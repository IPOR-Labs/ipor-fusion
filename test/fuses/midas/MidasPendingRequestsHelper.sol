// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MidasPendingRequestsStorageLib} from "../../../contracts/fuses/midas/lib/MidasPendingRequestsStorageLib.sol";

/// @notice Helper contract for testing MidasPendingRequestsStorageLib via delegatecall
/// @dev Call via PlasmaVaultMock.execute() to manipulate storage in vault's context
contract MidasPendingRequestsHelper {
    function addPendingDeposit(address depositVault_, uint256 requestId_) external {
        MidasPendingRequestsStorageLib.addPendingDeposit(depositVault_, requestId_);
    }

    function removePendingDeposit(address depositVault_, uint256 requestId_) external {
        MidasPendingRequestsStorageLib.removePendingDeposit(depositVault_, requestId_);
    }

    function addPendingRedemption(address redemptionVault_, uint256 requestId_) external {
        MidasPendingRequestsStorageLib.addPendingRedemption(redemptionVault_, requestId_);
    }

    function removePendingRedemption(address redemptionVault_, uint256 requestId_) external {
        MidasPendingRequestsStorageLib.removePendingRedemption(redemptionVault_, requestId_);
    }

    function getPendingDeposits()
        external
        view
        returns (address[] memory vaults, uint256[][] memory requestIds)
    {
        return MidasPendingRequestsStorageLib.getPendingDeposits();
    }

    function getPendingRedemptions()
        external
        view
        returns (address[] memory vaults, uint256[][] memory requestIds)
    {
        return MidasPendingRequestsStorageLib.getPendingRedemptions();
    }

    function getPendingDepositsForVault(address depositVault_) external view returns (uint256[] memory) {
        return MidasPendingRequestsStorageLib.getPendingDepositsForVault(depositVault_);
    }

    function getPendingRedemptionsForVault(address redemptionVault_) external view returns (uint256[] memory) {
        return MidasPendingRequestsStorageLib.getPendingRedemptionsForVault(redemptionVault_);
    }

    function isDepositPending(address depositVault_, uint256 requestId_) external view returns (bool) {
        return MidasPendingRequestsStorageLib.isDepositPending(depositVault_, requestId_);
    }

    function isRedemptionPending(address redemptionVault_, uint256 requestId_) external view returns (bool) {
        return MidasPendingRequestsStorageLib.isRedemptionPending(redemptionVault_, requestId_);
    }
}
