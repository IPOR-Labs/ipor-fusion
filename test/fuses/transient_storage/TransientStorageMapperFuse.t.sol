// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TransientStorageMapperFuse, TransientStorageMapperEnterData, TransientStorageMapperItem} from "../../../contracts/fuses/transient_storage/TransientStorageMapperFuse.sol";
import {TransientStorageParamTypes} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {TransientStorageMapperFuseMock} from "./TransientStorageMapperFuseMock.sol";

/// @title TransientStorageMapperFuseTest
/// @notice Tests for TransientStorageMapperFuse
/// @author IPOR Labs
contract TransientStorageMapperFuseTest is Test {
    /// @notice The fuse contract being tested
    TransientStorageMapperFuse public fuse;

    /// @notice The mock contract for executing fuse
    TransientStorageMapperFuseMock public mock;

    /// @notice Setup the test environment
    function setUp() public {
        fuse = new TransientStorageMapperFuse();
        mock = new TransientStorageMapperFuseMock(address(fuse));
    }

    /// @notice Test MARKET_ID constant value
    function testMarketId() public view {
        assertEq(fuse.MARKET_ID(), IporFusionMarkets.ERC20_VAULT_BALANCE);
    }

    /// @notice Test successful mapping from INPUTS_BY_FUSE
    function testEnterSuccessMapFromInputs() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = bytes32(uint256(100));
        inputs[1] = bytes32(uint256(200));
        inputs[2] = bytes32(uint256(300));

        mock.setInputs(fuseFrom, inputs);

        bytes32[] memory storedInputs = mock.getInputs(fuseFrom);
        assertEq(storedInputs.length, 3);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataToAddress: fuseTo,
            dataToIndex: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(mock.getInput(fuseTo, 0), inputs[1]);
    }

    /// @notice Test successful mapping from OUTPUTS_BY_FUSE
    function testEnterSuccessMapFromOutputs() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = bytes32(uint256(500));
        outputs[1] = bytes32(uint256(600));

        mock.setOutputs(fuseFrom, outputs);

        bytes32[] memory storedOutputs = mock.getOutputs(fuseFrom);
        assertEq(storedOutputs.length, 2);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.OUTPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(mock.getInput(fuseTo, 0), outputs[0]);
    }

    /// @notice Test successful mapping with multiple items
    function testEnterSuccessMultipleItems() public {
        address fuseFrom1 = address(0x1);
        address fuseFrom2 = address(0x2);
        address fuseTo = address(0x3);

        bytes32[] memory inputs1 = new bytes32[](2);
        inputs1[0] = bytes32(uint256(100));
        inputs1[1] = bytes32(uint256(200));

        bytes32[] memory outputs2 = new bytes32[](2);
        outputs2[0] = bytes32(uint256(300));
        outputs2[1] = bytes32(uint256(400));

        mock.setInputs(fuseFrom1, inputs1);
        mock.setOutputs(fuseFrom2, outputs2);

        bytes32[] memory emptyInputs = new bytes32[](2);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](2);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom1,
            dataFromIndex: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.OUTPUTS_BY_FUSE,
            dataFromAddress: fuseFrom2,
            dataFromIndex: 1,
            dataToAddress: fuseTo,
            dataToIndex: 1
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(mock.getInput(fuseTo, 0), inputs1[0]);
        assertEq(mock.getInput(fuseTo, 1), outputs2[1]);
    }

    /// @notice Test mapping to different fuse addresses
    function testEnterSuccessMapToDifferentFuses() public {
        address fuseFrom = address(0x1);
        address fuseTo1 = address(0x2);
        address fuseTo2 = address(0x3);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = bytes32(uint256(100));
        inputs[1] = bytes32(uint256(200));

        mock.setInputs(fuseFrom, inputs);

        bytes32[] memory emptyInputs1 = new bytes32[](1);
        bytes32[] memory emptyInputs2 = new bytes32[](1);
        mock.setInputs(fuseTo1, emptyInputs1);
        mock.setInputs(fuseTo2, emptyInputs2);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](2);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataToAddress: fuseTo1,
            dataToIndex: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataToAddress: fuseTo2,
            dataToIndex: 0
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(mock.getInput(fuseTo1, 0), inputs[0]);
        assertEq(mock.getInput(fuseTo2, 0), inputs[1]);
    }

    /// @notice Test revert when dataFromAddress is zero
    function testEnterRevertInvalidDataFromAddress() public {
        address fuseTo = address(0x2);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: address(0),
            dataFromIndex: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(TransientStorageMapperFuse.TransientStorageMapperFuseInvalidDataFromAddress.selector);
        mock.enter(data);
    }

    /// @notice Test revert when dataToAddress is zero
    function testEnterRevertInvalidDataToAddress() public {
        address fuseFrom = address(0x1);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(100));
        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataToAddress: address(0),
            dataToIndex: 0
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(TransientStorageMapperFuse.TransientStorageMapperFuseInvalidDataToAddress.selector);
        mock.enter(data);
    }

    /// @notice Test revert when paramType is UNKNOWN
    function testEnterRevertUnknownParamType() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(100));
        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.UNKNOWN,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(TransientStorageMapperFuse.TransientStorageMapperFuseUnknownParamType.selector);
        mock.enter(data);
    }

    /// @notice Test revert when dataFromAddress is zero in the middle of array
    function testEnterRevertInvalidDataFromAddressMiddle() public {
        address fuseFrom1 = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(100));
        mock.setInputs(fuseFrom1, inputs);

        bytes32[] memory emptyInputs = new bytes32[](2);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](2);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom1,
            dataFromIndex: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: address(0),
            dataFromIndex: 0,
            dataToAddress: fuseTo,
            dataToIndex: 1
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(TransientStorageMapperFuse.TransientStorageMapperFuseInvalidDataFromAddress.selector);
        mock.enter(data);
    }

    /// @notice Test revert when dataToAddress is zero in the middle of array
    function testEnterRevertInvalidDataToAddressMiddle() public {
        address fuseFrom = address(0x1);
        address fuseTo1 = address(0x2);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = bytes32(uint256(100));
        inputs[1] = bytes32(uint256(200));
        mock.setInputs(fuseFrom, inputs);

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo1, emptyInputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](2);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataToAddress: fuseTo1,
            dataToIndex: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataToAddress: address(0),
            dataToIndex: 0
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(TransientStorageMapperFuse.TransientStorageMapperFuseInvalidDataToAddress.selector);
        mock.enter(data);
    }

    /// @notice Test with empty items array
    function testEnterWithEmptyItems() public {
        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](0);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);
    }

    /// @notice Test mapping overwrites existing input
    function testEnterOverwriteExistingInput() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory initialInputs = new bytes32[](1);
        initialInputs[0] = bytes32(uint256(100));
        mock.setInputs(fuseTo, initialInputs);

        bytes32[] memory newInputs = new bytes32[](1);
        newInputs[0] = bytes32(uint256(200));
        mock.setInputs(fuseFrom, newInputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(mock.getInput(fuseTo, 0), newInputs[0]);
    }

    /// @notice Test mapping with different bytes32 values
    function testEnterWithDifferentBytes32Values() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = bytes32(uint256(123));
        inputs[1] = keccak256("test string");
        inputs[2] = bytes32(abi.encodePacked(address(0x1234)));

        mock.setInputs(fuseFrom, inputs);

        bytes32[] memory emptyInputs = new bytes32[](3);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](3);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataToAddress: fuseTo,
            dataToIndex: 1
        });
        items[2] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 2,
            dataToAddress: fuseTo,
            dataToIndex: 2
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(mock.getInput(fuseTo, 0), inputs[0]);
        assertEq(mock.getInput(fuseTo, 1), inputs[1]);
        assertEq(mock.getInput(fuseTo, 2), inputs[2]);
    }
}
