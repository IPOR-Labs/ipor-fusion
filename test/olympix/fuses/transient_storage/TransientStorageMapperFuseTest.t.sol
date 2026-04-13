// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {TransientStorageMapperFuse} from "contracts/fuses/transient_storage/TransientStorageMapperFuse.sol";

/// @dev Target contract: contracts/fuses/transient_storage/TransientStorageMapperFuse.sol

import {TransientStorageMapperFuseMock} from "test/fuses/transient_storage/TransientStorageMapperFuseMock.sol";
import {TransientStorageMapperFuse, TransientStorageMapperEnterData, TransientStorageMapperItem} from "contracts/fuses/transient_storage/TransientStorageMapperFuse.sol";
import {DataType} from "contracts/libraries/TypeConversionLib.sol";
import {TransientStorageParamTypes} from "contracts/transient_storage/TransientStorageLib.sol";
import {TransientStorageMapperEnterData, TransientStorageMapperItem} from "contracts/fuses/transient_storage/TransientStorageMapperFuse.sol";
contract TransientStorageMapperFuseTest is OlympixUnitTest("TransientStorageMapperFuse") {
    TransientStorageMapperFuse public transientStorageMapperFuse;


    function setUp() public override {
        transientStorageMapperFuse = new TransientStorageMapperFuse();
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(transientStorageMapperFuse) != address(0), "Contract should be deployed");
    }

    function test_packNumericValueToSigned_int64Overflow_reverts() public {
            // Deploy mock that delegates to the fuse so storage layout matches expectations
            TransientStorageMapperFuse fuseImpl = new TransientStorageMapperFuse();
            TransientStorageMapperFuseMock mock = new TransientStorageMapperFuseMock(address(fuseImpl));
    
            // Prepare source input in transient storage: a UINT64 value greater than int64 max
            // uint64 max is 2^64-1, int64 max is 2^63-1, so this value will overflow when casting to int64
            uint256 overflowingValue = uint256(type(uint64).max);
    
            bytes32[] memory inputs = new bytes32[](1);
            inputs[0] = bytes32(overflowingValue);
    
            // Store this as INPUT[0] for dataFromAddress = address(mock)
            mock.setInputs(address(mock), inputs);
    
            // Prepare mapping item that converts from UINT64 to INT64 (no decimals)
            TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
            items[0] = TransientStorageMapperItem({
                paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
                dataFromAddress: address(mock),
                dataFromIndex: 0,
                dataFromType: DataType.UINT64,
                dataFromDecimals: 0,
                dataToAddress: address(mock),
                dataToIndex: 0,
                dataToType: DataType.INT64,
                dataToDecimals: 0
            });
    
            TransientStorageMapperEnterData memory enterData = TransientStorageMapperEnterData({items: items});
    
            // Expect revert from _packNumericValueToSigned INT64 branch (value_ > uint64(int64.max))
            vm.expectRevert(abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(type(uint64).max),
                DataType.INT64
            ));
            mock.enter(enterData);
        }

    function test_packNumericValueToSigned_int32Overflow_triggersIfBranch() public {
            // Deploy implementation and mock that delegates to it
            TransientStorageMapperFuse fuseImpl = new TransientStorageMapperFuse();
            TransientStorageMapperFuseMock mock = new TransientStorageMapperFuseMock(address(fuseImpl));
    
            // Prepare source input in transient storage: a UINT32 value greater than int32 max
            // uint32 max (2^32-1) is > int32 max (2^31-1), so this value will overflow when casting to int32
            uint256 overflowingValue = uint256(type(uint32).max);
    
            bytes32[] memory inputs = new bytes32[](1);
            inputs[0] = bytes32(overflowingValue);
    
            // Initialize destination inputs array so that setInput(index=0) does not revert with TransientStorageError
            mock.setInputs(address(this), inputs);
    
            // Store overflowing value as INPUT[0] for dataFromAddress = address(this)
            mock.setInputs(address(this), inputs);
    
            // Prepare mapping item that converts from UINT32 to INT32 (no decimals)
            TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
            items[0] = TransientStorageMapperItem({
                paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
                dataFromAddress: address(this),
                dataFromIndex: 0,
                dataFromType: DataType.UINT32,
                dataFromDecimals: 0,
                dataToAddress: address(this),
                dataToIndex: 0,
                dataToType: DataType.INT32,
                dataToDecimals: 0
            });
    
            TransientStorageMapperEnterData memory enterData = TransientStorageMapperEnterData({items: items});
    
            // Expect revert from _packNumericValueToSigned INT32 branch
            vm.expectRevert(abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(type(uint32).max),
                DataType.INT32
            ));
            mock.enter(enterData);
        }

    function test_packNumericValueToSigned_int16Overflow_triggersIfBranch() public {
            // Arrange: deploy implementation and mock delegating to it
            TransientStorageMapperFuse fuseImpl = new TransientStorageMapperFuse();
            TransientStorageMapperFuseMock mock = new TransientStorageMapperFuseMock(address(fuseImpl));
    
            // Prepare a UINT16 value greater than int16 max to overflow the INT16 branch
            uint256 overflowingValue = uint256(type(uint16).max); // > uint16(int16.max)
    
            bytes32[] memory inputs = new bytes32[](1);
            inputs[0] = bytes32(overflowingValue);
    
            // Initialize destination inputs array for dataToAddress so setInput(index=0) is valid
            mock.setInputs(address(this), inputs);
    
            // Store overflowing value as INPUT[0] for dataFromAddress = address(this)
            mock.setInputs(address(this), inputs);
    
            // Map from UINT16 to INT16 with same decimals so we hit _packNumericValueToSigned INT16 branch
            TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
            items[0] = TransientStorageMapperItem({
                paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
                dataFromAddress: address(this),
                dataFromIndex: 0,
                dataFromType: DataType.UINT16,
                dataFromDecimals: 0,
                dataToAddress: address(this),
                dataToIndex: 0,
                dataToType: DataType.INT16,
                dataToDecimals: 0
            });
    
            TransientStorageMapperEnterData memory enterData = TransientStorageMapperEnterData({items: items});
    
            // Assert: expect revert from _packNumericValueToSigned INT16 overflow branch
            vm.expectRevert(abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(type(uint16).max),
                DataType.INT16
            ));
            mock.enter(enterData);
        }

    function test_packNumericValueToSigned_int8Overflow_triggersIfBranch() public {
            // Deploy implementation and mock delegating to it
            TransientStorageMapperFuse fuseImpl = new TransientStorageMapperFuse();
            TransientStorageMapperFuseMock mock = new TransientStorageMapperFuseMock(address(fuseImpl));
    
            // Prepare a UINT8 value greater than int8 max to overflow the INT8 branch
            // uint8 max (255) > int8 max (127), so this overflows when casting to int8
            uint256 overflowingValue = uint256(type(uint8).max);
    
            bytes32[] memory inputs = new bytes32[](1);
            inputs[0] = bytes32(overflowingValue);
    
            // Initialize destination inputs array for dataToAddress so setInput(index=0) is valid
            mock.setInputs(address(this), inputs);
    
            // Store overflowing value as INPUT[0] for dataFromAddress = address(this)
            mock.setInputs(address(this), inputs);
    
            // Map from UINT8 to INT8 with same decimals so we hit _packNumericValueToSigned INT8 branch
            TransientStorageMapperItem[] memory items = new TransientStorageMapperItem[](1);
            items[0] = TransientStorageMapperItem({
                paramType: TransientStorageParamTypes.INPUTS_BY_FUSE,
                dataFromAddress: address(this),
                dataFromIndex: 0,
                dataFromType: DataType.UINT8,
                dataFromDecimals: 0,
                dataToAddress: address(this),
                dataToIndex: 0,
                dataToType: DataType.INT8,
                dataToDecimals: 0
            });
    
            TransientStorageMapperEnterData memory enterData = TransientStorageMapperEnterData({items: items});
    
            // Expect revert from _packNumericValueToSigned INT8 overflow branch (value_ > uint8(int8.max))
            vm.expectRevert(abi.encodeWithSelector(
                TransientStorageMapperFuse.TransientStorageMapperFuseValueOutOfRange.selector,
                uint256(type(uint8).max),
                DataType.INT8
            ));
            mock.enter(enterData);
        }
}