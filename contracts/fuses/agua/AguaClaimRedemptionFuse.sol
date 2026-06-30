// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IAguaGlobalCarryVault} from "./ext/IAguaGlobalCarryVault.sol";
import {AguaSubstrateLib} from "./lib/AguaSubstrateLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice Data structure for entering AguaClaimRedemptionFuse (complete an unlocked redemption request)
struct AguaClaimRedemptionFuseEnterData {
    /// @dev Agua Global Carry Vault address
    address vault;
}

/// @title AguaClaimRedemptionFuse
/// @notice Fuse for completing (claiming) an unlocked asynchronous redemption request on Reservoir's
///         Agua Global Carry Vault, paying the frozen underlying payout to the PlasmaVault.
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Because each fuse runs via delegatecall, the PlasmaVault is the Agua holder and receiver —
///      no executor/silo is required.
///      This fuse deliberately does NOT implement IFuseInstantWithdraw: there is no
///      `instantWithdraw(bytes32[])` selector, so a PlasmaVault redemption can never auto-trigger an
///      Agua exit (redemption DoS impossible).
contract AguaClaimRedemptionFuse is IFuseCommon {
    /// @notice Emitted when an unlocked redemption request is completed
    /// @param version The address of this fuse contract version
    /// @param vault The Agua vault the request was completed on
    /// @param assets The amount of underlying assets paid to the PlasmaVault
    event AguaClaimRedemptionFuseCompleted(address version, address vault, uint256 assets);

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

    /// @notice Complete an unlocked redemption request, paying underlying assets to the PlasmaVault
    /// @dev Agua enforces the unlock time and reverts if the request is not yet completable
    ///      (`LockupNotFinished`) or absent (`NoActiveRequest`).
    /// @param data_ The enter data containing vault
    function enter(AguaClaimRedemptionFuseEnterData memory data_) external {
        AguaSubstrateLib.validateVaultGranted(MARKET_ID, data_.vault);

        uint256 assets = IAguaGlobalCarryVault(data_.vault).completeRedemption(address(this));

        emit AguaClaimRedemptionFuseCompleted(VERSION, data_.vault, assets);
    }
}
