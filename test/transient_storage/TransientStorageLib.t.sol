// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TransientStorageLib} from "../../contracts/transient_storage/TransientStorageLib.sol";
import {TransientStorageLibMock} from "./TransientStorageLibMock.sol";

/// @title TransientStorageLibTest
/// @notice Tests for TransientStorageLib
/// @author IPOR Labs
contract TransientStorageLibTest is Test {
    /// @notice Mock contract for testing library internal functions
    TransientStorageLibMock public mock;

    /// @notice Setup the test environment
    function setUp() public {
        mock = new TransientStorageLibMock();
    }

    /// @notice Test setting and getting inputs
    function testSetAndGetInputs() public {
        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = bytes32(uint256(1));
        inputs[1] = bytes32(uint256(2));
        inputs[2] = bytes32(uint256(3));

        mock.setInputs(address(this), inputs);

        bytes32[] memory storedInputs = mock.getInputs(address(this));
        assertEq(storedInputs.length, 3);
        assertEq(storedInputs[0], inputs[0]);
        assertEq(storedInputs[1], inputs[1]);
        assertEq(storedInputs[2], inputs[2]);
    }

    /// @notice Test setting and getting single input
    function testSetAndGetInput() public {
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = bytes32(uint256(10));
        inputs[1] = bytes32(uint256(20));
        mock.setInputs(address(this), inputs);

        // Update index 1
        bytes32 newValue = bytes32(uint256(99));
        mock.setInput(address(this), 1, newValue);

        bytes32 storedValue = mock.getInput(address(this), 1);
        assertEq(storedValue, newValue);

        // Check other value remains
        assertEq(mock.getInput(address(this), 0), inputs[0]);
    }

    /// @notice Test setting input out of bounds
    function testSetInputOutOfBounds() public {
        // Initial empty inputs
        bytes32[] memory inputs = new bytes32[](0);
        mock.setInputs(address(this), inputs);

        // Set at index 5 (out of bounds of length 0)
        bytes32 val = bytes32(uint256(123));

        vm.expectRevert(abi.encodeWithSelector(TransientStorageLib.TransientStorageError.selector, 5, 0));
        mock.setInput(address(this), 5, val);

        vm.expectRevert(abi.encodeWithSelector(TransientStorageLib.TransientStorageError.selector, 5, 0));
        mock.getInput(address(this), 5);
    }

    /// @notice Test setting and getting outputs
    function testSetAndGetOutputs() public {
        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = bytes32(uint256(100));
        outputs[1] = bytes32(uint256(200));

        mock.setOutputs(address(this), outputs);

        bytes32[] memory storedOutputs = mock.getOutputs(address(this));
        assertEq(storedOutputs.length, 2);
        assertEq(storedOutputs[0], outputs[0]);
        assertEq(storedOutputs[1], outputs[1]);
    }

    /// @notice Test setting and getting single output
    function testSetAndGetOutput() public {
        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = bytes32(uint256(50));
        mock.setOutputs(address(this), outputs);

        assertEq(mock.getOutput(address(this), 0), outputs[0]);
    }

    /// @notice Test clearing outputs
    function testClearOutputs() public {
        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = keccak256("test1");
        outputs[1] = keccak256("test2");

        mock.setOutputs(address(this), outputs);
        assertEq(mock.getOutputs(address(this)).length, 2);

        mock.clearOutputs(address(this));

        bytes32[] memory storedOutputs = mock.getOutputs(address(this));
        assertEq(storedOutputs.length, 0);

        // Verify elements are cleared
        vm.expectRevert(abi.encodeWithSelector(TransientStorageLib.TransientStorageError.selector, 0, 0));
        mock.getOutput(address(this), 0);

        vm.expectRevert(abi.encodeWithSelector(TransientStorageLib.TransientStorageError.selector, 1, 0));
        mock.getOutput(address(this), 1);
    }

    /// @notice Test account isolation
    function testAccountIsolation() public {
        address account1 = address(0x1);
        address account2 = address(0x2);

        bytes32[] memory inputs1 = new bytes32[](1);
        inputs1[0] = bytes32(uint256(111));

        bytes32[] memory inputs2 = new bytes32[](1);
        inputs2[0] = bytes32(uint256(222));

        mock.setInputs(account1, inputs1);
        mock.setInputs(account2, inputs2);

        assertEq(mock.getInputs(account1)[0], inputs1[0]);
        assertEq(mock.getInputs(account2)[0], inputs2[0]);
    }

    /// @notice Test input and output isolation
    function testInputOutputIsolation() public {
        bytes32[] memory inputData = new bytes32[](1);
        inputData[0] = bytes32(uint256(12345));

        bytes32[] memory outputData = new bytes32[](1);
        outputData[0] = bytes32(uint256(67890));

        mock.setInputs(address(this), inputData);

        // Outputs should be empty
        assertEq(mock.getOutputs(address(this)).length, 0);

        mock.setOutputs(address(this), outputData);

        // Inputs should remain unchanged
        assertEq(mock.getInputs(address(this))[0], inputData[0]);
        assertEq(mock.getOutputs(address(this))[0], outputData[0]);
    }

    /// @notice Test clearing inputs
    function testClearInputs() public {
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = keccak256("test1");
        inputs[1] = keccak256("test2");

        mock.setInputs(address(this), inputs);
        assertEq(mock.getInputs(address(this)).length, 2);

        mock.clearInputs(address(this));

        bytes32[] memory storedInputs = mock.getInputs(address(this));
        assertEq(storedInputs.length, 0);

        // Verify elements are cleared
        vm.expectRevert(abi.encodeWithSelector(TransientStorageLib.TransientStorageError.selector, 0, 0));
        mock.getInput(address(this), 0);

        vm.expectRevert(abi.encodeWithSelector(TransientStorageLib.TransientStorageError.selector, 1, 0));
        mock.getInput(address(this), 1);
    }
}
