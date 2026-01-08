// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {TransientStorageSetInputsFuseMock} from "./TransientStorageSetInputsFuseMock.sol";

/// @title TransientStorageSetInputsFuseTest
/// @notice Tests for TransientStorageSetInputsFuse
/// @author IPOR Labs
contract TransientStorageSetInputsFuseTest is Test {
    /// @notice The fuse contract being tested
    TransientStorageSetInputsFuse public fuse;

    /// @notice The mock contract for executing fuse
    TransientStorageSetInputsFuseMock public mock;

    /// @notice Setup the test environment
    function setUp() public {
        fuse = new TransientStorageSetInputsFuse();
        mock = new TransientStorageSetInputsFuseMock(address(fuse));
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

        // Execute enter via mock contract to simulate vault execution
        mock.enter(data);

        // Verify - read from mock contract context
        bytes32[] memory storedInputs1 = mock.getInputs(fuse1);
        assertEq(storedInputs1.length, 2);
        assertEq(storedInputs1[0], inputs1[0]);
        assertEq(storedInputs1[1], inputs1[1]);

        bytes32[] memory storedInputs2 = mock.getInputs(fuse2);
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
        mock.enter(data);
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
        mock.enter(data);
    }

    /// @notice Test MARKET_ID constant value
    function testMarketId() public view {
        assertEq(fuse.MARKET_ID(), IporFusionMarkets.ERC20_VAULT_BALANCE);
    }

    /// @notice Test successful entry with single fuse
    function testEnterSuccessSingleFuse() public {
        address fuse1 = address(0x1);

        bytes32[] memory inputs1 = new bytes32[](3);
        inputs1[0] = bytes32(uint256(100));
        inputs1[1] = bytes32(uint256(200));
        inputs1[2] = bytes32(uint256(300));

        address[] memory fuses = new address[](1);
        fuses[0] = fuse1;

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs1;

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        mock.enter(data);

        bytes32[] memory storedInputs1 = mock.getInputs(fuse1);
        assertEq(storedInputs1.length, 3);
        assertEq(storedInputs1[0], inputs1[0]);
        assertEq(storedInputs1[1], inputs1[1]);
        assertEq(storedInputs1[2], inputs1[2]);
    }

    /// @notice Test successful entry with multiple fuses (3+)
    function testEnterSuccessMultipleFuses() public {
        address fuse1 = address(0x1);
        address fuse2 = address(0x2);
        address fuse3 = address(0x3);
        address fuse4 = address(0x4);

        bytes32[] memory inputs1 = new bytes32[](1);
        inputs1[0] = bytes32(uint256(1));
        bytes32[] memory inputs2 = new bytes32[](2);
        inputs2[0] = bytes32(uint256(2));
        inputs2[1] = bytes32(uint256(3));
        bytes32[] memory inputs3 = new bytes32[](3);
        inputs3[0] = bytes32(uint256(4));
        inputs3[1] = bytes32(uint256(5));
        inputs3[2] = bytes32(uint256(6));
        bytes32[] memory inputs4 = new bytes32[](1);
        inputs4[0] = bytes32(uint256(7));

        address[] memory fuses = new address[](4);
        fuses[0] = fuse1;
        fuses[1] = fuse2;
        fuses[2] = fuse3;
        fuses[3] = fuse4;

        bytes32[][] memory inputsByFuse = new bytes32[][](4);
        inputsByFuse[0] = inputs1;
        inputsByFuse[1] = inputs2;
        inputsByFuse[2] = inputs3;
        inputsByFuse[3] = inputs4;

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        mock.enter(data);

        bytes32[] memory storedInputs1 = mock.getInputs(fuse1);
        assertEq(storedInputs1.length, 1);
        assertEq(storedInputs1[0], inputs1[0]);
        bytes32[] memory storedInputs2 = mock.getInputs(fuse2);
        assertEq(storedInputs2.length, 2);
        assertEq(storedInputs2[0], inputs2[0]);
        assertEq(storedInputs2[1], inputs2[1]);
        bytes32[] memory storedInputs3 = mock.getInputs(fuse3);
        assertEq(storedInputs3.length, 3);
        assertEq(storedInputs3[0], inputs3[0]);
        assertEq(storedInputs3[1], inputs3[1]);
        assertEq(storedInputs3[2], inputs3[2]);
        assertEq(mock.getInputs(fuse4).length, 1);
        assertEq(mock.getInputs(fuse4)[0], inputs4[0]);
    }

    /// @notice Test overwriting inputs for the same fuse
    function testEnterOverwriteInputs() public {
        address fuse1 = address(0x1);

        bytes32[] memory inputs1 = new bytes32[](2);
        inputs1[0] = bytes32(uint256(1));
        inputs1[1] = bytes32(uint256(2));

        address[] memory fuses = new address[](1);
        fuses[0] = fuse1;

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs1;

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        mock.enter(data);

        bytes32[] memory storedInputs1 = mock.getInputs(fuse1);
        assertEq(storedInputs1.length, 2);
        assertEq(storedInputs1[0], inputs1[0]);
        assertEq(storedInputs1[1], inputs1[1]);

        // Overwrite with new inputs
        bytes32[] memory inputs2 = new bytes32[](3);
        inputs2[0] = bytes32(uint256(100));
        inputs2[1] = bytes32(uint256(200));
        inputs2[2] = bytes32(uint256(300));

        inputsByFuse[0] = inputs2;
        data = TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse});

        mock.enter(data);

        bytes32[] memory storedInputs2 = mock.getInputs(fuse1);
        assertEq(storedInputs2.length, 3);
        assertEq(storedInputs2[0], inputs2[0]);
        assertEq(storedInputs2[1], inputs2[1]);
        assertEq(storedInputs2[2], inputs2[2]);
    }

    /// @notice Test with different bytes32 values (not just uint256)
    function testEnterWithDifferentBytes32Values() public {
        address fuse1 = address(0x1);

        bytes32[] memory inputs1 = new bytes32[](4);
        inputs1[0] = bytes32(uint256(123));
        inputs1[1] = keccak256("test string");
        inputs1[2] = bytes32(abi.encodePacked(address(0x1234)));
        inputs1[3] = bytes32(uint256(0xdeadbeef));

        address[] memory fuses = new address[](1);
        fuses[0] = fuse1;

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs1;

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        mock.enter(data);

        bytes32[] memory storedInputs1 = mock.getInputs(fuse1);
        assertEq(storedInputs1.length, 4);
        assertEq(storedInputs1[0], inputs1[0]);
        assertEq(storedInputs1[1], inputs1[1]);
        assertEq(storedInputs1[2], inputs1[2]);
        assertEq(storedInputs1[3], inputs1[3]);
    }

    /// @notice Test revert when fuse address is zero in the middle of array
    function testEnterRevertWrongFuseAddressMiddle() public {
        address[] memory fuses = new address[](3);
        fuses[0] = address(0x1);
        fuses[1] = address(0); // Invalid in middle
        fuses[2] = address(0x2);

        bytes32[][] memory inputsByFuse = new bytes32[][](3);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = bytes32(uint256(1));
        inputsByFuse[1] = new bytes32[](1);
        inputsByFuse[1][0] = bytes32(uint256(2));
        inputsByFuse[2] = new bytes32[](1);
        inputsByFuse[2][0] = bytes32(uint256(3));

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        vm.expectRevert(TransientStorageSetInputsFuse.WrongFuseAddress.selector);
        mock.enter(data);
    }

    /// @notice Test revert when fuse address is zero at the end of array
    function testEnterRevertWrongFuseAddressEnd() public {
        address[] memory fuses = new address[](3);
        fuses[0] = address(0x1);
        fuses[1] = address(0x2);
        fuses[2] = address(0); // Invalid at end

        bytes32[][] memory inputsByFuse = new bytes32[][](3);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = bytes32(uint256(1));
        inputsByFuse[1] = new bytes32[](1);
        inputsByFuse[1][0] = bytes32(uint256(2));
        inputsByFuse[2] = new bytes32[](1);
        inputsByFuse[2][0] = bytes32(uint256(3));

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        vm.expectRevert(TransientStorageSetInputsFuse.WrongFuseAddress.selector);
        mock.enter(data);
    }

    /// @notice Test revert when inputs length is zero in the middle of array
    function testEnterRevertWrongInputsLengthMiddle() public {
        address[] memory fuses = new address[](3);
        fuses[0] = address(0x1);
        fuses[1] = address(0x2);
        fuses[2] = address(0x3);

        bytes32[][] memory inputsByFuse = new bytes32[][](3);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = bytes32(uint256(1));
        inputsByFuse[1] = new bytes32[](0); // Empty inputs in middle
        inputsByFuse[2] = new bytes32[](1);
        inputsByFuse[2][0] = bytes32(uint256(3));

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        vm.expectRevert(TransientStorageSetInputsFuse.WrongInputsLength.selector);
        mock.enter(data);
    }

    /// @notice Test revert when inputs length is zero at the end of array
    function testEnterRevertWrongInputsLengthEnd() public {
        address[] memory fuses = new address[](3);
        fuses[0] = address(0x1);
        fuses[1] = address(0x2);
        fuses[2] = address(0x3);

        bytes32[][] memory inputsByFuse = new bytes32[][](3);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = bytes32(uint256(1));
        inputsByFuse[1] = new bytes32[](1);
        inputsByFuse[1][0] = bytes32(uint256(2));
        inputsByFuse[2] = new bytes32[](0); // Empty inputs at end

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        vm.expectRevert(TransientStorageSetInputsFuse.WrongInputsLength.selector);
        mock.enter(data);
    }

    /// @notice Test with empty arrays (edge case)
    function testEnterWithEmptyArrays() public {
        address[] memory fuses = new address[](0);
        bytes32[][] memory inputsByFuse = new bytes32[][](0);

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        // Should succeed with empty arrays (no validation needed)
        mock.enter(data);
    }

    /// @notice Test data isolation between different fuses
    function testDataIsolationBetweenFuses() public {
        address fuse1 = address(0x1);
        address fuse2 = address(0x2);
        address fuse3 = address(0x3);

        bytes32[] memory inputs1 = new bytes32[](2);
        inputs1[0] = bytes32(uint256(100));
        inputs1[1] = bytes32(uint256(200));
        bytes32[] memory inputs2 = new bytes32[](1);
        inputs2[0] = bytes32(uint256(300));
        bytes32[] memory inputs3 = new bytes32[](3);
        inputs3[0] = bytes32(uint256(400));
        inputs3[1] = bytes32(uint256(500));
        inputs3[2] = bytes32(uint256(600));

        address[] memory fuses = new address[](3);
        fuses[0] = fuse1;
        fuses[1] = fuse2;
        fuses[2] = fuse3;

        bytes32[][] memory inputsByFuse = new bytes32[][](3);
        inputsByFuse[0] = inputs1;
        inputsByFuse[1] = inputs2;
        inputsByFuse[2] = inputs3;

        TransientStorageSetInputsFuseEnterData memory data = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        mock.enter(data);

        bytes32[] memory storedInputs1 = mock.getInputs(fuse1);
        assertEq(storedInputs1.length, 2);
        assertEq(storedInputs1[0], bytes32(uint256(100)));
        assertEq(storedInputs1[1], bytes32(uint256(200)));

        bytes32[] memory storedInputs2 = mock.getInputs(fuse2);
        assertEq(storedInputs2.length, 1);
        assertEq(storedInputs2[0], bytes32(uint256(300)));

        bytes32[] memory storedInputs3 = mock.getInputs(fuse3);
        assertEq(storedInputs3.length, 3);
        assertEq(storedInputs3[0], bytes32(uint256(400)));
        assertEq(storedInputs3[1], bytes32(uint256(500)));
        assertEq(storedInputs3[2], bytes32(uint256(600)));
    }
}
