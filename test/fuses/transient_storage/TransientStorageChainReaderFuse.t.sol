// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TransientStorageChainReaderFuse, ExternalCalls, ExternalCall, ReadDataFromResponse} from "../../../contracts/fuses/transient_storage/TransientStorageChainReaderFuse.sol";
import {DataType, TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {TransientStorageChainReaderFuseMock, MockTarget} from "./TransientStorageChainReaderFuseMock.sol";

/// @title TransientStorageChainReaderFuseTest
/// @notice Tests for TransientStorageChainReaderFuse
/// @author IPOR Labs
contract TransientStorageChainReaderFuseTest is Test {
    /// @notice The fuse contract being tested
    TransientStorageChainReaderFuse public fuse;

    /// @notice The mock contract for executing fuse
    TransientStorageChainReaderFuseMock public mock;

    /// @notice Mock target for external calls
    MockTarget public mockTarget;

    /// @notice Setup the test environment
    function setUp() public {
        fuse = new TransientStorageChainReaderFuse();
        mock = new TransientStorageChainReaderFuseMock(address(fuse));
        mockTarget = new MockTarget();
    }

    /// @notice Test MARKET_ID constant value
    function testMarketId() public view {
        assertEq(fuse.MARKET_ID(), IporFusionMarkets.ERC20_VAULT_BALANCE);
    }

    /// @notice Test VERSION constant value
    function testVersion() public view {
        assertEq(fuse.VERSION(), address(fuse));
    }

    /// @notice Test successful reading UINT256
    function testEnterSuccessUint256() public {
        uint256 value = 12345678901234567890;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint256.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(value));
    }

    /// @notice Test successful reading UINT128
    function testEnterSuccessUint128() public {
        uint128 value = 12345678901234567890;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint128.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT128, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(uint256(value)));
    }

    /// @notice Test successful reading UINT64
    function testEnterSuccessUint64() public {
        uint64 value = 12345678901234567890;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint64.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT64, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(uint256(value)));
    }

    /// @notice Test successful reading UINT32
    function testEnterSuccessUint32() public {
        uint32 value = 1234567890;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint32.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT32, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(uint256(value)));
    }

    /// @notice Test successful reading UINT16
    function testEnterSuccessUint16() public {
        uint16 value = 12345;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint16.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT16, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(uint256(value)));
    }

    /// @notice Test successful reading UINT8
    function testEnterSuccessUint8() public {
        uint8 value = 123;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint8.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT8, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(uint256(value)));
    }

    /// @notice Test successful reading INT256
    function testEnterSuccessInt256() public {
        int256 value = -12345678901234567890;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnInt256.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.INT256, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(value));
    }

    /// @notice Test successful reading INT128
    function testEnterSuccessInt128() public {
        int128 value = -12345678901234567890;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnInt128.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.INT128, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(int256(value)));
    }

    /// @notice Test successful reading INT64
    function testEnterSuccessInt64() public {
        int64 value = -1234567890123456789;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnInt64.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.INT64, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(int256(value)));
    }

    /// @notice Test successful reading INT32
    function testEnterSuccessInt32() public {
        int32 value = -1234567890;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnInt32.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.INT32, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(int256(value)));
    }

    /// @notice Test successful reading INT16
    function testEnterSuccessInt16() public {
        int16 value = -12345;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnInt16.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.INT16, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(int256(value)));
    }

    /// @notice Test successful reading INT8
    function testEnterSuccessInt8() public {
        int8 value = -123;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnInt8.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.INT8, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(int256(value)));
    }

    /// @notice Test successful reading ADDRESS
    function testEnterSuccessAddress() public {
        address value = address(0x1234567890123456789012345678901234567890);
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnAddress.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.ADDRESS, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(value));
    }

    /// @notice Test successful reading BOOL
    function testEnterSuccessBool() public {
        bool value = true;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnBool.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.BOOL, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(value));
    }

    /// @notice Test successful reading BOOL false
    function testEnterSuccessBoolFalse() public {
        bool value = false;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnBool.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.BOOL, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, TypeConversionLib.toBytes32(value));
    }

    /// @notice Test successful reading BYTES32
    function testEnterSuccessBytes32() public {
        bytes32 value = keccak256("test");
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnBytes32.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.BYTES32, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, value);
    }

    /// @notice Test successful reading UNKNOWN type (should return raw value)
    function testEnterSuccessUnknown() public {
        bytes32 value = keccak256("test");
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnBytes32.selector, value);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UNKNOWN, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32 result = mock.getOutput(fuse.VERSION(), 0);
        assertEq(result, value);
    }

    /// @notice Test successful reading multiple values from one call
    function testEnterSuccessMultipleReaders() public {
        uint256 value1 = 100;
        uint256 value2 = 200;
        uint256 value3 = 300;
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnMultiple.selector, value1, value2, value3);

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](3);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 0, bytesEnd: 32});
        readers[1] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 32, bytesEnd: 64});
        readers[2] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 64, bytesEnd: 96});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 3});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        assertEq(mock.getOutput(fuse.VERSION(), 0), TypeConversionLib.toBytes32(value1));
        assertEq(mock.getOutput(fuse.VERSION(), 1), TypeConversionLib.toBytes32(value2));
        assertEq(mock.getOutput(fuse.VERSION(), 2), TypeConversionLib.toBytes32(value3));
    }

    /// @notice Test successful reading from multiple calls
    function testEnterSuccessMultipleCalls() public {
        uint256 value1 = 100;
        uint256 value2 = 200;
        bytes memory callData1 = abi.encodeWithSelector(MockTarget.returnUint256.selector, value1);
        bytes memory callData2 = abi.encodeWithSelector(MockTarget.returnUint256.selector, value2);

        ExternalCall[] memory calls = new ExternalCall[](2);
        ReadDataFromResponse[] memory readers1 = new ReadDataFromResponse[](1);
        readers1[0] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 0, bytesEnd: 32});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData1, readers: readers1});

        ReadDataFromResponse[] memory readers2 = new ReadDataFromResponse[](1);
        readers2[0] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 0, bytesEnd: 32});
        calls[1] = ExternalCall({target: address(mockTarget), targetCalldata: callData2, readers: readers2});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 2});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        assertEq(mock.getOutput(fuse.VERSION(), 0), TypeConversionLib.toBytes32(value1));
        assertEq(mock.getOutput(fuse.VERSION(), 1), TypeConversionLib.toBytes32(value2));
    }

    /// @notice Test revert when data length is too long
    function testEnterRevertDataTooLong() public {
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint256.selector, uint256(100));

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 0, bytesEnd: 33});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);

        vm.expectRevert(TransientStorageChainReaderFuse.DataTooLong.selector);
        mock.enter(data);
    }

    /// @notice Test revert when out of bounds
    function testEnterRevertOutOfBounds() public {
        bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint256.selector, uint256(100));

        ExternalCall[] memory calls = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
        readers[0] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 0, bytesEnd: 33});
        calls[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData, readers: readers});

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 1});

        bytes memory data = abi.encode(externalCalls);

        vm.expectRevert(TransientStorageChainReaderFuse.DataTooLong.selector);
        mock.enter(data);
    }

    /// @notice Test with empty calls array
    function testEnterWithEmptyCalls() public {
        ExternalCall[] memory calls = new ExternalCall[](0);

        ExternalCalls memory externalCalls = ExternalCalls({calls: calls, responsLength: 0});

        bytes memory data = abi.encode(externalCalls);
        mock.enter(data);

        bytes32[] memory outputs = mock.getOutputs(fuse.VERSION());
        assertEq(outputs.length, 0);
    }

    /// @notice Test that outputs are cleared before setting new ones
    function testEnterClearsOutputs() public {
        uint256 value1 = 100;
        bytes memory callData1 = abi.encodeWithSelector(MockTarget.returnUint256.selector, value1);

        ExternalCall[] memory calls1 = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers1 = new ReadDataFromResponse[](1);
        readers1[0] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 0, bytesEnd: 32});
        calls1[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData1, readers: readers1});

        ExternalCalls memory externalCalls1 = ExternalCalls({calls: calls1, responsLength: 1});

        bytes memory data1 = abi.encode(externalCalls1);
        mock.enter(data1);

        assertEq(mock.getOutput(fuse.VERSION(), 0), TypeConversionLib.toBytes32(value1));

        uint256 value2 = 200;
        bytes memory callData2 = abi.encodeWithSelector(MockTarget.returnUint256.selector, value2);

        ExternalCall[] memory calls2 = new ExternalCall[](1);
        ReadDataFromResponse[] memory readers2 = new ReadDataFromResponse[](1);
        readers2[0] = ReadDataFromResponse({dataType: DataType.UINT256, bytesStart: 0, bytesEnd: 32});
        calls2[0] = ExternalCall({target: address(mockTarget), targetCalldata: callData2, readers: readers2});

        ExternalCalls memory externalCalls2 = ExternalCalls({calls: calls2, responsLength: 1});

        bytes memory data2 = abi.encode(externalCalls2);
        mock.enter(data2);

        bytes32[] memory outputs = mock.getOutputs(fuse.VERSION());
        assertEq(outputs.length, 1);
        assertEq(outputs[0], TypeConversionLib.toBytes32(value2));
    }
}
