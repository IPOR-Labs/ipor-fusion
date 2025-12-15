// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TransientStorageLib} from "../../contracts/transient_storage/TransientStorageLib.sol";

/// @title TransientStorageLibMock
/// @notice Mock contract for TransientStorageLib
/// @author IPOR Labs
contract TransientStorageLibMock {
    /// @notice Sets input parameters for a specific account in transient storage
    /// @param account_ The address of the account
    /// @param inputs_ Array of input values
    function setInputs(address account_, bytes32[] memory inputs_) external {
        TransientStorageLib.setInputs(account_, inputs_);
    }

    /// @notice Sets a single input parameter for a specific account at a given index
    /// @param account_ The address of the account
    /// @param index_ The index of the input parameter
    /// @param value_ The value to set
    function setInput(address account_, uint256 index_, bytes32 value_) external {
        TransientStorageLib.setInput(account_, index_, value_);
    }

    /// @notice Retrieves a single input parameter for a specific account at a given index
    /// @param account_ The address of the account
    /// @param index_ The index of the input parameter
    /// @return The input value at the specified index
    function getInput(address account_, uint256 index_) external view returns (bytes32) {
        return TransientStorageLib.getInput(account_, index_);
    }

    /// @notice Retrieves all input parameters for a specific account
    /// @param account_ The address of the account
    /// @return inputs Array of input values
    function getInputs(address account_) external view returns (bytes32[] memory) {
        return TransientStorageLib.getInputs(account_);
    }

    /// @notice Sets output parameters for a specific account in transient storage
    /// @param account_ The address of the account
    /// @param outputs_ Array of output values
    function setOutputs(address account_, bytes32[] memory outputs_) external {
        TransientStorageLib.setOutputs(account_, outputs_);
    }

    /// @notice Retrieves a single output parameter for a specific account at a given index
    /// @param account_ The address of the account
    /// @param index_ The index of the output parameter
    /// @return The output value at the specified index
    function getOutput(address account_, uint256 index_) external view returns (bytes32) {
        return TransientStorageLib.getOutput(account_, index_);
    }

    /// @notice Retrieves all output parameters for a specific account
    /// @param account_ The address of the account
    /// @return outputs Array of output values
    function getOutputs(address account_) external view returns (bytes32[] memory) {
        return TransientStorageLib.getOutputs(account_);
    }

    /// @notice Clears all output parameters for a specific account in transient storage
    /// @param account_ The address of the account
    function clearOutputs(address account_) external {
        TransientStorageLib.clearOutputs(account_);
    }

    /// @notice Clears all input parameters for a specific account in transient storage
    /// @param account_ The address of the account
    function clearInputs(address account_) external {
        TransientStorageLib.clearInputs(account_);
    }
}
