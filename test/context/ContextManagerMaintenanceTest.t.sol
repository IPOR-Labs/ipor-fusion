// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContextManagerInitSetup} from "./ContextManagerInitSetup.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {ContextManager, ContextDataWithSender} from "../../contracts/managers/context/ContextManager.sol";

contract ContextManagerMaintenanceTest is Test, ContextManagerInitSetup {
    // Test events
    event ApprovedAddressAdded(address indexed addr);
    event ApprovedAddressRemoved(address indexed addr);

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
        emit ApprovedAddressAdded(addresses[0]);
        vm.expectEmit(true, false, false, false);
        emit ApprovedAddressAdded(addresses[1]);

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
        emit ApprovedAddressRemoved(addresses[0]);
        vm.expectEmit(true, false, false, false);
        emit ApprovedAddressRemoved(addresses[1]);

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
        emit ApprovedAddressRemoved(removeAddresses[0]);
        vm.expectEmit(true, false, false, false);
        emit ApprovedAddressRemoved(removeAddresses[1]);

        vm.prank(address(TestAddresses.ATOMIST));
        uint256 removedCount = _contextManager.removeApprovedAddresses(removeAddresses);

        // Should only count actually removed addresses
        assertEq(removedCount, 2, "Should only count actually removed addresses");

        // Verify final state
        assertFalse(_contextManager.isApproved(removeAddresses[0]), "First address should be removed");
        assertFalse(_contextManager.isApproved(removeAddresses[1]), "Second address should be removed");
        assertFalse(_contextManager.isApproved(removeAddresses[2]), "Third address should not exist");
    }

    function testRevertWhenSenderNotMatchSignature() public {
        // Create test data
        address actualSigner = makeAddr("actual_signer");
        uint256 signerPrivateKey = 0x1234; // Test private key
        vm.deal(actualSigner, 100 ether);

        // Create a mock approved target
        address mockTarget = makeAddr("mock_target");
        address[] memory approvedAddrs = new address[](1);
        approvedAddrs[0] = mockTarget;

        vm.prank(address(TestAddresses.ATOMIST));
        _contextManager.addApprovedAddresses(approvedAddrs);

        // Prepare context data
        ContextDataWithSender[] memory contextDataArray = new ContextDataWithSender[](1);

        bytes memory callData = abi.encodeWithSignature("someFunction()");
        uint256 expirationTime = block.timestamp + 3600; // 1 hour from now
        uint256 nonce = _contextManager.getNonce(actualSigner);

        // Create message hash
        bytes32 messageHash = keccak256(abi.encodePacked(expirationTime, nonce, mockTarget, callData));

        // Sign message with actual signer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Create context data with different sender than signer
        contextDataArray[0] = ContextDataWithSender({
            sender: makeAddr("different_sender"), // Different address than the signer
            expirationTime: expirationTime,
            nonce: nonce,
            target: mockTarget,
            data: callData,
            signature: signature
        });

        // Expect revert with InvalidSignature
        vm.expectRevert(abi.encodeWithSignature("InvalidSignature()"));

        // Execute with different sender
        _contextManager.runWithContextAndSignature(contextDataArray);
    }

    function testRevertWhenSignatureExpired() public {
        // Create test data
        address signer = makeAddr("signer");
        uint256 signerPrivateKey = 0x1234;
        vm.deal(signer, 100 ether);

        // Create a mock approved target
        address mockTarget = makeAddr("mock_target");
        address[] memory approvedAddrs = new address[](1);
        approvedAddrs[0] = mockTarget;

        vm.prank(address(TestAddresses.ATOMIST));
        _contextManager.addApprovedAddresses(approvedAddrs);

        // Prepare context data
        ContextDataWithSender[] memory contextDataArray = new ContextDataWithSender[](1);

        bytes memory callData = abi.encodeWithSignature("someFunction()");
        uint256 expirationTime = block.timestamp - 1; // Expired timestamp
        uint256 nonce = _contextManager.getNonce(signer);

        // Create message hash
        bytes32 messageHash = keccak256(abi.encodePacked(expirationTime, nonce, mockTarget, callData));

        // Sign message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Create context data
        contextDataArray[0] = ContextDataWithSender({
            sender: signer,
            expirationTime: expirationTime,
            nonce: nonce,
            target: mockTarget,
            data: callData,
            signature: signature
        });

        // Expect revert with SignatureExpired
        vm.expectRevert(abi.encodeWithSignature("SignatureExpired()"));

        // Execute with expired signature
        _contextManager.runWithContextAndSignature(contextDataArray);
    }

    function _createSignedContextData(
        address signer,
        uint256 signerPrivateKey,
        address target,
        uint256 expirationTime,
        uint256 nonce
    ) internal view returns (ContextDataWithSender memory contextData) {
        bytes memory callData = abi.encodeWithSignature("someFunction()");
        bytes32 messageHash = keccak256(
            abi.encodePacked(expirationTime, nonce, TestAddresses.BASE_CHAIN_ID, target, callData)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        contextData = ContextDataWithSender({
            sender: signer,
            expirationTime: expirationTime,
            nonce: nonce,
            target: target,
            data: callData,
            signature: signature
        });
    }

    function testRevertWhenNonceTooLow() public {
        // Setup test data
        uint256 signerPrivateKey = 0x1234;
        address signer = vm.addr(signerPrivateKey);
        address mockTarget = makeAddr("mock_target");

        // Approve target
        address[] memory approvedAddrs = new address[](1);
        approvedAddrs[0] = mockTarget;
        vm.prank(address(TestAddresses.ATOMIST));
        _contextManager.addApprovedAddresses(approvedAddrs);

        // Setup first transaction
        uint256 expirationTime = block.timestamp + 3600;
        uint256 currentNonce = _contextManager.getNonce(signer);

        // Try to execute with the same nonce
        ContextDataWithSender[] memory secondContextData = new ContextDataWithSender[](1);
        secondContextData[0] = _createSignedContextData(
            signer,
            signerPrivateKey,
            mockTarget,
            expirationTime,
            currentNonce // Using the old nonce
        );

        // Expect revert with NonceTooLow
        vm.expectRevert(abi.encodeWithSignature("NonceTooLow()"));
        _contextManager.runWithContextAndSignature(secondContextData);
    }
}
