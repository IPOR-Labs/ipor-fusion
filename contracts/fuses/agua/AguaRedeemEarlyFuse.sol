// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IAguaGlobalCarryVault} from "./ext/IAguaGlobalCarryVault.sol";
import {AguaSubstrateLib} from "./lib/AguaSubstrateLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice Data structure for entering AguaRedeemEarlyFuse (instant early redemption)
struct AguaRedeemEarlyFuseEnterData {
    /// @dev Agua Global Carry Vault address
    address vault;
    /// @dev amount of shares to redeem instantly
    uint256 shares;
    /// @dev minimum acceptable underlying assets (slippage protection)
    uint256 minAssetsOut;
}

/// @title AguaRedeemEarlyFuse
/// @notice Fuse for instantly redeeming Agua Global Carry Vault shares for underlying assets,
///         charging the early-redemption fee and bypassing the async lockup.
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Because each fuse runs via delegatecall, the PlasmaVault is the Agua holder and receiver —
///      no executor/silo is required. Operates on free shares only, independent of any pending request.
///      This fuse deliberately does NOT implement IFuseInstantWithdraw: even though `redeemEarly` is
///      economically instant, there is no `instantWithdraw(bytes32[])` selector, so a PlasmaVault
///      redemption can never auto-trigger an Agua exit (redemption DoS impossible). The fee path is
///      only reachable via an explicit, slippage-guarded alpha action.
contract AguaRedeemEarlyFuse is IFuseCommon {
    /// @notice Emitted when an instant early redemption succeeds
    /// @param version The address of this fuse contract version
    /// @param vault The Agua vault redeemed from
    /// @param shares The amount of shares redeemed
    /// @param assets The amount of underlying assets paid to the PlasmaVault (net of fee)
    event AguaRedeemEarlyFuseRedeemed(address version, address vault, uint256 shares, uint256 assets);

    /// @notice Address of this fuse contract version
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the fuse with a specific market ID
    /// @param marketId_ The market ID used to identify the Agua vault substrates
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Instantly redeem shares for underlying assets, charging the early redemption fee
    /// @dev Clamps shares to the PlasmaVault's share balance. The Agua vault enforces `minAssetsOut`
    ///      and reverts `RedeemSlippageExceeded` if the payout is below it.
    /// @param data_ The enter data containing vault, shares and minAssetsOut
    function enter(AguaRedeemEarlyFuseEnterData memory data_) external {
        AguaSubstrateLib.validateVaultGranted(MARKET_ID, data_.vault);

        uint256 shares = IporMath.min(data_.shares, IAguaGlobalCarryVault(data_.vault).balanceOf(address(this)));

        if (shares == 0) {
            return;
        }

        uint256 assets = IAguaGlobalCarryVault(data_.vault).redeemEarly(shares, address(this), data_.minAssetsOut);

        emit AguaRedeemEarlyFuseRedeemed(VERSION, data_.vault, shares, assets);
    }
}
