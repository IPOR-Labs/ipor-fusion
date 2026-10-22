// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {HyperCoreLib} from "./lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "./lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "./lib/HyperCorePendingLib.sol";
import {HyperCoreHookWiringLib} from "./lib/HyperCoreHookWiringLib.sol";
import {HyperCoreValuationLib} from "./lib/HyperCoreValuationLib.sol";
import {ICoreDepositWallet} from "./ICoreDepositWallet.sol";

/// @dev Data structure for entering (EVM -> Core) the HyperCore deposit fuse
struct HyperCoreDepositFuseEnterData {
    /// @notice HyperCore spot token index (granted as a SpotToken substrate)
    uint64 tokenIndex;
    /// @notice Amount of the EVM asset to transfer, in the EVM token's own decimals
    uint256 amount;
}

/// @title HyperCoreDepositFuse
/// @author IPOR Labs
/// @notice Moves a granted spot token from the vault's EVM balance to its HyperCore spot
///         balance by transferring it to the token's Core system address.
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage
///      variables. This is the account-activation path: unlike every other HyperCore fuse it
///      does NOT require `coreUserExists()` beforehand, because the first inbound transfer is
///      what activates the vault's HyperCore account.
contract HyperCoreDepositFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the HyperCore deposit fuse
    /// @param version The address of the fuse version
    /// @param tokenIndex The HyperCore spot token index
    /// @param evmAsset The EVM asset address transferred
    /// @param amount The EVM-side amount actually transferred (rounded down to a Core-representable amount)
    /// @param coreWei The resulting amount credited on HyperCore, in Core wei
    event HyperCoreDepositFuseEnter(
        address version,
        uint64 tokenIndex,
        address evmAsset,
        uint256 amount,
        uint64 coreWei
    );

    /// @notice Thrown when the market ID passed to the constructor is zero
    error HyperCoreDepositFuseInvalidMarketId();

    /// @notice Thrown when the token index is not granted as a SpotToken substrate for this market
    /// @param tokenIndex The ungranted HyperCore token index
    error HyperCoreDepositFuseUnsupportedToken(uint64 tokenIndex);

    /// @notice Thrown when the granted EVM asset does not match HyperCore's registered EVM contract for the token
    error HyperCoreDepositFuseTokenMismatch();

    /// @notice Thrown when depositing USDC (token 0) via the CoreDepositWallet and its `token()` does
    ///         not match the granted EVM asset
    /// @param wallet The CoreDepositWallet address (`tokenInfo(0).evmContract`)
    /// @param walletToken The ERC20 address reported by `wallet.token()`
    /// @param grantedEvmAsset The EVM asset granted as the SpotToken(0) substrate
    error HyperCoreDepositFuseDepositWalletTokenMismatch(address wallet, address walletToken, address grantedEvmAsset);

    /// @notice Thrown when the CoreDepositWallet (USDC, token 0) is paused, or an unexpected call to it
    ///         reverts; fails closed rather than assuming availability
    error HyperCoreDepositFuseDepositWalletUnavailable();

    /// @notice Thrown when the configured transfer-class window is zero or exceeds `type(uint64).max`
    error HyperCoreDepositFuseInvalidWindow(uint240 value);

    /// @notice Thrown when the configured transfer timeout is below `MIN_TRANSFER_TIMEOUT_SECONDS` (60) or exceeds
    ///         `type(uint64).max`
    error HyperCoreDepositFuseInvalidTimeout(uint240 value);

    /// @notice Thrown when the configured activation-fee allowance does not fit `uint64` (Core wei)
    error HyperCoreDepositFuseInvalidActivationFeeAllowance(uint240 value);

    /// @notice Constructor for HyperCoreDepositFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert HyperCoreDepositFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Transfers a granted spot token from the vault's EVM balance to HyperCore spot
    /// @param data_ Enter data containing the HyperCore token index and the EVM amount to send
    /// @dev @custom:revert HyperCoreActionPending When a HyperCore action is already pending
    /// @dev @custom:revert HyperCorePreHooksNotWired When the six share-priced selectors are not all wired to one
    ///      HyperCoreCapitalFlowPreHook (IL-8529)
    /// @dev @custom:revert HyperCoreDepositFuseUnsupportedToken When the token index is not granted
    /// @dev @custom:revert HyperCoreDepositFuseTokenMismatch When the granted EVM asset does not match HyperCore's records
    /// @dev @custom:revert HyperCoreDepositFuseDepositWalletTokenMismatch When USDC's CoreDepositWallet
    ///      `token()` does not match the granted EVM asset
    /// @dev @custom:revert HyperCoreDepositFuseDepositWalletUnavailable When USDC's CoreDepositWallet is
    ///      paused, or a call to it unexpectedly reverts
    /// @dev @custom:revert HyperCoreDepositFuseInvalidTimeout When the configured transfer timeout is below
    ///      `MIN_TRANSFER_TIMEOUT_SECONDS` (60) or exceeds `type(uint64).max`
    /// @dev @custom:revert HyperCoreDepositFuseInvalidActivationFeeAllowance When the configured allowance
    ///      does not fit `uint64`
    /// @dev The deposit stays pending until the vault's Core spot balance reaches the expected net credit,
    ///      or `pendingUntil + timeout` passes (residual risk: Core lagging beyond the timeout opens the gate
    ///      with NAV missing the in-transit amount; the GUARDIAN must pause the vault in that case).
    function enter(HyperCoreDepositFuseEnterData memory data_) public {
        // @dev No other HyperCore action (deposit or CoreWriter) may be in flight; this guard also
        //      prevents the in-transit credit `A` computed below from being double counted.
        HyperCorePendingLib.requireNotPendingAction();
        // IL-8529: no capital reaches Core unless the share-priced flows refresh market 55 before pricing.
        HyperCoreHookWiringLib.requireCapitalFlowWired();

        (bool granted, address evmAsset) = HyperCoreSubstrateLib.getSpotToken(MARKET_ID, data_.tokenIndex);
        if (!granted) {
            revert HyperCoreDepositFuseUnsupportedToken(data_.tokenIndex);
        }

        HyperCoreLib.TokenInfo memory info = HyperCoreLib.tokenInfo(data_.tokenIndex);

        // Hyperliquid routes HyperCore token 0 (USDC) through a CoreDepositWallet contract
        // (Circle/Hyperliquid's TransparentUpgradeableProxy) on every network where USDC is
        // CCTP-native: `tokenInfo(0).evmContract` is that wallet's address, not the USDC ERC20
        // itself, and depositing requires calling `deposit`/`depositFor` on it rather than
        // transferring USDC to the token's derived system address (which would credit nothing).
        // Every other token keeps the generic system-address transfer path below.
        bool viaWallet = data_.tokenIndex == HyperCoreLib.USDC_TOKEN;
        _validateEvmAsset(viaWallet, info.evmContract, evmAsset);

        uint256 amount = IporMath.min(IERC20(evmAsset).balanceOf(address(this)), data_.amount);
        if (amount == 0) {
            return;
        }

        (uint64 coreWei, uint256 rounded) = HyperCoreLib.evmToCoreWei(amount, info.evmExtraWeiDecimals);
        if (rounded == 0) {
            // Amount is below the smallest Core-representable unit for this token; nothing to send.
            return;
        }

        // Snapshot the live Core value before the transfer is observable, then add the
        // in-transit USD value of this deposit as the cached value for the pending window.
        uint256 cachedValueWad = HyperCoreValuationLib.liveValueWad(MARKET_ID) + _creditValueWad(evmAsset, rounded);

        uint256 expectedBalance = _expectedCoreBalance(data_.tokenIndex, coreWei);

        _transferToCore(viaWallet, info.evmContract, evmAsset, data_.tokenIndex, rounded);
        _enqueueAndEmit(data_.tokenIndex, evmAsset, rounded, coreWei, cachedValueWad, expectedBalance);
    }

    /// @dev Core spot balance the vault must reach for the deposit to count as landed:
    ///      `baseline + coreWei - min(coreWei, allowance)`. Must be read BEFORE the transfer. For a first USDC
    ///      deposit into a not-yet-activated account Core charges an activation fee out of the credit, so the
    ///      configured `ActivationFeeAllowanceUsdcWei` is netted off; any other case expects the full credit.
    function _expectedCoreBalance(uint64 tokenIndex_, uint64 coreWei_) internal view returns (uint256) {
        bool existed = HyperCoreLib.coreUserExists(address(this));
        uint256 baseline = existed ? HyperCoreLib.spotBalance(address(this), tokenIndex_).total : 0;
        uint256 allowance = (!existed && tokenIndex_ == HyperCoreLib.USDC_TOKEN) ? _activationFeeAllowance() : 0;
        return baseline + coreWei_ - IporMath.min(coreWei_, allowance);
    }

    /// @dev Validates the granted EVM asset against HyperCore's records for `tokenIndex_`, following
    ///      either the CoreDepositWallet path (USDC, token 0) or the generic system-address path.
    function _validateEvmAsset(bool viaWallet_, address evmContract_, address evmAsset_) internal view {
        if (viaWallet_) {
            address walletToken;
            try ICoreDepositWallet(evmContract_).token() returns (address token) {
                walletToken = token;
            } catch {
                revert HyperCoreDepositFuseDepositWalletUnavailable();
            }
            if (walletToken != evmAsset_ || evmAsset_ == address(0)) {
                revert HyperCoreDepositFuseDepositWalletTokenMismatch(evmContract_, walletToken, evmAsset_);
            }
            try ICoreDepositWallet(evmContract_).paused() returns (bool isPaused) {
                if (isPaused) {
                    revert HyperCoreDepositFuseDepositWalletUnavailable();
                }
            } catch {
                revert HyperCoreDepositFuseDepositWalletUnavailable();
            }
        } else {
            // Native HYPE (and any token with no EVM contract) has evmContract == address(0) and cannot
            // be deposited through an ERC20 transfer; the check below rejects it.
            if (evmContract_ != evmAsset_ || evmAsset_ == address(0)) {
                revert HyperCoreDepositFuseTokenMismatch();
            }
        }
    }

    /// @dev Moves `rounded_` of `evmAsset_` to HyperCore, either through the CoreDepositWallet
    ///      (USDC, token 0; approve, depositFor, then reset the approval) or by a plain ERC20
    ///      transfer to the token's derived system address for every other granted token.
    function _transferToCore(
        bool viaWallet_,
        address evmContract_,
        address evmAsset_,
        uint64 tokenIndex_,
        uint256 rounded_
    ) internal {
        if (viaWallet_) {
            IERC20(evmAsset_).forceApprove(evmContract_, rounded_);
            ICoreDepositWallet(evmContract_).depositFor(address(this), rounded_, HyperCoreLib.SPOT_DEX);
            IERC20(evmAsset_).forceApprove(evmContract_, 0);
        } else {
            IERC20(evmAsset_).safeTransfer(HyperCoreLib.systemAddress(tokenIndex_), rounded_);
        }
    }

    /// @dev Enqueues the pending action and emits the enter event for a completed deposit.
    function _enqueueAndEmit(
        uint64 tokenIndex_,
        address evmAsset_,
        uint256 rounded_,
        uint64 coreWei_,
        uint256 cachedValueWad_,
        uint256 expectedBalance_
    ) internal {
        HyperCorePendingLib.enqueueTransferWithEffect(
            cachedValueWad_,
            _windowTransfer(),
            0,
            keccak256(abi.encode(tokenIndex_, rounded_)),
            HyperCorePendingLib.EFFECT_CORE_SPOT,
            tokenIndex_,
            address(0),
            expectedBalance_,
            _transferTimeout()
        );

        emit HyperCoreDepositFuseEnter(VERSION, tokenIndex_, evmAsset_, rounded_, coreWei_);
    }

    /// @notice Prices the in-transit deposit amount in USD WAD using the vault's price oracle middleware
    /// @param evmAsset_ The EVM asset being deposited
    /// @param roundedAmount_ The EVM-side amount actually transferred
    function _creditValueWad(address evmAsset_, uint256 roundedAmount_) internal view returns (uint256) {
        address oracle = PlasmaVaultLib.getPriceOracleMiddleware();
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(oracle).getAssetPrice(evmAsset_);
        uint256 tokenDecimals = IERC20Metadata(evmAsset_).decimals();
        return IporMath.convertToWad(roundedAmount_ * price, tokenDecimals + priceDecimals);
    }

    /// @dev Reads the configured transfer-class settlement window; defaults to 2 seconds when unset.
    function _windowTransfer() internal view returns (uint64) {
        (bool set, uint240 value) = HyperCoreSubstrateLib.getConfig(
            MARKET_ID,
            HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds
        );
        if (!set) {
            return 2;
        }
        if (value == 0 || value > type(uint64).max) {
            revert HyperCoreDepositFuseInvalidWindow(value);
        }
        return uint64(value);
    }

    /// @dev Reads the configured effect timeout (seconds after the window); defaults to 600 when unset.
    function _transferTimeout() internal view returns (uint64) {
        (bool set, uint240 value) = HyperCoreSubstrateLib.getConfig(
            MARKET_ID,
            HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds
        );
        if (!set) {
            return 600;
        }
        if (value < HyperCorePendingLib.MIN_TRANSFER_TIMEOUT_SECONDS || value > type(uint64).max) {
            revert HyperCoreDepositFuseInvalidTimeout(value);
        }
        return uint64(value);
    }

    /// @dev Reads the configured first-deposit activation-fee allowance in USDC Core wei; defaults to
    ///      1 USDC (`10 ** tokenInfo(USDC).weiDecimals`) when unset.
    function _activationFeeAllowance() internal view returns (uint256) {
        (bool set, uint240 value) = HyperCoreSubstrateLib.getConfig(
            MARKET_ID,
            HyperCoreSubstrateLib.ConfigKey.ActivationFeeAllowanceUsdcWei
        );
        if (!set) {
            return 10 ** uint256(HyperCoreLib.tokenInfo(HyperCoreLib.USDC_TOKEN).weiDecimals);
        }
        if (value > type(uint64).max) {
            revert HyperCoreDepositFuseInvalidActivationFeeAllowance(value);
        }
        return uint256(value);
    }
}
