// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {TransientStorageChainReaderFuse} from "../../../contracts/fuses/transient_storage/TransientStorageChainReaderFuse.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";

/// @title TransientStorageChainReaderFuseMock
/// @notice Mock contract for executing fuse via delegatecall
/// @author IPOR Labs
contract TransientStorageChainReaderFuseMock {
    using Address for address;

    /// @notice The fuse contract address
    address public fuse;

    /// @notice Constructor
    /// @param fuse_ The address of the fuse contract
    constructor(address fuse_) {
        fuse = fuse_;
    }

    /// @notice Executes enter function via delegatecall
    /// @param data_ The encoded ExternalCalls struct containing calls and readers
    function enter(bytes calldata data_) external {
        address(fuse).functionDelegateCall(
            abi.encodeWithSelector(TransientStorageChainReaderFuse.enter.selector, data_)
        );
    }

    /// @notice Retrieves all output parameters for a specific account
    /// @param account_ The address of the account
    /// @return outputs Array of output values
    function getOutputs(address account_) external view returns (bytes32[] memory) {
        return TransientStorageLib.getOutputs(account_);
    }

    /// @notice Retrieves a single output parameter for a specific account at a given index
    /// @param account_ The address of the account
    /// @param index_ The index of the output parameter
    /// @return The output value at the specified index
    function getOutput(address account_, uint256 index_) external view returns (bytes32) {
        return TransientStorageLib.getOutput(account_, index_);
    }
}

/// @title MockTarget
/// @notice Mock contract for testing external calls
/// @author IPOR Labs
contract MockTarget {
    /// @notice Returns a uint256 value
    /// @param value_ The value to return
    /// @return The value
    function returnUint256(uint256 value_) external pure returns (uint256) {
        return value_;
    }

    /// @notice Returns a uint128 value
    /// @param value_ The value to return
    /// @return The value
    function returnUint128(uint128 value_) external pure returns (uint128) {
        return value_;
    }

    /// @notice Returns a uint64 value
    /// @param value_ The value to return
    /// @return The value
    function returnUint64(uint64 value_) external pure returns (uint64) {
        return value_;
    }

    /// @notice Returns a uint32 value
    /// @param value_ The value to return
    /// @return The value
    function returnUint32(uint32 value_) external pure returns (uint32) {
        return value_;
    }

    /// @notice Returns a uint16 value
    /// @param value_ The value to return
    /// @return The value
    function returnUint16(uint16 value_) external pure returns (uint16) {
        return value_;
    }

    /// @notice Returns a uint8 value
    /// @param value_ The value to return
    /// @return The value
    function returnUint8(uint8 value_) external pure returns (uint8) {
        return value_;
    }

    /// @notice Returns an int256 value
    /// @param value_ The value to return
    /// @return The value
    function returnInt256(int256 value_) external pure returns (int256) {
        return value_;
    }

    /// @notice Returns an int128 value
    /// @param value_ The value to return
    /// @return The value
    function returnInt128(int128 value_) external pure returns (int128) {
        return value_;
    }

    /// @notice Returns an int64 value
    /// @param value_ The value to return
    /// @return The value
    function returnInt64(int64 value_) external pure returns (int64) {
        return value_;
    }

    /// @notice Returns an int32 value
    /// @param value_ The value to return
    /// @return The value
    function returnInt32(int32 value_) external pure returns (int32) {
        return value_;
    }

    /// @notice Returns an int16 value
    /// @param value_ The value to return
    /// @return The value
    function returnInt16(int16 value_) external pure returns (int16) {
        return value_;
    }

    /// @notice Returns an int8 value
    /// @param value_ The value to return
    /// @return The value
    function returnInt8(int8 value_) external pure returns (int8) {
        return value_;
    }

    /// @notice Returns an address value
    /// @param value_ The value to return
    /// @return The value
    function returnAddress(address value_) external pure returns (address) {
        return value_;
    }

    /// @notice Returns a bool value
    /// @param value_ The value to return
    /// @return The value
    function returnBool(bool value_) external pure returns (bool) {
        return value_;
    }

    /// @notice Returns a bytes32 value
    /// @param value_ The value to return
    /// @return The value
    function returnBytes32(bytes32 value_) external pure returns (bytes32) {
        return value_;
    }

    /// @notice Returns multiple values
    /// @param value1_ First value
    /// @param value2_ Second value
    /// @param value3_ Third value
    /// @return The values
    function returnMultiple(
        uint256 value1_,
        uint256 value2_,
        uint256 value3_
    ) external pure returns (uint256, uint256, uint256) {
        return (value1_, value2_, value3_);
    }

    /// @notice Returns custom bytes data
    /// @param data_ The data to return
    /// @return The data
    function returnBytes(bytes memory data_) external pure returns (bytes memory) {
        return data_;
    }
}
