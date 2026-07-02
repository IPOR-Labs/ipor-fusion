// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IAguaGlobalCarryVault} from "./ext/IAguaGlobalCarryVault.sol";
import {AguaSubstrateLib} from "./lib/AguaSubstrateLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice Data structure for entering AguaRequestRedemptionFuse (submit async redemption request)
struct AguaRequestRedemptionFuseEnterData {
    /// @dev Agua Global Carry Vault address
    address vault;
    /// @dev amount of shares to request for redemption
    uint256 shares;
}

/// @notice Data structure for exiting AguaRequestRedemptionFuse (cancel the active redemption request)
struct AguaRequestRedemptionFuseExitData {
    /// @dev Agua Global Carry Vault address
    address vault;
}

/// @title AguaRequestRedemptionFuse
/// @notice Fuse for opening and cancelling an asynchronous redemption request on Reservoir's Agua
///         Global Carry Vault. `enter` submits the request (escrows shares); `exit` cancels it.
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Because each fuse runs via delegatecall, the PlasmaVault is the Agua holder and requester —
///      no executor/silo is required. The vault allows at most one active request per holder.
///      This fuse deliberately does NOT implement IFuseInstantWithdraw: there is no
///      `instantWithdraw(bytes32[])` selector, so a PlasmaVault redemption can never auto-trigger an
///      Agua exit (redemption DoS impossible).
contract AguaRequestRedemptionFuse is IFuseCommon {
    /// @notice Emitted when an async redemption request is submitted
    /// @param version The address of this fuse contract version
    /// @param vault The Agua vault the request was submitted to
    /// @param shares The amount of shares escrowed by the request
    event AguaRequestRedemptionFuseRequested(address version, address vault, uint256 shares);

    /// @notice Emitted when an active redemption request is cancelled
    /// @param version The address of this fuse contract version
    /// @param vault The Agua vault the request was cancelled on
    event AguaRequestRedemptionFuseCancelled(address version, address vault);

    /// @notice Thrown when a redemption request is submitted while one is already active
    /// @param vault The Agua vault that already has an active request
    error AguaRequestRedemptionFuseRequestAlreadyActive(address vault);

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

    /// @notice Submit an async redemption request, escrowing shares inside the Agua vault
    /// @dev Clamps shares to the PlasmaVault's share balance. Reverts with a typed error if a
    ///      request is already active (Agua allows only one active request per holder).
    /// @param data_ The enter data containing vault and shares
    function enter(AguaRequestRedemptionFuseEnterData memory data_) external {
        AguaSubstrateLib.validateVaultGranted(MARKET_ID, data_.vault);

        uint256 shares = IporMath.min(data_.shares, IAguaGlobalCarryVault(data_.vault).balanceOf(address(this)));

        if (shares == 0) {
            return;
        }

        (uint256 activeShares, , , ) = IAguaGlobalCarryVault(data_.vault).getRedemptionRequest(address(this));
        if (activeShares != 0) {
            revert AguaRequestRedemptionFuseRequestAlreadyActive(data_.vault);
        }

        IAguaGlobalCarryVault(data_.vault).requestRedemption(shares);

        emit AguaRequestRedemptionFuseRequested(VERSION, data_.vault, shares);
    }

    /// @notice Cancel the active redemption request, returning escrowed shares to the PlasmaVault
    /// @dev Agua reverts `NoActiveRequest` if there is no active request.
    /// @param data_ The exit data containing vault
    function exit(AguaRequestRedemptionFuseExitData memory data_) external {
        AguaSubstrateLib.validateVaultGranted(MARKET_ID, data_.vault);

        IAguaGlobalCarryVault(data_.vault).cancelRedemption();

        emit AguaRequestRedemptionFuseCancelled(VERSION, data_.vault);
    }
}
