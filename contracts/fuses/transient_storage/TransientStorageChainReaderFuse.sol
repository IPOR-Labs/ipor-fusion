// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {TypeConversionLib, DataType} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

struct ReadDataFromResponse {
    DataType dataType;
    uint256 bytesStart;
    uint256 bytesEnd;
}

struct ExternalCall {
    address target;
    bytes targetCalldata;
    ReadDataFromResponse[] readers;
}

struct ExternalCalls {
    ExternalCall[] calls;
    // This is a summary (schema) of all readers from the 'calls' array
    uint256 responsLength;
}

contract TransientStorageChainReaderFuse is IFuseCommon {
    using Address for address;

    /// @notice The market ID associated with the Fuse
    uint256 public constant MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;
    address public immutable VERSION;

    constructor() {
        VERSION = address(this);
    }

    error DataTooLong();
    error OutOfBounds();

    /// @notice Decodes and executes external calls, reads data from responses, and stores it in transient storage
    /// @param data_ The encoded ExternalCalls struct containing calls and readers
    function enter(bytes calldata data_) external {
        TransientStorageLib.clearOutputs(VERSION);
        ExternalCalls memory externalCalls = abi.decode(data_, (ExternalCalls));
        bytes32[] memory results = new bytes32[](externalCalls.responsLength);
        uint256 resultsIndex = 0;

        uint256 callsLength = externalCalls.calls.length;
        uint256 readersLength;

        for (uint256 i; i < callsLength; ++i) {
            ExternalCall memory call = externalCalls.calls[i];
            bytes memory returndata = call.target.functionStaticCall(call.targetCalldata);

            readersLength = call.readers.length;
            for (uint256 j; j < readersLength; ++j) {
                ReadDataFromResponse memory reader = call.readers[j];
                bytes32 rawVal = _extractBytes32(returndata, reader.bytesStart, reader.bytesEnd);
                bytes32 convertedVal;

                DataType dataType = reader.dataType;

                if (dataType == DataType.UINT256) {
                    convertedVal = TypeConversionLib.toBytes32(uint256(rawVal));
                } else if (dataType == DataType.UINT128) {
                    convertedVal = TypeConversionLib.toBytes32(uint256(uint128(uint256(rawVal))));
                } else if (dataType == DataType.UINT64) {
                    convertedVal = TypeConversionLib.toBytes32(uint256(uint64(uint256(rawVal))));
                } else if (dataType == DataType.UINT32) {
                    convertedVal = TypeConversionLib.toBytes32(uint256(uint32(uint256(rawVal))));
                } else if (dataType == DataType.UINT16) {
                    convertedVal = TypeConversionLib.toBytes32(uint256(uint16(uint256(rawVal))));
                } else if (dataType == DataType.UINT8) {
                    convertedVal = TypeConversionLib.toBytes32(uint256(uint8(uint256(rawVal))));
                } else if (dataType == DataType.INT256) {
                    convertedVal = TypeConversionLib.toBytes32(int256(uint256(rawVal)));
                } else if (dataType == DataType.INT128) {
                    convertedVal = TypeConversionLib.toBytes32(int256(int128(uint128(uint256(rawVal)))));
                } else if (dataType == DataType.INT64) {
                    convertedVal = TypeConversionLib.toBytes32(int256(int64(uint64(uint256(rawVal)))));
                } else if (dataType == DataType.INT32) {
                    convertedVal = TypeConversionLib.toBytes32(int256(int32(uint32(uint256(rawVal)))));
                } else if (dataType == DataType.INT16) {
                    convertedVal = TypeConversionLib.toBytes32(int256(int16(uint16(uint256(rawVal)))));
                } else if (dataType == DataType.INT8) {
                    convertedVal = TypeConversionLib.toBytes32(int256(int8(uint8(uint256(rawVal)))));
                } else if (dataType == DataType.ADDRESS) {
                    convertedVal = TypeConversionLib.toBytes32(address(uint160(uint256(rawVal))));
                } else if (dataType == DataType.BOOL) {
                    convertedVal = TypeConversionLib.toBytes32(uint256(rawVal) != 0);
                } else if (dataType == DataType.BYTES32) {
                    convertedVal = rawVal;
                } else {
                    convertedVal = rawVal;
                }

                results[resultsIndex++] = convertedVal;
            }
        }

        TransientStorageLib.setOutputs(VERSION, results);
    }

    /// @notice Extracts a bytes32 value from a byte array within a specified range
    /// @param data_ The byte array to extract from
    /// @param start_ The starting index
    /// @param end_ The ending index (exclusive)
    /// @return result The extracted bytes32 value
    function _extractBytes32(bytes memory data_, uint256 start_, uint256 end_) internal pure returns (bytes32 result) {
        uint256 length = end_ - start_;
        if (length > 32) revert DataTooLong();
        if (data_.length < end_) revert OutOfBounds();

        assembly {
            let dataPtr := add(add(data_, 32), start_)
            result := mload(dataPtr)
        }

        if (length < 32) {
            result = result >> ((32 - length) * 8);
        }
    }
}
