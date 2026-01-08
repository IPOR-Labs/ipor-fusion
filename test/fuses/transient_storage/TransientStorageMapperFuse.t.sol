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
}
