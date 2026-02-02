// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MidasPendingRequestsStorageLib} from "../../../contracts/fuses/midas/lib/MidasPendingRequestsStorageLib.sol";
import {MidasPendingRequestsHelper} from "./MidasPendingRequestsHelper.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title MidasPendingRequestsStorageLibTest
/// @notice Tests for MidasPendingRequestsStorageLib through delegatecall via PlasmaVaultMock
contract MidasPendingRequestsStorageLibTest is Test {
    address public constant DEPOSIT_VAULT_A = address(0xD001);
    address public constant DEPOSIT_VAULT_B = address(0xD002);
    address public constant REDEMPTION_VAULT_A = address(0xE001);
    address public constant REDEMPTION_VAULT_B = address(0xE002);

    MidasPendingRequestsHelper public helper;
    PlasmaVaultMock public vault;

    function setUp() public {
        helper = new MidasPendingRequestsHelper();
        vault = new PlasmaVaultMock(address(helper), address(0));

        vm.label(address(helper), "MidasPendingRequestsHelper");
        vm.label(address(vault), "PlasmaVaultMock");
    }

    // ============ Helpers ============

    function _addPendingDeposit(address depositVault_, uint256 requestId_) internal {
        vault.execute(
            address(helper),
            abi.encodeWithSelector(MidasPendingRequestsHelper.addPendingDeposit.selector, depositVault_, requestId_)
        );
    }

    function _removePendingDeposit(address depositVault_, uint256 requestId_) internal {
        vault.execute(
            address(helper),
            abi.encodeWithSelector(MidasPendingRequestsHelper.removePendingDeposit.selector, depositVault_, requestId_)
        );
    }

    function _addPendingRedemption(address redemptionVault_, uint256 requestId_) internal {
        vault.execute(
            address(helper),
            abi.encodeWithSelector(
                MidasPendingRequestsHelper.addPendingRedemption.selector, redemptionVault_, requestId_
            )
        );
    }

    function _removePendingRedemption(address redemptionVault_, uint256 requestId_) internal {
        vault.execute(
            address(helper),
            abi.encodeWithSelector(
                MidasPendingRequestsHelper.removePendingRedemption.selector, redemptionVault_, requestId_
            )
        );
    }

    function _getPendingDeposits()
        internal
        returns (address[] memory vaults, uint256[][] memory requestIds)
    {
        bytes memory result = _staticDelegateCall(
            abi.encodeWithSelector(MidasPendingRequestsHelper.getPendingDeposits.selector)
        );
        return abi.decode(result, (address[], uint256[][]));
    }

    function _getPendingRedemptions()
        internal
        returns (address[] memory vaults, uint256[][] memory requestIds)
    {
        bytes memory result = _staticDelegateCall(
            abi.encodeWithSelector(MidasPendingRequestsHelper.getPendingRedemptions.selector)
        );
        return abi.decode(result, (address[], uint256[][]));
    }

    function _getPendingDepositsForVault(address depositVault_) internal returns (uint256[] memory) {
        bytes memory result = _staticDelegateCall(
            abi.encodeWithSelector(MidasPendingRequestsHelper.getPendingDepositsForVault.selector, depositVault_)
        );
        return abi.decode(result, (uint256[]));
    }

    function _getPendingRedemptionsForVault(address redemptionVault_) internal returns (uint256[] memory) {
        bytes memory result = _staticDelegateCall(
            abi.encodeWithSelector(MidasPendingRequestsHelper.getPendingRedemptionsForVault.selector, redemptionVault_)
        );
        return abi.decode(result, (uint256[]));
    }

    function _isDepositPending(address depositVault_, uint256 requestId_) internal returns (bool) {
        bytes memory result = _staticDelegateCall(
            abi.encodeWithSelector(MidasPendingRequestsHelper.isDepositPending.selector, depositVault_, requestId_)
        );
        return abi.decode(result, (bool));
    }

    function _isRedemptionPending(address redemptionVault_, uint256 requestId_) internal returns (bool) {
        bytes memory result = _staticDelegateCall(
            abi.encodeWithSelector(
                MidasPendingRequestsHelper.isRedemptionPending.selector, redemptionVault_, requestId_
            )
        );
        return abi.decode(result, (bool));
    }

    /// @dev Execute a view function on the helper via delegatecall from vault
    function _staticDelegateCall(bytes memory data_) internal returns (bytes memory) {
        // Use execute which does delegatecall - the helper reads from vault's storage
        // We wrap it in a call to capture return data
        (bool success, bytes memory returnData) =
            address(vault).call(abi.encodeWithSelector(PlasmaVaultMock.execute.selector, address(helper), data_));
        // execute doesn't return data, so we need a different approach
        // Use the fallback which does delegatecall and returns data
        (success, returnData) = address(vault).call(data_);
        require(success, "Delegatecall failed");
        return returnData;
    }

    // ============ Deposit Tests ============

    function testShouldAddPendingDeposit() public {
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);

        assertTrue(_isDepositPending(DEPOSIT_VAULT_A, 1), "Request 1 should be pending");
    }

    function testShouldAddPendingDepositsForMultipleVaults() public {
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);
        _addPendingDeposit(DEPOSIT_VAULT_B, 2);

        assertTrue(_isDepositPending(DEPOSIT_VAULT_A, 1), "Vault A request should be pending");
        assertTrue(_isDepositPending(DEPOSIT_VAULT_B, 2), "Vault B request should be pending");

        (address[] memory vaults, uint256[][] memory ids) = _getPendingDeposits();
        assertEq(vaults.length, 2, "Should have 2 deposit vaults");
    }

    function testShouldRemovePendingDeposit() public {
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);
        _addPendingDeposit(DEPOSIT_VAULT_A, 2);

        assertTrue(_isDepositPending(DEPOSIT_VAULT_A, 1), "Request 1 should be pending before removal");

        _removePendingDeposit(DEPOSIT_VAULT_A, 1);

        assertFalse(_isDepositPending(DEPOSIT_VAULT_A, 1), "Request 1 should not be pending after removal");
        assertTrue(_isDepositPending(DEPOSIT_VAULT_A, 2), "Request 2 should still be pending");
    }

    function testShouldRemoveDepositVaultWhenNoMoreRequestIds() public {
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);

        _removePendingDeposit(DEPOSIT_VAULT_A, 1);

        (address[] memory vaults,) = _getPendingDeposits();
        assertEq(vaults.length, 0, "Deposit vaults array should be empty after removing last request");
    }

    // ============ Redemption Tests ============

    function testShouldAddPendingRedemption() public {
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);

        assertTrue(_isRedemptionPending(REDEMPTION_VAULT_A, 1), "Redemption request 1 should be pending");
    }

    function testShouldAddPendingRedemptionsForMultipleVaults() public {
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);
        _addPendingRedemption(REDEMPTION_VAULT_B, 2);

        assertTrue(_isRedemptionPending(REDEMPTION_VAULT_A, 1), "Vault A redemption should be pending");
        assertTrue(_isRedemptionPending(REDEMPTION_VAULT_B, 2), "Vault B redemption should be pending");

        (address[] memory vaults,) = _getPendingRedemptions();
        assertEq(vaults.length, 2, "Should have 2 redemption vaults");
    }

    function testShouldRemovePendingRedemption() public {
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);
        _addPendingRedemption(REDEMPTION_VAULT_A, 2);

        _removePendingRedemption(REDEMPTION_VAULT_A, 1);

        assertFalse(_isRedemptionPending(REDEMPTION_VAULT_A, 1), "Request 1 should not be pending");
        assertTrue(_isRedemptionPending(REDEMPTION_VAULT_A, 2), "Request 2 should still be pending");
    }

    function testShouldRemoveRedemptionVaultWhenNoMoreRequestIds() public {
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);

        _removePendingRedemption(REDEMPTION_VAULT_A, 1);

        (address[] memory vaults,) = _getPendingRedemptions();
        assertEq(vaults.length, 0, "Redemption vaults should be empty after removing last request");
    }

    // ============ Query Tests ============

    function testShouldReturnAllPendingDeposits() public {
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);
        _addPendingDeposit(DEPOSIT_VAULT_A, 2);
        _addPendingDeposit(DEPOSIT_VAULT_B, 3);

        (address[] memory vaults, uint256[][] memory ids) = _getPendingDeposits();

        assertEq(vaults.length, 2, "Should have 2 deposit vaults");

        // Find which index is which vault
        uint256 totalIds;
        for (uint256 i; i < vaults.length; i++) {
            totalIds += ids[i].length;
        }
        assertEq(totalIds, 3, "Should have 3 total deposit request IDs");
    }

    function testShouldReturnAllPendingRedemptions() public {
        _addPendingRedemption(REDEMPTION_VAULT_A, 10);
        _addPendingRedemption(REDEMPTION_VAULT_A, 11);
        _addPendingRedemption(REDEMPTION_VAULT_B, 20);

        (address[] memory vaults, uint256[][] memory ids) = _getPendingRedemptions();

        assertEq(vaults.length, 2, "Should have 2 redemption vaults");

        uint256 totalIds;
        for (uint256 i; i < vaults.length; i++) {
            totalIds += ids[i].length;
        }
        assertEq(totalIds, 3, "Should have 3 total redemption request IDs");
    }

    function testShouldReturnPendingForSpecificVault() public {
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);
        _addPendingDeposit(DEPOSIT_VAULT_A, 2);
        _addPendingDeposit(DEPOSIT_VAULT_B, 3);

        uint256[] memory vaultAIds = _getPendingDepositsForVault(DEPOSIT_VAULT_A);
        assertEq(vaultAIds.length, 2, "Vault A should have 2 deposit request IDs");

        uint256[] memory vaultBIds = _getPendingDepositsForVault(DEPOSIT_VAULT_B);
        assertEq(vaultBIds.length, 1, "Vault B should have 1 deposit request ID");
    }

    function testShouldReportIsDepositPendingCorrectly() public {
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);

        assertTrue(_isDepositPending(DEPOSIT_VAULT_A, 1), "Request 1 should be pending");
        assertFalse(_isDepositPending(DEPOSIT_VAULT_A, 999), "Request 999 should not be pending");
        assertFalse(_isDepositPending(DEPOSIT_VAULT_B, 1), "Request 1 on different vault should not be pending");
    }

    function testShouldReportIsRedemptionPendingCorrectly() public {
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);

        assertTrue(_isRedemptionPending(REDEMPTION_VAULT_A, 1), "Request 1 should be pending");
        assertFalse(_isRedemptionPending(REDEMPTION_VAULT_A, 999), "Request 999 should not be pending");
        assertFalse(
            _isRedemptionPending(REDEMPTION_VAULT_B, 1), "Request 1 on different vault should not be pending"
        );
    }

    // ============ Error Tests ============

    function testShouldRevertWhenAddingDuplicateDepositRequestId() public {
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                DEPOSIT_VAULT_A,
                uint256(1)
            )
        );
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);
    }

    function testShouldRevertWhenAddingDuplicateRedemptionRequestId() public {
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                REDEMPTION_VAULT_A,
                uint256(1)
            )
        );
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);
    }

    function testShouldRevertWhenRemovingNonExistentRequestId() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestNotFound.selector,
                DEPOSIT_VAULT_A,
                uint256(999)
            )
        );
        _removePendingDeposit(DEPOSIT_VAULT_A, 999);
    }

    function testShouldRevertWhenRemovingNonExistentRedemptionRequestId() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestNotFound.selector,
                REDEMPTION_VAULT_A,
                uint256(999)
            )
        );
        _removePendingRedemption(REDEMPTION_VAULT_A, 999);
    }

    function testShouldRemoveNonFirstDepositRequestId() public {
        // Add 3 requests: [1, 2, 3]
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);
        _addPendingDeposit(DEPOSIT_VAULT_A, 2);
        _addPendingDeposit(DEPOSIT_VAULT_A, 3);

        // Remove request 3 (last element, requires iterating past 1 and 2)
        _removePendingDeposit(DEPOSIT_VAULT_A, 3);

        assertFalse(_isDepositPending(DEPOSIT_VAULT_A, 3), "Request 3 should be removed");
        assertTrue(_isDepositPending(DEPOSIT_VAULT_A, 1), "Request 1 should still be pending");
        assertTrue(_isDepositPending(DEPOSIT_VAULT_A, 2), "Request 2 should still be pending");
    }

    function testShouldRemoveNonFirstRedemptionRequestId() public {
        // Add 3 requests: [1, 2, 3]
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);
        _addPendingRedemption(REDEMPTION_VAULT_A, 2);
        _addPendingRedemption(REDEMPTION_VAULT_A, 3);

        // Remove request 3 (last element, requires iterating past 1 and 2)
        _removePendingRedemption(REDEMPTION_VAULT_A, 3);

        assertFalse(_isRedemptionPending(REDEMPTION_VAULT_A, 3), "Request 3 should be removed");
        assertTrue(_isRedemptionPending(REDEMPTION_VAULT_A, 1), "Request 1 should still be pending");
        assertTrue(_isRedemptionPending(REDEMPTION_VAULT_A, 2), "Request 2 should still be pending");
    }

    function testShouldReturnPendingRedemptionsForSpecificVault() public {
        _addPendingRedemption(REDEMPTION_VAULT_A, 10);
        _addPendingRedemption(REDEMPTION_VAULT_A, 11);
        _addPendingRedemption(REDEMPTION_VAULT_B, 20);

        uint256[] memory vaultAIds = _getPendingRedemptionsForVault(REDEMPTION_VAULT_A);
        assertEq(vaultAIds.length, 2, "Vault A should have 2 redemption request IDs");

        uint256[] memory vaultBIds = _getPendingRedemptionsForVault(REDEMPTION_VAULT_B);
        assertEq(vaultBIds.length, 1, "Vault B should have 1 redemption request ID");
    }

    function testShouldRemoveNonFirstDepositVaultFromArray() public {
        // Add requests to vault A then vault B — vault A is at index 0, vault B at index 1
        _addPendingDeposit(DEPOSIT_VAULT_A, 1);
        _addPendingDeposit(DEPOSIT_VAULT_B, 2);

        // Remove vault B's only request — triggers _removeDepositVault for vault at index 1
        _removePendingDeposit(DEPOSIT_VAULT_B, 2);

        (address[] memory vaults,) = _getPendingDeposits();
        assertEq(vaults.length, 1, "Should have 1 deposit vault remaining");
        assertEq(vaults[0], DEPOSIT_VAULT_A, "Remaining vault should be vault A");
    }

    function testShouldRemoveNonFirstRedemptionVaultFromArray() public {
        // Add requests to vault A then vault B — vault A is at index 0, vault B at index 1
        _addPendingRedemption(REDEMPTION_VAULT_A, 1);
        _addPendingRedemption(REDEMPTION_VAULT_B, 2);

        // Remove vault B's only request — triggers _removeRedemptionVault for vault at index 1
        _removePendingRedemption(REDEMPTION_VAULT_B, 2);

        (address[] memory vaults,) = _getPendingRedemptions();
        assertEq(vaults.length, 1, "Should have 1 redemption vault remaining");
        assertEq(vaults[0], REDEMPTION_VAULT_A, "Remaining vault should be vault A");
    }
}
