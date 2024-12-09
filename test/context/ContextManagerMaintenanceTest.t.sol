// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ContextManagerInitSetup} from "./ContextManagerInitSetup.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
contract ContextManagerMaintenanceTest is Test, ContextManagerInitSetup {
    // Test events
    event AddressApproved(address indexed addr);
    event AddressRemoved(address indexed addr);

    function setUp() public {
        initSetup();
    }

    function testRevertWhenAddEmptyApprovedAddressesList() public {
        // given
        address[] memory emptyAddresses = new address[](0);

        bytes memory error = abi.encodeWithSignature("EmptyArrayNotAllowed()");

        // when
        vm.expectRevert(error);
        vm.prank(address(TestAddresses.ATOMIST));
        _contextManager.addApprovedAddresses(emptyAddresses);
    }

    function testRevertWhenAddApprovedAddressesNotByAtomist() public {
        // given
        address[] memory addresses = new address[](1);
        addresses[0] = makeAddr("random_address");

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", TestAddresses.USER);

        // when
        vm.expectRevert(error);
        vm.prank(TestAddresses.USER);
        _contextManager.addApprovedAddresses(addresses);
    }

    function testAddApprovedAddressesHappyPath() public {
        address[] memory addresses = new address[](2);
        addresses[0] = makeAddr("random_address1");
        addresses[1] = makeAddr("random_address2");

        // Expect events for each address
        vm.expectEmit(true, false, false, false);
        emit AddressApproved(addresses[0]);
        vm.expectEmit(true, false, false, false);
        emit AddressApproved(addresses[1]);

        // Execute as protocol owner
        vm.prank(address(TestAddresses.ATOMIST));
        uint256 approvedCount = _contextManager.addApprovedAddresses(addresses);

        // Verify return value
        assertEq(approvedCount, 2, "Should return correct number of newly approved addresses");

        // Verify addresses were actually approved
        assertTrue(_contextManager.isApproved(addresses[0]), "First address should be approved");
        assertTrue(_contextManager.isApproved(addresses[1]), "Second address should be approved");
    }

    function testAddAlreadyApprovedAddress() public {
        address[] memory addresses = new address[](1);
        addresses[0] = makeAddr("random_address");

        // First approval
        vm.prank(address(TestAddresses.ATOMIST));
        uint256 firstApprovalCount = _contextManager.addApprovedAddresses(addresses);
        assertEq(firstApprovalCount, 1, "First approval should count as 1");

        // Second approval of same address
        vm.prank(address(TestAddresses.ATOMIST));
        uint256 secondApprovalCount = _contextManager.addApprovedAddresses(addresses);
        assertEq(secondApprovalCount, 0, "Second approval should count as 0");
    }

    function testRemoveApprovedAddressesHappyPath() public {
        // Setup - first add some addresses
        address[] memory addresses = new address[](2);
        addresses[0] = makeAddr("random_address1");
        addresses[1] = makeAddr("random_address2");

        vm.prank(address(TestAddresses.ATOMIST));
        _contextManager.addApprovedAddresses(addresses);

        // Expect events for each address removal
        vm.expectEmit(true, false, false, false);
        emit AddressRemoved(addresses[0]);
        vm.expectEmit(true, false, false, false);
        emit AddressRemoved(addresses[1]);

        // Execute removal as protocol owner
        vm.prank(address(TestAddresses.ATOMIST));
        uint256 removedCount = _contextManager.removeApprovedAddresses(addresses);

        // Verify return value
        assertEq(removedCount, 2, "Should return correct number of removed addresses");

        // Verify addresses were actually removed
        assertFalse(_contextManager.isApproved(addresses[0]), "First address should not be approved");
        assertFalse(_contextManager.isApproved(addresses[1]), "Second address should not be approved");
    }

    function testRemoveNonExistentApprovedAddresses() public {
        // Try to remove addresses that were never approved
        address[] memory addresses = new address[](2);
        addresses[0] = makeAddr("non_existent1");
        addresses[1] = makeAddr("non_existent2");

        vm.prank(address(TestAddresses.ATOMIST));
        uint256 removedCount = _contextManager.removeApprovedAddresses(addresses);

        // Should return 0 as no addresses were actually removed
        assertEq(removedCount, 0, "Should return 0 for non-existent addresses");
    }

    function testRevertWhenRemoveApprovedAddressesNotByAtomist() public {
        address[] memory addresses = new address[](1);
        addresses[0] = makeAddr("random_address");

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", TestAddresses.USER);

        vm.expectRevert(error);
        vm.prank(TestAddresses.USER);
        _contextManager.removeApprovedAddresses(addresses);
    }

    function testPartialRemovalOfApprovedAddresses() public {
        // Setup - add two addresses
        address[] memory addAddresses = new address[](2);
        addAddresses[0] = makeAddr("approved1");
        addAddresses[1] = makeAddr("approved2");

        vm.prank(address(TestAddresses.ATOMIST));
        _contextManager.addApprovedAddresses(addAddresses);

        // Try to remove three addresses (two existing, one non-existent)
        address[] memory removeAddresses = new address[](3);
        removeAddresses[0] = addAddresses[0];
        removeAddresses[1] = addAddresses[1];
        removeAddresses[2] = makeAddr("non_existent");

        // Expect events only for the existing addresses
        vm.expectEmit(true, false, false, false);
        emit AddressRemoved(removeAddresses[0]);
        vm.expectEmit(true, false, false, false);
        emit AddressRemoved(removeAddresses[1]);

        vm.prank(address(TestAddresses.ATOMIST));
        uint256 removedCount = _contextManager.removeApprovedAddresses(removeAddresses);

        // Should only count actually removed addresses
        assertEq(removedCount, 2, "Should only count actually removed addresses");

        // Verify final state
        assertFalse(_contextManager.isApproved(removeAddresses[0]), "First address should be removed");
        assertFalse(_contextManager.isApproved(removeAddresses[1]), "Second address should be removed");
        assertFalse(_contextManager.isApproved(removeAddresses[2]), "Third address should not exist");
    }
}
