// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IRewardsClaimManager, VestingData} from "../../interfaces/IRewardsClaimManager.sol";
import {ICoreDepositWallet} from "./ICoreDepositWallet.sol";
import {HyperCoreLib} from "./lib/HyperCoreLib.sol";
import {HyperCoreSupportedDexLib} from "./lib/HyperCoreSupportedDexLib.sol";
import {HyperCoreSubstrateLib} from "./lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "./lib/HyperCorePendingLib.sol";
import {HyperCoreValuationLib} from "./lib/HyperCoreValuationLib.sol";

/// @dev Data structure for entering the HyperCore spot send fuse (action 6)
struct HyperCoreSendFuseSpotSendData {
    /// @notice Destination address (granted as a Destination substrate)
    address destination;
    /// @notice HyperCore spot token index
    uint64 tokenIndex;
    /// @notice Amount to send, in Core wei
    uint64 amountWei;
}

/// @dev Data structure for entering the HyperCore send-asset fuse (action 13)
struct HyperCoreSendFuseSendAssetData {
    /// @notice Destination address (granted as a Destination substrate)
    address destination;
    /// @notice Source dex id: spot, native perp, or a configured supported HIP-3 perp dex
    uint32 sourceDex;
    /// @notice Destination dex id: spot, native perp, or a configured supported HIP-3 perp dex
    uint32 destinationDex;
    /// @notice HyperCore token index
    uint64 tokenIndex;
    /// @notice Amount to send, in Core wei
    uint64 amountWei;
}

/// @title HyperCoreSendFuse
/// @author IPOR Labs
/// @notice Sends granted spot or configured perp balances to a granted destination on HyperCore
///         (CoreWriter actions 6 spotSend and 13 sendAsset). `subAccount` is always address(0).
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
contract HyperCoreSendFuse is IFuseCommon {
    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @dev Vault-side baseline of a Core -> EVM bridge, read BEFORE the action is sent (IL-9529). All sums are
    ///      thresholds that already include the bridged EVM amount A.
    struct BridgeBaseline {
        /// @dev Granted ERC20 credited by the bridge; `address(0)` for a self-send (no cross-domain effect)
        address evmAsset;
        /// @dev Vault balance of `evmAsset` + A
        uint256 expectedBalance;
        /// @dev Rewards manager bound to the record; `address(0)` unless `evmAsset` is the vault's underlying and a
        ///      rewards manager is set
        address rewardsManager;
        /// @dev Vault balance + the manager's balance of `evmAsset` + A (0 when unbound)
        uint256 expectedRawSum;
        /// @dev Vault balance + `IRewardsClaimManager.balanceOf()` + A (0 when unbound)
        uint256 expectedVestedSum;
        /// @dev The manager's `getVestingData()` at send: its push counter and anchor (zero when unbound)
        VestingData vesting;
    }

    /// @notice Emitted when entering the HyperCore spot send fuse
    event HyperCoreSendFuseSpotSend(address version, address destination, uint64 tokenIndex, uint64 amountWei);

    /// @notice Emitted when entering the HyperCore send-asset fuse
    event HyperCoreSendFuseSendAsset(
        address version,
        address destination,
        uint32 sourceDex,
        uint32 destinationDex,
        uint64 tokenIndex,
        uint64 amountWei
    );

    /// @notice Thrown when the market ID passed to the constructor is zero
    error HyperCoreSendFuseInvalidMarketId();

    /// @notice Thrown when the vault's HyperCore account does not exist yet
    error HyperCoreSendFuseAccountNotActivated();

    /// @notice Thrown when `amountWei` is zero
    error HyperCoreSendFuseZeroAmount();

    /// @notice Thrown when the token index is not granted as a SpotToken substrate
    error HyperCoreSendFuseUnsupportedToken(uint64 tokenIndex);

    /// @notice Thrown when the requested amount exceeds the configured per-token send cap
    error HyperCoreSendFuseExceedsSendCap(uint64 amountWei, uint128 maxWei);

    /// @notice Thrown when the destination address is not granted
    error HyperCoreSendFuseDestinationNotGranted(address destination);

    /// @notice Thrown when the destination is the vault itself but the policy for this call does not allow it
    error HyperCoreSendFuseSelfSend();

    /// @notice Thrown when the destination is neither `address(this)` (cross-dex own-funds move, sendAsset only)
    ///         nor exactly the token's derived system address (Core -> EVM), even if a Destination substrate grants it
    error HyperCoreSendFuseDestinationNotAllowed(address destination);

    /// @notice Thrown when a dex id is neither the spot dex nor the native perp dex
    error HyperCoreSendFuseUnsupportedDex(uint32 dex);

    /// @notice Thrown when the source balance is insufficient for the requested send
    error HyperCoreSendFuseInsufficientBalance(uint256 available, uint256 required);

    /// @notice Thrown when a Core -> EVM amount is not representable at EVM precision (would burn value)
    error HyperCoreSendFuseAmountNotRepresentable(uint64 amountWei);

    /// @notice Thrown when the configured transfer-class window is below `MIN_WINDOW_TRANSFER_SECONDS` (2) or exceeds
    ///         `type(uint64).max`
    error HyperCoreSendFuseInvalidWindow(uint240 value);

    /// @notice Thrown when the configured transfer timeout is below `MIN_TRANSFER_TIMEOUT_SECONDS` (60) or exceeds
    ///         `type(uint64).max`
    error HyperCoreSendFuseInvalidTimeout(uint240 value);

    /// @notice Thrown when a Core -> EVM bridge (system-address destination) is requested via a route
    ///         other than spot -> spot; perp collateral must return through the margin fuse (action 7) first
    error HyperCoreSendFuseUnsupportedBridgeRoute(uint32 sourceDex, uint32 destinationDex);

    /// @notice Thrown when the in-transit USD value leaving Core would exceed the live snapshotted value,
    ///         which would otherwise let the cached NAV overstate the post-settlement value
    error HyperCoreSendFuseTransitExceedsValue(uint256 liveValueWad, uint256 transitValueWad);

    /// @notice Thrown when USDC's reported `weiDecimals` is outside the sane [6, 18] range this fuse
    ///         can safely scale a perp-margin USD6 amount against; fails closed rather than guessing
    error HyperCoreSendFuseUnexpectedUsdcScale(uint8 weiDecimals);

    /// @notice Thrown when a HIP-3 source dex has no positive or sufficient equity
    error HyperCoreSendFuseInsufficientDexEquity(uint32 dex, uint256 availableUsd6, uint256 requiredUsd6);

    /// @notice Thrown when a Core -> EVM bridge is requested for a token whose granted ERC-20 is not the one HyperCore
    ///         links to `tokenIndex` (IL-9639). Mirrors the Core-link check of `HyperCoreDepositFuse` and
    ///         `HyperCoreMarginFuse`; it is not a grant policy.
    /// @param tokenIndex HyperCore spot token index
    /// @param grantedEvmAsset The ERC-20 granted for the token in the vault's substrates
    error HyperCoreSendFuseBridgeTokenMismatch(uint64 tokenIndex, address grantedEvmAsset);

    /// @notice Thrown when `enterSpotSend` targets a token system address (Core -> EVM bridge) but the
    ///         Atomist has not explicitly enabled the spot-send bridge via
    ///         `Config{SpotSendBridgeEnabled}` == 1; fails closed by default
    error HyperCoreSendFuseSpotSendBridgeDisabled();

    /// @notice Constructor for HyperCoreSendFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert HyperCoreSendFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Sends a granted spot token balance to a granted destination (CoreWriter action 6)
    /// @param data_ Enter data containing destination, token index and amount
    /// @dev @custom:revert HyperCoreSendFuseSpotSendBridgeDisabled When targeting a token system address
    ///      (Core -> EVM) while `Config{SpotSendBridgeEnabled}` is unset or not exactly 1. Fails closed:
    ///      the Atomist must explicitly opt the vault into the spot-send bridge route. `enterSendAsset`
    ///      (action 13) is unaffected by this gate: it is the designed Core -> EVM route (and cheaper on
    ///      mainnet), while the flag only admits a second encoding (action 6) of the same withdrawal once it
    ///      has been proven on a given chain. Both routes share the same destination, cap and balance checks.
    function enterSpotSend(HyperCoreSendFuseSpotSendData memory data_) public {
        if (data_.destination != address(this)) {
            (bool bridgeEnabledSet, uint240 bridgeEnabled) = HyperCoreSubstrateLib.getConfig(
                MARKET_ID,
                HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled
            );
            if (!bridgeEnabledSet || bridgeEnabled != 1) {
                revert HyperCoreSendFuseSpotSendBridgeDisabled();
            }
        }

        _validate(data_.destination, HyperCoreLib.SPOT_DEX, HyperCoreLib.SPOT_DEX, data_.tokenIndex, data_.amountWei);

        uint256 s = HyperCoreValuationLib.liveValueWad(MARKET_ID);
        uint256 c = _cachedValueWad(data_.destination, data_.tokenIndex, data_.amountWei, s);

        bytes memory payload = HyperCoreLib.encodeSpotSend(data_.destination, data_.tokenIndex, data_.amountWei);
        BridgeBaseline memory baseline = _bridgeBaseline(data_.destination, data_.tokenIndex, data_.amountWei);
        HyperCoreLib.sendRawAction(payload);

        _enqueue(c, HyperCoreLib.ACTION_SPOT_SEND, payload, baseline);

        emit HyperCoreSendFuseSpotSend(VERSION, data_.destination, data_.tokenIndex, data_.amountWei);
    }

    /// @notice Sends a granted spot or configured perp balance to a granted destination (CoreWriter action 13)
    /// @param data_ Enter data containing destination, source/destination dex ids, token index and amount
    function enterSendAsset(HyperCoreSendFuseSendAssetData memory data_) public {
        if (
            data_.destinationDex != HyperCoreLib.SPOT_DEX && data_.destinationDex != HyperCoreLib.NATIVE_PERP_DEX
                && !HyperCoreSupportedDexLib.isSupportedPerpDex(data_.destinationDex)
        ) {
            revert HyperCoreSendFuseUnsupportedDex(data_.destinationDex);
        }

        _validate(data_.destination, data_.sourceDex, data_.destinationDex, data_.tokenIndex, data_.amountWei);

        uint256 s = HyperCoreValuationLib.liveValueWad(MARKET_ID);
        uint256 c = _cachedValueWad(data_.destination, data_.tokenIndex, data_.amountWei, s);

        bytes memory payload = HyperCoreLib.encodeSendAsset(
            data_.destination,
            address(0),
            data_.sourceDex,
            data_.destinationDex,
            data_.tokenIndex,
            data_.amountWei
        );
        BridgeBaseline memory baseline = _bridgeBaseline(data_.destination, data_.tokenIndex, data_.amountWei);
        HyperCoreLib.sendRawAction(payload);

        _enqueue(c, HyperCoreLib.ACTION_SEND_ASSET, payload, baseline);

        emit HyperCoreSendFuseSendAsset(
            VERSION,
            data_.destination,
            data_.sourceDex,
            data_.destinationDex,
            data_.tokenIndex,
            data_.amountWei
        );
    }

    /// @dev For a Core -> EVM bridge (destination is not the vault) returns the granted ERC20 and the vault
    ///      balance it must reach once the credit lands: current balance plus the exact EVM amount A (the
    ///      Core -> EVM fee is charged separately on Core). Must be read BEFORE the action is sent. Returns an
    ///      empty baseline for a self-send, which carries no cross-domain effect.
    ///      IL-9529 (3sigma #2, D-034): when the ERC20 is the vault's underlying and a rewards manager is set, the
    ///      manager's vested underlying is already counted in NAV (`PlasmaVault._getGrossTotalAssets`) and can be pushed
    ///      into the vault by anyone (`transferVestedTokensToVault`) or by the keeper (`updateBalance`). Such a push
    ///      alone would meet `expectedBalance` before the credit, and with vesting accrual or underlying sent to the
    ///      manager it could also meet any balance sum. So the baseline also snapshots the manager's
    ///      `getVestingData()`: the gate subtracts the pushes the manager has counted in `transferredTokens` since the
    ///      send, and a re-anchor (`updateBalanceTimestamp` or `lastUpdateBalance` changed, the counter reset) or a
    ///      manager change waits for `timeoutAt`. The two D-004 sums, each plus A, stay: the vault balance plus the
    ///      manager's raw token balance, and the vault balance plus `IRewardsClaimManager.balanceOf()`
    ///      (`HyperCorePendingLib.isEffectObserved`).
    function _bridgeBaseline(
        address destination_,
        uint64 tokenIndex_,
        uint64 amountWei_
    ) internal view returns (BridgeBaseline memory baseline_) {
        if (destination_ == address(this)) {
            return baseline_;
        }
        (, baseline_.evmAsset) = HyperCoreSubstrateLib.getSpotToken(MARKET_ID, tokenIndex_);
        HyperCoreLib.TokenInfo memory info = HyperCoreLib.tokenInfo(tokenIndex_);
        _requireCoreLinkedAsset(tokenIndex_, baseline_.evmAsset, info.evmContract);
        uint256 vaultBalance = IERC20(baseline_.evmAsset).balanceOf(address(this));
        uint256 evmAmount = HyperCoreLib.coreWeiToEvm(amountWei_, info.evmExtraWeiDecimals);
        baseline_.expectedBalance = vaultBalance + evmAmount;

        address rewardsManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsManager != address(0) && baseline_.evmAsset == IERC4626(address(this)).asset()) {
            baseline_.rewardsManager = rewardsManager;
            baseline_.expectedRawSum = baseline_.expectedBalance + IERC20(baseline_.evmAsset).balanceOf(rewardsManager);
            baseline_.expectedVestedSum = baseline_.expectedBalance + IRewardsClaimManager(rewardsManager).balanceOf();
            baseline_.vesting = IRewardsClaimManager(rewardsManager).getVestingData();
        }
    }

    /// @dev IL-9639: the granted ERC-20 must be the token HyperCore links to `tokenIndex_`, because the bridge gate waits
    ///      for a credit of exactly that token. This mirrors the Core-link check of `HyperCoreDepositFuse` (any token)
    ///      and `HyperCoreMarginFuse` (USDC); it does not police what is granted or revoked. A token without an EVM
    ///      contract (native HYPE) never matches. Token 0 (USDC) also accepts the CoreDepositWallet's `token()`, since
    ///      there `tokenInfo(0).evmContract` is the wallet and not the ERC-20.
    function _requireCoreLinkedAsset(uint64 tokenIndex_, address evmAsset_, address evmContract_) internal view {
        if (evmAsset_ == address(0)) {
            revert HyperCoreSendFuseBridgeTokenMismatch(tokenIndex_, evmAsset_);
        }
        if (evmAsset_ == evmContract_) {
            return;
        }
        if (tokenIndex_ == HyperCoreLib.USDC_TOKEN && evmContract_ != address(0)) {
            try ICoreDepositWallet(evmContract_).token() returns (address walletToken_) {
                if (walletToken_ == evmAsset_) {
                    return;
                }
            } catch {}
        }
        revert HyperCoreSendFuseBridgeTokenMismatch(tokenIndex_, evmAsset_);
    }

    /// @dev Enqueues the transfer; a Core -> EVM bridge (`baseline_.evmAsset != address(0)`) additionally waits for
    ///      its EVM credit (or the configured timeout), a self-send settles by time only. A bridge of the underlying on
    ///      a vault with a rewards manager is then bound to that manager (`HyperCorePendingLib.bindRewardsEffect`).
    function _enqueue(
        uint256 cachedValueWad_,
        uint24 actionId_,
        bytes memory payload_,
        BridgeBaseline memory baseline_
    ) internal {
        if (baseline_.evmAsset == address(0)) {
            HyperCorePendingLib.enqueue(
                cachedValueWad_,
                _windowTransfer(),
                actionId_,
                keccak256(payload_)
            );
        } else {
            HyperCorePendingLib.enqueueTransferWithEffect(
                cachedValueWad_,
                _windowTransfer(),
                actionId_,
                keccak256(payload_),
                HyperCorePendingLib.EFFECT_EVM_BALANCE,
                0,
                baseline_.evmAsset,
                baseline_.expectedBalance,
                _transferTimeout()
            );
            if (baseline_.rewardsManager != address(0)) {
                HyperCorePendingLib.bindRewardsEffect(
                    baseline_.rewardsManager,
                    baseline_.expectedRawSum,
                    baseline_.expectedVestedSum,
                    baseline_.vesting
                );
            }
        }
    }

    /// @dev Shared validation for both spot send (sourceDex_ = destinationDex_ = SPOT_DEX) and
    ///      send-asset entry points.
    function _validate(
        address destination_,
        uint32 sourceDex_,
        uint32 destinationDex_,
        uint64 tokenIndex_,
        uint64 amountWei_
    ) internal view {
        HyperCorePendingLib.requireNotPendingAction();

        if (!HyperCoreLib.coreUserExists(address(this))) {
            revert HyperCoreSendFuseAccountNotActivated();
        }

        if (amountWei_ == 0) {
            revert HyperCoreSendFuseZeroAmount();
        }

        (bool tokenGranted, ) = HyperCoreSubstrateLib.getSpotToken(MARKET_ID, tokenIndex_);
        if (!tokenGranted) {
            revert HyperCoreSendFuseUnsupportedToken(tokenIndex_);
        }

        (bool capSet, uint128 maxWei) = HyperCoreSubstrateLib.getSendCap(MARKET_ID, tokenIndex_);
        if (!capSet || amountWei_ > maxWei) {
            revert HyperCoreSendFuseExceedsSendCap(amountWei_, capSet ? maxWei : 0);
        }

        if (!HyperCoreSubstrateLib.isDestinationGranted(MARKET_ID, destination_)) {
            revert HyperCoreSendFuseDestinationNotGranted(destination_);
        }

        _validateDestinationPolicy(destination_, sourceDex_, destinationDex_, tokenIndex_, amountWei_);

        _validateDex(sourceDex_);
        _validateDex(destinationDex_);

        bool sourceHip3 = sourceDex_ != HyperCoreLib.SPOT_DEX && sourceDex_ != HyperCoreLib.NATIVE_PERP_DEX;
        bool destinationHip3 = destinationDex_ != HyperCoreLib.SPOT_DEX && destinationDex_ != HyperCoreLib.NATIVE_PERP_DEX;
        if (sourceHip3 || destinationHip3) {
            if (destination_ != address(this)) {
                revert HyperCoreSendFuseDestinationNotAllowed(destination_);
            }
            if (tokenIndex_ != HyperCoreLib.USDC_TOKEN) {
                revert HyperCoreSendFuseUnsupportedToken(tokenIndex_);
            }
        }

        if (sourceHip3) {
            uint8 usdcWeiDecimals = HyperCoreLib.tokenInfo(HyperCoreLib.USDC_TOKEN).weiDecimals;
            if (usdcWeiDecimals < 6 || usdcWeiDecimals > 18) {
                revert HyperCoreSendFuseUnexpectedUsdcScale(usdcWeiDecimals);
            }
            uint256 factor = 10 ** (uint256(usdcWeiDecimals) - 6);
            uint256 required = (uint256(amountWei_) + factor - 1) / factor;
            HyperCoreLib.AccountMarginSummary memory summary = HyperCoreLib.accountMarginSummary(sourceDex_, address(this));
            if (summary.accountValue <= 0 || uint256(uint64(summary.accountValue)) < required) {
                revert HyperCoreSendFuseInsufficientDexEquity(
                    sourceDex_, summary.accountValue > 0 ? uint256(uint64(summary.accountValue)) : 0, required
                );
            }
        } else if (sourceDex_ == HyperCoreLib.SPOT_DEX) {
            HyperCoreLib.SpotBalance memory balance = HyperCoreLib.spotBalance(address(this), tokenIndex_);
            uint256 available = uint256(balance.total) - uint256(balance.hold);
            if (available < amountWei_) {
                revert HyperCoreSendFuseInsufficientBalance(available, amountWei_);
            }
        } else {
            if (tokenIndex_ != HyperCoreLib.USDC_TOKEN) {
                revert HyperCoreSendFuseUnsupportedToken(tokenIndex_);
            }
            // `withdrawable()` (0x803) returns the native perp account's withdrawable USD with 6 decimals
            // (checked on HyperEVM mainnet: 22.0 USDC withdrawable reads 22000000, IL-8902).
            // amountWei_ is Core wei in USDC's own `weiDecimals`: fail closed on any scale this fuse
            // cannot safely reason about, rather than hardcoding a network-specific factor. Ceiling-divide
            // so a fractional-cent request never passes with an under-counted USD6 requirement.
            uint8 usdcWeiDecimals = HyperCoreLib.tokenInfo(HyperCoreLib.USDC_TOKEN).weiDecimals;
            if (usdcWeiDecimals < 6 || usdcWeiDecimals > 18) {
                revert HyperCoreSendFuseUnexpectedUsdcScale(usdcWeiDecimals);
            }
            uint256 factor = 10 ** (uint256(usdcWeiDecimals) - 6);
            uint64 available = HyperCoreLib.withdrawable(address(this));
            uint256 required = (uint256(amountWei_) + factor - 1) / factor;
            if (available < required) {
                revert HyperCoreSendFuseInsufficientBalance(available, required);
            }
        }
    }

    /// @dev Accepts spot/native implicitly and HIP-3 only when supported and enabled in this vault's NAV bitmap.
    function _validateDex(uint32 dex_) internal view {
        if (dex_ == HyperCoreLib.SPOT_DEX || dex_ == HyperCoreLib.NATIVE_PERP_DEX) return;
        bool configured = HyperCoreSubstrateLib.isPerpDexConfigured(MARKET_ID, dex_);
        if (!HyperCoreSupportedDexLib.isSupportedPerpDex(dex_) || !configured) {
            revert HyperCoreSendFuseUnsupportedDex(dex_);
        }
    }

    /// @dev Destination policy (agreed spec): `destination_` must be EITHER `address(this)` — only
    ///      allowed for `enterSendAsset` when `sourceDex_ != destinationDex_` (a spot<->perp move of the
    ///      vault's own funds; rejected for `enterSpotSend` and for a same-dex `enterSendAsset`) — OR
    ///      exactly the token's derived system address (`HyperCoreLib.systemAddress(tokenIndex_)`), i.e. a
    ///      Core -> EVM withdrawal. Any other destination reverts even if a Destination substrate grants
    ///      it. HYPE and other tokens without a linked ERC20 (`evmContract == address(0)`) cannot be sent
    ///      to a system address in v1. A Core -> EVM amount that would round to a different value at EVM
    ///      precision (and so burn value on receipt) is rejected outright rather than silently rounded.
    function _validateDestinationPolicy(
        address destination_,
        uint32 sourceDex_,
        uint32 destinationDex_,
        uint64 tokenIndex_,
        uint64 amountWei_
    ) internal view {
        if (destination_ == address(this)) {
            if (sourceDex_ == destinationDex_) {
                revert HyperCoreSendFuseSelfSend();
            }
            return;
        }

        // Core -> EVM bridge: only a spot -> spot route may target the system address. Perp
        // collateral must be moved to spot via the margin fuse (action 7) before it can leave Core.
        if (sourceDex_ != HyperCoreLib.SPOT_DEX || destinationDex_ != HyperCoreLib.SPOT_DEX) {
            revert HyperCoreSendFuseUnsupportedBridgeRoute(sourceDex_, destinationDex_);
        }

        HyperCoreLib.TokenInfo memory info = HyperCoreLib.tokenInfo(tokenIndex_);
        if (info.evmContract == address(0)) {
            revert HyperCoreSendFuseUnsupportedToken(tokenIndex_);
        }

        address expectedSystem = HyperCoreLib.systemAddress(tokenIndex_);
        if (destination_ != expectedSystem) {
            revert HyperCoreSendFuseDestinationNotAllowed(destination_);
        }

        uint256 evmAmount = HyperCoreLib.coreWeiToEvm(amountWei_, info.evmExtraWeiDecimals);
        (uint64 roundTrip, ) = HyperCoreLib.evmToCoreWei(evmAmount, info.evmExtraWeiDecimals);
        if (roundTrip != amountWei_) {
            revert HyperCoreSendFuseAmountNotRepresentable(amountWei_);
        }
    }

    /// @dev Cached value snapshotted for the pending window: `S` when the destination is `address(this)`
    ///      (funds stay on Core, only moving between dexes); `S - A` when the destination is the token's
    ///      system address, i.e. this send is a Core -> EVM withdrawal, where `A` is the USD WAD value of
    ///      the amount leaving Core priced via the vault's price oracle middleware, using the same basis
    ///      as `HyperCoreValuationLib.liveValueWad` (Core-wei quantity, the granted SpotToken's `evmAsset`
    ///      as the pricing key, and `tokenInfo.weiDecimals` for scale) so `S` and `A` are directly
    ///      comparable. The real `tokenInfo.evmContract` is used only for the transfer/destination and
    ///      representability checks in `_validateDestinationPolicy`, never for pricing. `A` must never
    ///      exceed `S`: a transfer that would make the cached value negative means the live snapshot
    ///      already excludes value (e.g. negative perp PnL) that this spot-only send cannot draw down,
    ///      so it reverts rather than silently clamping to zero and overstating post-settlement NAV.
    function _cachedValueWad(address destination_, uint64 tokenIndex_, uint64 amountWei_, uint256 s_)
        internal
        view
        returns (uint256)
    {
        if (destination_ == address(this)) {
            return s_;
        }

        (, address grantedEvmAsset) = HyperCoreSubstrateLib.getSpotToken(MARKET_ID, tokenIndex_);
        HyperCoreLib.TokenInfo memory info = HyperCoreLib.tokenInfo(tokenIndex_);

        address oracle = PlasmaVaultLib.getPriceOracleMiddleware();
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(oracle).getAssetPrice(grantedEvmAsset);
        uint256 a = IporMath.convertToWad(uint256(amountWei_) * price, uint256(info.weiDecimals) + priceDecimals);

        if (a > s_) {
            revert HyperCoreSendFuseTransitExceedsValue(s_, a);
        }
        return s_ - a;
    }

    /// @dev Reads the configured transfer-class settlement window; defaults to 2 seconds when unset. A configured value
    ///      below `HyperCorePendingLib.MIN_WINDOW_TRANSFER_SECONDS` (2) reverts (IL-9529): a 1 s window could pass the
    ///      time gate in the block in which the Core debit of a bridge is visible but its EVM credit is still queued.
    function _windowTransfer() internal view returns (uint64) {
        (bool set, uint240 value) = HyperCoreSubstrateLib.getConfig(
            MARKET_ID,
            HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds
        );
        if (!set) {
            return 2;
        }
        if (value < HyperCorePendingLib.MIN_WINDOW_TRANSFER_SECONDS || value > type(uint64).max) {
            revert HyperCoreSendFuseInvalidWindow(value);
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
            revert HyperCoreSendFuseInvalidTimeout(value);
        }
        return uint64(value);
    }
}
