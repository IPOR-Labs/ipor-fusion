// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";

/// @title TransientStorageSetInputsFuseTest
/// @notice Tests for TransientStorageSetInputsFuse
/// @author IPOR Labs
contract TransientStorageSetInputsFuseTest is Test {
    using Address for address;

    /// @notice The fuse contract being tested
    TransientStorageSetInputsFuse public fuse;

    /// @notice Setup the test environment
    function setUp() public {
        fuse = new TransientStorageSetInputsFuse();
    }

    /// @notice Test successful entry with valid data
    function testEnterSuccess() public {
        address fuse1 = address(0x1);
        address fuse2 = address(0x2);

        bytes32[] memory inputs1 = new bytes32[](2);
        inputs1[0] = bytes32(uint256(1));
        inputs1[1] = bytes32(uint256(2));

        bytes32[] memory inputs2 = new bytes32[](1);
        inputs2[0] = bytes32(uint256(3));

        address[] memory fuses = new address[](2);
        fuses[0] = fuse1;
        fuses[1] = fuse2;

        bytes32[][] memory inputsByFuse = new bytes32[][](2);
        inputsByFuse[0] = inputs1;
        inputsByFuse[1] = inputs2;

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        // Execute enter via delegatecall to simulate vault execution
        // The storage will be on this contract
        address(fuse).functionDelegateCall(abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, data));

        // Verify
        bytes32[] memory storedInputs1 = TransientStorageLib.getInputs(fuse1);
        assertEq(storedInputs1.length, 2);
        assertEq(storedInputs1[0], inputs1[0]);
        assertEq(storedInputs1[1], inputs1[1]);

        bytes32[] memory storedInputs2 = TransientStorageLib.getInputs(fuse2);
        assertEq(storedInputs2.length, 1);
        assertEq(storedInputs2[0], inputs2[0]);
    }

    /// @notice Test revert when fuse address is zero
    function testEnterRevertWrongFuseAddress() public {
        address[] memory fuses = new address[](1);
        fuses[0] = address(0); // Invalid

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = bytes32(uint256(1));

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        vm.expectRevert(TransientStorageSetInputsFuse.WrongFuseAddress.selector);
        address(fuse).functionDelegateCall(abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, data));
    }

    /// @notice Test revert when inputs length is zero
    function testEnterRevertWrongInputsLength() public {
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x1);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](0); // Empty inputs

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        vm.expectRevert(TransientStorageSetInputsFuse.WrongInputsLength.selector);
        address(fuse).functionDelegateCall(abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, data));
    }

    /// @notice Test exit function (no-op)
    function testExit() public {
        bytes memory data = "";
        // exit is pure and does nothing, but we check it doesn't revert
        address(fuse).functionDelegateCall(abi.encodeWithSelector(TransientStorageSetInputsFuse.exit.selector, data));
    }
}
