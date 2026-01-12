// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TransientStorageMapperFuse, TransientStorageMapperEnterData, TransientStorageMapperItem} from "../../../contracts/fuses/transient_storage/TransientStorageMapperFuse.sol";
import {TransientStorageParamTypes} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {DataType} from "../../../contracts/libraries/TypeConversionLib.sol";
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.OUTPUTS_BY_FUSE,
            dataFromAddress: fuseFrom2,
            dataFromIndex: 1,
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 1,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo1,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo2,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: address(0),
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: address(0),
            dataFromIndex: 0,
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 1,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo1,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: address(0),
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
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
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 1,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
        });
        items[2] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 2,
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 2,
            dataToType: DataType.UNKNOWN,
            dataToDecimals: 0
        });

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(mock.getInput(fuseTo, 0), inputs[0]);
        assertEq(mock.getInput(fuseTo, 1), inputs[1]);
        assertEq(mock.getInput(fuseTo, 2), inputs[2]);
    }

    // ============================================
    // DECIMAL CONVERSION TESTS
    // ============================================

    /// @notice Test decimal conversion: scale up from 6 to 18 decimals (USDC -> DAI style)
    function testEnterDecimalConversionScaleUp6To18() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // 1000 USDC with 6 decimals = 1000 * 10^6 = 1_000_000_000
        uint256 usdcAmount = 1000 * 1e6;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(usdcAmount);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Expected: 1000 * 10^18 = 1_000_000_000_000_000_000_000
        uint256 expectedAmount = 1000 * 1e18;
        assertEq(uint256(mock.getInput(fuseTo, 0)), expectedAmount);
    }

    /// @notice Test decimal conversion: scale down from 18 to 6 decimals (DAI -> USDC style)
    function testEnterDecimalConversionScaleDown18To6() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // 1000 DAI with 18 decimals = 1000 * 10^18
        uint256 daiAmount = 1000 * 1e18;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(daiAmount);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 18,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 6
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Expected: 1000 * 10^6 = 1_000_000_000
        uint256 expectedAmount = 1000 * 1e6;
        assertEq(uint256(mock.getInput(fuseTo, 0)), expectedAmount);
    }

    /// @notice Test decimal conversion: scale up from 8 to 18 decimals (WBTC style)
    function testEnterDecimalConversionScaleUp8To18() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // 1.5 WBTC with 8 decimals = 1.5 * 10^8 = 150_000_000
        uint256 wbtcAmount = 15 * 1e7;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(wbtcAmount);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 8,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Expected: 1.5 * 10^18 = 1_500_000_000_000_000_000
        uint256 expectedAmount = 15 * 1e17;
        assertEq(uint256(mock.getInput(fuseTo, 0)), expectedAmount);
    }

    /// @notice Test decimal conversion: same decimals should not change value
    function testEnterDecimalConversionSameDecimals() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 amount = 12345 * 1e18;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(amount);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 18,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), amount);
    }

    /// @notice Test that same type and decimals returns value unchanged (early return optimization)
    function testEnterSameTypeAndDecimalsReturnsUnchanged() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // Test with a complex bytes32 value (hash) to ensure no conversion cycle occurs
        bytes32 complexValue = keccak256("test value that should not be modified");
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = complexValue;

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BYTES32,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BYTES32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Should be exactly the same (early return, no conversion cycle)
        assertEq(mock.getInput(fuseTo, 0), complexValue);
    }

    /// @notice Test that same decimals but different types still performs conversion
    function testEnterSameDecimalsDifferentTypesPerformsConversion() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // Use a uint128 value
        uint128 value = 123456789;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT128,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Should convert properly even though decimals are the same
        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(value));
    }

    /// @notice Test decimal conversion with zero value
    function testEnterDecimalConversionZeroValue() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(0));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 0);
    }

    /// @notice Test type conversion: UINT128 to UINT256
    function testEnterTypeConversionUint128ToUint256() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint128 value = 12345678901234567890;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT128,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(value));
    }

    /// @notice Test combined type and decimal conversion
    function testEnterCombinedTypeAndDecimalConversion() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // 100 tokens with 6 decimals stored as uint128
        uint128 value = 100 * 1e6;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT128,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Expected: 100 * 10^18
        assertEq(uint256(mock.getInput(fuseTo, 0)), 100 * 1e18);
    }

    /// @notice Test decimal conversion scale down with precision loss
    function testEnterDecimalConversionScaleDownWithPrecisionLoss() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // 1000.123456789012345678 DAI with 18 decimals
        uint256 daiAmount = 1000123456789012345678;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(daiAmount);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 18,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 6
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Expected: 1000.123456 USDC (loses precision after 6 decimals)
        // 1000123456789012345678 / 10^12 = 1000123456
        uint256 expectedAmount = 1000123456;
        assertEq(uint256(mock.getInput(fuseTo, 0)), expectedAmount);
    }

    /// @notice Test mapping with UNKNOWN type bypasses conversion
    function testEnterUnknownTypeBypassesConversion() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 amount = 1000 * 1e6;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(amount);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // When fromType is UNKNOWN, value should pass through unchanged
        assertEq(uint256(mock.getInput(fuseTo, 0)), amount);
    }

    /// @notice Test address type conversion preserves address
    function testEnterAddressTypeConversion() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        address testAddress = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(uint160(testAddress)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.ADDRESS,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.ADDRESS,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(address(uint160(uint256(mock.getInput(fuseTo, 0)))), testAddress);
    }

    /// @notice Test bool type conversion
    function testEnterBoolTypeConversion() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = bytes32(uint256(1)); // true
        inputs[1] = bytes32(uint256(0)); // false

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](2);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BOOL,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataFromType: DataType.BOOL,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 1,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](2);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1);
        assertEq(uint256(mock.getInput(fuseTo, 1)), 0);
    }

    /// @notice Test decimal conversion from 0 to 18 decimals (no decimals to standard decimals)
    function testEnterDecimalConversionFrom0To18() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // Raw amount with no decimals
        uint256 rawAmount = 1000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(rawAmount);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Expected: 1000 * 10^18
        assertEq(uint256(mock.getInput(fuseTo, 0)), 1000 * 1e18);
    }

    /// @notice Test decimal conversion from 18 to 0 decimals
    function testEnterDecimalConversionFrom18To0() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // 1000 tokens with 18 decimals
        uint256 amount = 1000 * 1e18;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(amount);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 18,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        // Expected: 1000
        assertEq(uint256(mock.getInput(fuseTo, 0)), 1000);
    }

    /// @notice Test multiple items with different decimal conversions
    function testEnterMultipleItemsWithDifferentDecimalConversions() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = bytes32(uint256(1000 * 1e6)); // USDC: 1000 with 6 decimals
        inputs[1] = bytes32(uint256(500 * 1e8)); // WBTC: 500 with 8 decimals
        inputs[2] = bytes32(uint256(200 * 1e18)); // DAI: 200 with 18 decimals

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](3);
        // USDC 6 -> 18
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });
        // WBTC 8 -> 18
        items[1] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 1,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 8,
            dataToAddress: fuseTo,
            dataToIndex: 1,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });
        // DAI 18 -> 6
        items[2] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 2,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 18,
            dataToAddress: fuseTo,
            dataToIndex: 2,
            dataToType: DataType.UINT256,
            dataToDecimals: 6
        });

        bytes32[] memory emptyInputs = new bytes32[](3);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1000 * 1e18); // USDC scaled up
        assertEq(uint256(mock.getInput(fuseTo, 1)), 500 * 1e18); // WBTC scaled up
        assertEq(uint256(mock.getInput(fuseTo, 2)), 200 * 1e6); // DAI scaled down
    }

    // ============================================
    // INT TO INT CONVERSION TESTS
    // ============================================

    /// @notice Test INT256 positive to INT128 conversion
    function testShouldConvertInt256ToInt128PositiveSuccessfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = 1000e18;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT128,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int128 result = int128(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int128(value));
    }

    /// @notice Test INT256 negative to INT128 conversion
    function testShouldConvertInt256ToInt128NegativeSuccessfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -1000e18;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT128,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int128 result = int128(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int128(value));
    }

    /// @notice Test INT128 negative to INT256 extension
    function testShouldConvertInt128ToInt256NegativeSuccessfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int128 value = -500e6;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(int256(value)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT128,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int256 result = int256(uint256(mock.getInput(fuseTo, 0)));
        assertEq(result, int256(value));
    }

    /// @notice Test INT256 negative with decimal scale up preserves sign
    function testShouldConvertInt256NegativeScaleUp6To18Decimals() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -1000 * 1e6; // -1000 with 6 decimals
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int256 result = int256(uint256(mock.getInput(fuseTo, 0)));
        assertEq(result, -1000 * 1e18);
    }

    /// @notice Test INT256 negative with decimal scale down preserves sign
    function testShouldConvertInt256NegativeScaleDown18To6Decimals() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -1000 * 1e18; // -1000 with 18 decimals
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 18,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 6
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int256 result = int256(uint256(mock.getInput(fuseTo, 0)));
        assertEq(result, -1000 * 1e6);
    }

    // ============================================
    // INT TO UINT CONVERSION TESTS
    // ============================================

    /// @notice Test positive INT256 to UINT256 conversion
    function testShouldConvertInt256PositiveToUint256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = 1000e18;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(value));
    }

    /// @notice Test negative INT256 to UINT256 reverts
    function testShouldRevertWhenNegativeInt256ToUint256() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -1000e18;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseNegativeValueNotAllowed.selector,
                value,
                DataType.UINT256
            )
        );
        mock.enter(data);
    }

    /// @notice Test negative INT128 to UINT256 reverts
    function testShouldRevertWhenNegativeInt128ToUint256() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int128 value = -500e6;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(int256(value)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT128,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseNegativeValueNotAllowed.selector,
                int256(value),
                DataType.UINT256
            )
        );
        mock.enter(data);
    }

    // ============================================
    // UINT TO INT CONVERSION TESTS
    // ============================================

    /// @notice Test UINT256 to INT256 in positive range
    function testShouldConvertUint256ToInt256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 1000e18;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int256 result = int256(uint256(mock.getInput(fuseTo, 0)));
        assertEq(result, int256(value));
    }

    /// @notice Test UINT256 exceeds INT256 max reverts
    function testShouldRevertWhenUint256ExceedsInt256Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(type(int256).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                value,
                DataType.INT256
            )
        );
        mock.enter(data);
    }

    // ============================================
    // ADDRESS CONVERSION TESTS
    // ============================================

    /// @notice Test ADDRESS to UINT256 conversion
    function testShouldConvertAddressToUint256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        address testAddr = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(uint160(testAddr)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.ADDRESS,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(uint160(testAddr)));
    }

    /// @notice Test UINT256 to ADDRESS conversion (within uint160 range)
    function testShouldConvertUint256ToAddressSuccessfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(uint160(address(0xDEAD)));
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.ADDRESS,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(address(uint160(uint256(mock.getInput(fuseTo, 0)))), address(0xDEAD));
    }

    /// @notice Test UINT256 > uint160.max to ADDRESS reverts
    function testShouldRevertWhenUint256ExceedsUint160ForAddress() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(type(uint160).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.ADDRESS,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                value,
                DataType.ADDRESS
            )
        );
        mock.enter(data);
    }

    /// @notice Test ADDRESS to INT256 conversion reverts (invalid path)
    function testShouldRevertWhenAddressToInt256() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(uint160(address(0xDEAD))));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.ADDRESS,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseInvalidConversion.selector,
                DataType.ADDRESS,
                DataType.INT256
            )
        );
        mock.enter(data);
    }

    /// @notice Test INT256 to ADDRESS conversion reverts (invalid path)
    function testShouldRevertWhenInt256ToAddress() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = 1000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.ADDRESS,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseInvalidConversion.selector,
                DataType.INT256,
                DataType.ADDRESS
            )
        );
        mock.enter(data);
    }

    // ============================================
    // BOOL CONVERSION TESTS
    // ============================================

    /// @notice Test BOOL true to UINT256 conversion
    function testShouldConvertBoolTrueToUint256() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(1)); // true

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BOOL,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1);
    }

    /// @notice Test BOOL false to UINT256 conversion
    function testShouldConvertBoolFalseToUint256() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(0)); // false

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BOOL,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 0);
    }

    /// @notice Test BOOL to ADDRESS conversion reverts (invalid path)
    function testShouldRevertWhenBoolToAddress() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(1)); // true

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BOOL,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.ADDRESS,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseInvalidConversion.selector,
                DataType.BOOL,
                DataType.ADDRESS
            )
        );
        mock.enter(data);
    }

    /// @notice Test negative INT256 to BOOL (non-zero -> true)
    function testShouldConvertInt256NegativeToBoolTrue() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -1000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1); // true
    }

    // ============================================
    // BYTES32 CONVERSION TESTS
    // ============================================

    /// @notice Test BYTES32 to UINT256 conversion
    function testShouldConvertBytes32ToUint256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32 value = keccak256("test");
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = value;

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BYTES32,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(value));
    }

    /// @notice Test INT256 to BYTES32 conversion
    function testShouldConvertInt256ToBytes32Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -12345;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BYTES32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        // Should pass through directly
        assertEq(mock.getInput(fuseTo, 0), bytes32(uint256(value)));
    }

    // ============================================
    // DECIMAL OVERFLOW TESTS
    // ============================================

    /// @notice Test decimal scale up overflow reverts
    function testShouldRevertWhenDecimalScaleUpOverflows() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // Large value that will overflow when multiplied by 10^12
        uint256 value = type(uint256).max / 1e11; // Just above what will overflow
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseDecimalOverflow.selector,
                value,
                6,
                18
            )
        );
        mock.enter(data);
    }

    /// @notice Test signed decimal scale up overflow reverts
    function testShouldRevertWhenSignedDecimalScaleUpOverflows() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        // Large positive signed value that will overflow
        int256 value = type(int256).max / 1e11;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseSignedDecimalOverflow.selector,
                value,
                6,
                18
            )
        );
        mock.enter(data);
    }

    // ============================================
    // VALUE OUT OF RANGE TESTS
    // ============================================

    /// @notice Test UINT256 exceeds UINT128 max reverts
    function testShouldRevertWhenUint256ExceedsUint128Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(type(uint128).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT128,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                value,
                DataType.UINT128
            )
        );
        mock.enter(data);
    }

    /// @notice Test INT256 exceeds INT128 max reverts
    function testShouldRevertWhenInt256ExceedsInt128Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = int256(type(int128).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT128,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(value),
                DataType.INT128
            )
        );
        mock.enter(data);
    }

    /// @notice Test INT256 below INT128 min reverts
    function testShouldRevertWhenInt256BelowInt128Min() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = int256(type(int128).min) - 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT128,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(-value), // absolute value
                DataType.INT128
            )
        );
        mock.enter(data);
    }

    // ============================================
    // DECIMAL BYPASS FOR NON-NUMERIC TESTS
    // ============================================

    /// @notice Test decimals are ignored for ADDRESS conversion
    function testShouldIgnoreDecimalsForAddressConversion() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        address testAddr = address(0xDEAD);
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(uint160(testAddr)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.ADDRESS,
            dataFromDecimals: 6, // Should be ignored
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18 // Should be ignored
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        // Value should NOT be scaled - decimals ignored for ADDRESS
        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(uint160(testAddr)));
    }

    /// @notice Test decimals are ignored for BOOL conversion
    function testShouldIgnoreDecimalsForBoolConversion() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(1)); // true

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BOOL,
            dataFromDecimals: 6, // Should be ignored
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18 // Should be ignored
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        // Value should be 1, not 1e12
        assertEq(uint256(mock.getInput(fuseTo, 0)), 1);
    }

    // ============================================
    // SMALLER SIGNED TYPE CONVERSION TESTS
    // ============================================

    /// @notice Test INT64 positive to INT256 conversion
    function testShouldConvertInt64ToInt256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int64 value = 1000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(int256(value)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT64,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), int256(value));
    }

    /// @notice Test INT32 negative to INT256 conversion
    function testShouldConvertInt32NegativeToInt256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int32 value = -500000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(int256(value)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT32,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), int256(value));
    }

    /// @notice Test INT16 conversion
    function testShouldConvertInt16ToInt256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int16 value = -1000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(int256(value)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT16,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), int256(value));
    }

    /// @notice Test INT8 conversion
    function testShouldConvertInt8ToInt256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int8 value = -100;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(int256(value)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT8,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), int256(value));
    }

    /// @notice Test INT256 to INT64 positive conversion
    function testShouldConvertInt256ToInt64PositiveSuccessfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = 1000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT64,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int64 result = int64(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int64(value));
    }

    /// @notice Test INT256 to INT32 conversion
    function testShouldConvertInt256ToInt32Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -10000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int32 result = int32(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int32(value));
    }

    /// @notice Test INT256 to INT16 conversion
    function testShouldConvertInt256ToInt16Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = 1000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT16,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int16 result = int16(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int16(value));
    }

    /// @notice Test INT256 to INT8 conversion
    function testShouldConvertInt256ToInt8Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -50;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT8,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int8 result = int8(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int8(value));
    }

    // ============================================
    // SMALLER UNSIGNED TYPE CONVERSION TESTS
    // ============================================

    /// @notice Test UINT64 to UINT256 conversion
    function testShouldConvertUint64ToUint256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint64 value = 1000000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT64,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(value));
    }

    /// @notice Test UINT32 to UINT256 conversion
    function testShouldConvertUint32ToUint256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint32 value = 1000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT32,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(value));
    }

    /// @notice Test UINT16 to UINT256 conversion
    function testShouldConvertUint16ToUint256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint16 value = 50000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT16,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(value));
    }

    /// @notice Test UINT8 to UINT256 conversion
    function testShouldConvertUint8ToUint256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint8 value = 200;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT8,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(value));
    }

    /// @notice Test UINT256 to UINT64 conversion
    function testShouldConvertUint256ToUint64Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 1000000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT64,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint64(uint256(mock.getInput(fuseTo, 0))), uint64(value));
    }

    /// @notice Test UINT256 to UINT32 conversion
    function testShouldConvertUint256ToUint32Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 1000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint32(uint256(mock.getInput(fuseTo, 0))), uint32(value));
    }

    /// @notice Test UINT256 to UINT16 conversion
    function testShouldConvertUint256ToUint16Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 50000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT16,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint16(uint256(mock.getInput(fuseTo, 0))), uint16(value));
    }

    /// @notice Test UINT256 to UINT8 conversion
    function testShouldConvertUint256ToUint8Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 200;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT8,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint8(uint256(mock.getInput(fuseTo, 0))), uint8(value));
    }

    // ============================================
    // ADDITIONAL OUT OF RANGE TESTS
    // ============================================

    /// @notice Test UINT256 exceeds UINT64 max reverts
    function testShouldRevertWhenUint256ExceedsUint64Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(type(uint64).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT64,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                value,
                DataType.UINT64
            )
        );
        mock.enter(data);
    }

    /// @notice Test UINT256 exceeds UINT32 max reverts
    function testShouldRevertWhenUint256ExceedsUint32Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(type(uint32).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                value,
                DataType.UINT32
            )
        );
        mock.enter(data);
    }

    /// @notice Test UINT256 exceeds UINT16 max reverts
    function testShouldRevertWhenUint256ExceedsUint16Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(type(uint16).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT16,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                value,
                DataType.UINT16
            )
        );
        mock.enter(data);
    }

    /// @notice Test UINT256 exceeds UINT8 max reverts
    function testShouldRevertWhenUint256ExceedsUint8Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(type(uint8).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT8,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                value,
                DataType.UINT8
            )
        );
        mock.enter(data);
    }

    /// @notice Test INT256 exceeds INT64 max reverts
    function testShouldRevertWhenInt256ExceedsInt64Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = int256(type(int64).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT64,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(value),
                DataType.INT64
            )
        );
        mock.enter(data);
    }

    /// @notice Test INT256 exceeds INT32 max reverts
    function testShouldRevertWhenInt256ExceedsInt32Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = int256(type(int32).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(value),
                DataType.INT32
            )
        );
        mock.enter(data);
    }

    /// @notice Test INT256 exceeds INT16 max reverts
    function testShouldRevertWhenInt256ExceedsInt16Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = int256(type(int16).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT16,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(value),
                DataType.INT16
            )
        );
        mock.enter(data);
    }

    /// @notice Test INT256 exceeds INT8 max reverts
    function testShouldRevertWhenInt256ExceedsInt8Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = int256(type(int8).max) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT8,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(value),
                DataType.INT8
            )
        );
        mock.enter(data);
    }

    /// @notice Test UINT256 exceeds INT128 max reverts (for unsigned to signed)
    function testShouldRevertWhenUint256ExceedsInt128Max() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = uint256(uint128(type(int128).max)) + 1;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT128,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                value,
                DataType.INT128
            )
        );
        mock.enter(data);
    }

    /// @notice Test UINT256 to INT64 conversion within range
    function testShouldConvertUint256ToInt64Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 1000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT64,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int64 result = int64(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int64(int256(value)));
    }

    /// @notice Test UINT256 to INT32 conversion within range
    function testShouldConvertUint256ToInt32Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 10000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int32 result = int32(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int32(int256(value)));
    }

    /// @notice Test UINT256 to INT16 conversion within range
    function testShouldConvertUint256ToInt16Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 1000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT16,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int16 result = int16(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int16(int256(value)));
    }

    /// @notice Test UINT256 to INT8 conversion within range
    function testShouldConvertUint256ToInt8Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 100;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT8,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int8 result = int8(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int8(int256(value)));
    }

    // ============================================
    // ADDITIONAL UINT TO INT CONVERSION TESTS
    // ============================================

    /// @notice Test UINT128 to INT256 conversion
    function testShouldConvertUint128ToInt256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint128 value = 1000000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT128,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), int256(uint256(value)));
    }

    /// @notice Test UINT256 to INT128 conversion within range
    function testShouldConvertUint256ToInt128Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 1000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT128,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        int128 result = int128(int256(uint256(mock.getInput(fuseTo, 0))));
        assertEq(result, int128(int256(value)));
    }

    // ============================================
    // ADDITIONAL INT TO UINT CONVERSION TESTS
    // ============================================

    /// @notice Test positive INT128 to UINT256 conversion
    function testShouldConvertInt128PositiveToUint256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int128 value = 500000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(int256(value)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT128,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), uint256(int256(value)));
    }

    /// @notice Test positive INT256 to UINT128 conversion
    function testShouldConvertInt256PositiveToUint128Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = 1000000;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT128,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint128(uint256(mock.getInput(fuseTo, 0))), uint128(uint256(value)));
    }

    // ============================================
    // ADDITIONAL BOOL CONVERSION TESTS
    // ============================================

    /// @notice Test BOOL true to INT256 conversion
    function testShouldConvertBoolTrueToInt256() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(1)); // true

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BOOL,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), int256(1));
    }

    /// @notice Test BOOL false to INT256 conversion
    function testShouldConvertBoolFalseToInt256() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(0)); // false

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BOOL,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), int256(0));
    }

    /// @notice Test UINT256 non-zero to BOOL conversion
    function testShouldConvertUint256NonZeroToBoolTrue() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(12345));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1); // true
    }

    /// @notice Test UINT256 zero to BOOL conversion
    function testShouldConvertUint256ZeroToBoolFalse() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(0));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 0); // false
    }

    /// @notice Test INT256 zero to BOOL conversion
    function testShouldConvertInt256ZeroToBoolFalse() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = 0;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 0); // false
    }

    // ============================================
    // ADDITIONAL BYTES32 CONVERSION TESTS
    // ============================================

    /// @notice Test BYTES32 to INT256 conversion
    function testShouldConvertBytes32ToInt256Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32 value = bytes32(uint256(12345));
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = value;

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BYTES32,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), int256(12345));
    }

    /// @notice Test BYTES32 to ADDRESS conversion
    function testShouldConvertBytes32ToAddressSuccessfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        address testAddr = address(0xDEADBEEF);
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(uint160(testAddr)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BYTES32,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.ADDRESS,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(address(uint160(uint256(mock.getInput(fuseTo, 0)))), testAddr);
    }

    /// @notice Test BYTES32 non-zero to BOOL conversion
    function testShouldConvertBytes32ToBoolNonZero() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = keccak256("non-zero");

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BYTES32,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1); // true
    }

    /// @notice Test BYTES32 zero to BOOL conversion
    function testShouldConvertBytes32ToBoolZero() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(0);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.BYTES32,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 0); // false
    }

    /// @notice Test UINT256 to BYTES32 conversion
    function testShouldConvertUint256ToBytes32Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 123456789;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BYTES32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(mock.getInput(fuseTo, 0), bytes32(value));
    }

    // ============================================
    // ADDITIONAL ADDRESS CONVERSION TESTS
    // ============================================

    /// @notice Test ADDRESS to BOOL true (non-zero address)
    function testShouldConvertAddressToBoolTrue() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(uint160(address(0xDEAD))));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.ADDRESS,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1); // true
    }

    /// @notice Test ADDRESS to BOOL false (zero address)
    function testShouldConvertAddressToBoolFalse() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(0)); // address(0)

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.ADDRESS,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BOOL,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 0); // false
    }

    /// @notice Test ADDRESS to BYTES32 conversion
    function testShouldConvertAddressToBytes32Successfully() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        address testAddr = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(uint160(testAddr)));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.ADDRESS,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.BYTES32,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(mock.getInput(fuseTo, 0), bytes32(uint256(uint160(testAddr))));
    }

    // ============================================
    // DECIMAL CONVERSION COVERAGE TESTS
    // ============================================

    /// @notice Test INT256 to UINT256 with decimal conversion (line 199)
    function testShouldConvertInt256ToUint256WithDecimals() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = 1000 * 1e6; // 1000 with 6 decimals
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1000 * 1e18);
    }

    /// @notice Test UINT256 to INT256 with decimal conversion (line 250-251)
    function testShouldConvertUint256ToInt256WithDecimals() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 500 * 1e6; // 500 with 6 decimals
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), 500 * 1e18);
    }

    /// @notice Test INT256 to INT256 same decimals (line 300 - early return)
    function testShouldConvertInt256ToInt256SameDecimals() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        int256 value = -12345;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(value));

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.INT256,
            dataFromDecimals: 18,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.INT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(int256(uint256(mock.getInput(fuseTo, 0))), value);
    }

    /// @notice Test UINT256 to UINT256 same decimals (line 441 - early return)
    function testShouldConvertUint256ToUint256SameDecimals() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 999888777;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 6
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), value);
    }

    // ============================================
    // BACKWARD COMPATIBILITY TESTS
    // ============================================

    /// @notice Test existing UINT256 to UINT256 no decimals unchanged
    function testExistingUint256ToUint256NoDecimalsUnchanged() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 123456789;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 0,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 0
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), value);
    }

    /// @notice Test existing decimal conversion unchanged (backward compatibility)
    function testExistingDecimalConversionUnchanged() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        uint256 value = 1000 * 1e6; // 1000 USDC
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(value);

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UINT256,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        assertEq(uint256(mock.getInput(fuseTo, 0)), 1000 * 1e18);
    }

    /// @notice Test existing UNKNOWN type bypass unchanged (backward compatibility)
    function testExistingUnknownTypeBypassUnchanged() public {
        address fuseFrom = address(0x1);
        address fuseTo = address(0x2);

        bytes32 value = keccak256("arbitrary data");
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = value;

        mock.setInputs(fuseFrom, inputs);

        TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
        items[0] = TransientStorageMapperItem({
            paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            dataFromAddress: fuseFrom,
            dataFromIndex: 0,
            dataFromType: DataType.UNKNOWN,
            dataFromDecimals: 6,
            dataToAddress: fuseTo,
            dataToIndex: 0,
            dataToType: DataType.UINT256,
            dataToDecimals: 18
        });

        bytes32[] memory emptyInputs = new bytes32[](1);
        mock.setInputs(fuseTo, emptyInputs);

        TransientStorageMapperEnterData memory data = TransientStorageMapperEnterData({items: items});
        mock.enter(data);

        // Value should pass through unchanged when fromType is UNKNOWN
        assertEq(mock.getInput(fuseTo, 0), value);
    }
}
