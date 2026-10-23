// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {HyperCoreLib} from "./lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "./lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "./lib/HyperCorePendingLib.sol";
import {HyperCoreValuationLib} from "./lib/HyperCoreValuationLib.sol";
import {ICoreDepositWallet} from "./ICoreDepositWallet.sol";

/// @dev Data structure for entering the HyperCore margin fuse (action 7, usdClassTransfer)
struct HyperCoreMarginFuseEnterData {
    /// @notice Amount to move between spot and perp margin, in USD with 6 decimals
    uint64 usd6;
    /// @notice true moves spot USDC into perp margin; false moves perp margin back to spot USDC
    bool toPerp;
}

/// @title HyperCoreMarginFuse
/// @author IPOR Labs
/// @notice Moves USDC between the vault's HyperCore spot balance and native perp margin
///         (CoreWriter action 7, usdClassTransfer).
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
contract HyperCoreMarginFuse is IFuseCommon {
    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the HyperCore margin fuse
    /// @param version The address of the fuse version
    /// @param usd6 The USD amount moved, 6 decimals
    /// @param toPerp true if moved from spot to perp margin
    event HyperCoreMarginFuseEnter(address version, uint64 usd6, bool toPerp);

    /// @notice Thrown when the market ID passed to the constructor is zero
    error HyperCoreMarginFuseInvalidMarketId();

    /// @notice Thrown when the vault's HyperCore account does not exist yet
    error HyperCoreMarginFuseAccountNotActivated();

    /// @notice Thrown when `usd6` is zero
    error HyperCoreMarginFuseZeroAmount();

    /// @notice Thrown when `usd6` exceeds the configured MaxUsdClassTransferUsd6 cap
    error HyperCoreMarginFuseExceedsCap(uint64 usd6, uint240 cap);

    /// @notice Thrown when no nonzero MaxUsdClassTransferUsd6 cap is configured
    error HyperCoreMarginFuseCapUnset();

    /// @notice Thrown when USDC (token 0) is not granted as a SpotToken substrate
    error HyperCoreMarginFuseUsdcNotGranted();

    /// @notice Thrown when the granted USDC EVM asset does not match HyperCore's registered EVM contract for token 0
    error HyperCoreMarginFuseUsdcTokenMismatch();

    /// @notice Thrown when USDC's reported `weiDecimals` is outside the sane [6, 18] range this fuse
    ///         can safely scale usd6 (6-decimal) amounts against; fails closed rather than guessing
    error HyperCoreMarginFuseUnexpectedUsdcScale(uint8 weiDecimals);

    /// @notice Thrown when the configured transfer-class window is zero or exceeds `type(uint64).max`
    error HyperCoreMarginFuseInvalidWindow(uint240 value);

    /// @notice Thrown when the vault's spot USDC balance is insufficient to move to perp margin
    error HyperCoreMarginFuseInsufficientSpotBalance(uint256 available, uint256 required);

    /// @notice Thrown when the vault's withdrawable perp margin is insufficient to move back to spot
    error HyperCoreMarginFuseInsufficientWithdrawable(uint64 available, uint64 required);

    /// @notice Constructor for HyperCoreMarginFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert HyperCoreMarginFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Moves USDC between HyperCore spot and native perp margin
    /// @param data_ Enter data containing the USD6 amount and the transfer direction
    /// @dev @custom:revert HyperCoreActionPending When a HyperCore action is already pending
    /// @dev @custom:revert HyperCoreMarginFuseAccountNotActivated When the vault has no HyperCore account yet
    function enter(HyperCoreMarginFuseEnterData memory data_) public {
        HyperCorePendingLib.requireNotPendingAction();

        if (!HyperCoreLib.coreUserExists(address(this))) {
            revert HyperCoreMarginFuseAccountNotActivated();
        }

        if (data_.usd6 == 0) {
            revert HyperCoreMarginFuseZeroAmount();
        }

        (bool usdcGranted, address usdcEvmAsset) = HyperCoreSubstrateLib.getSpotToken(
            MARKET_ID,
            HyperCoreLib.USDC_TOKEN
        );
        if (!usdcGranted) {
            revert HyperCoreMarginFuseUsdcNotGranted();
        }
        HyperCoreLib.TokenInfo memory usdcInfo = HyperCoreLib.tokenInfo(HyperCoreLib.USDC_TOKEN);
        if (usdcEvmAsset != usdcInfo.evmContract && !_isDepositWalletFor(usdcInfo.evmContract, usdcEvmAsset)) {
            revert HyperCoreMarginFuseUsdcTokenMismatch();
        }

        (bool capSet, uint240 cap) = HyperCoreSubstrateLib.getConfig(
            MARKET_ID,
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6
        );
        if (!capSet || cap == 0) {
            revert HyperCoreMarginFuseCapUnset();
        }
        if (uint240(data_.usd6) > cap) {
            revert HyperCoreMarginFuseExceedsCap(data_.usd6, cap);
        }

        if (data_.toPerp) {
            // Spot USDC balance is reported in USDC's own Core `weiDecimals` while usd6 is fixed at 6
            // decimals: fail closed on any USDC scale this fuse cannot safely reason about, rather than
            // hardcoding a network-specific factor.
            if (usdcInfo.weiDecimals < 6 || usdcInfo.weiDecimals > 18) {
                revert HyperCoreMarginFuseUnexpectedUsdcScale(usdcInfo.weiDecimals);
            }
            uint256 factor = 10 ** (uint256(usdcInfo.weiDecimals) - 6);
            HyperCoreLib.SpotBalance memory balance = HyperCoreLib.spotBalance(address(this), HyperCoreLib.USDC_TOKEN);
            uint256 available = uint256(balance.total) - uint256(balance.hold);
            uint256 required = uint256(data_.usd6) * factor;
            if (available < required) {
                revert HyperCoreMarginFuseInsufficientSpotBalance(available, required);
            }
        } else {
            // `withdrawable()` (0x803) returns the native perp account's withdrawable USD with 6 decimals
            // (checked on HyperEVM mainnet: 22.0 USDC withdrawable reads 22000000, IL-8902).
            uint64 available = HyperCoreLib.withdrawable(address(this));
            if (available < data_.usd6) {
                revert HyperCoreMarginFuseInsufficientWithdrawable(available, data_.usd6);
            }
        }

        uint256 s = HyperCoreValuationLib.liveValueWad(MARKET_ID);

        bytes memory payload = HyperCoreLib.encodeUsdClassTransfer(data_.usd6, data_.toPerp);
        HyperCoreLib.sendRawAction(payload);

        HyperCorePendingLib.enqueue(
            s,
            _windowTransfer(),
            HyperCoreLib.ACTION_USD_CLASS_TRANSFER,
            keccak256(payload)
        );

        emit HyperCoreMarginFuseEnter(VERSION, data_.usd6, data_.toPerp);
    }

    /// @dev Hyperliquid routes HyperCore token 0 (USDC) through a CoreDepositWallet contract on every
    ///      network where USDC is CCTP-native, so `tokenInfo(0).evmContract` may be that wallet's
    ///      proxy address rather than the USDC ERC20 itself. Accepts the grant when the wallet's
    ///      `token()` matches the granted EVM asset. Any revert from `token()` (not a wallet, EOA,
    ///      etc.) is treated as no match rather than as an error, since the plain equality check
    ///      already failed and this is only a secondary allowance.
    function _isDepositWalletFor(address evmContract_, address grantedEvmAsset_) internal view returns (bool) {
        try ICoreDepositWallet(evmContract_).token() returns (address token_) {
            return token_ == grantedEvmAsset_;
        } catch {
            return false;
        }
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
            revert HyperCoreMarginFuseInvalidWindow(value);
        }
        return uint64(value);
    }
}
