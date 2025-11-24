// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {TransientStorageMapperFuse, TransientStorageMapperEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageMapperFuse.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";

/// @title TransientStorageMapperFuseMock
/// @notice Mock contract for executing fuse via delegatecall
/// @author IPOR Labs
contract TransientStorageMapperFuseMock {
    using Address for address;

    /// @notice The fuse contract address
    address public fuse;

    /// @notice Constructor
    /// @param fuse_ The address of the fuse contract
    constructor(address fuse_) {
        fuse = fuse_;
    }

    /// @notice Executes enter function via delegatecall
    /// @param data_ The data containing mapping instructions
    function enter(TransientStorageMapperEnterData calldata data_) external {
        address(fuse).functionDelegateCall(abi.encodeWithSelector(TransientStorageMapperFuse.enter.selector, data_));
    }

    /// @notice Sets input parameters for a specific account in transient storage
    /// @param account_ The address of the account
    /// @param inputs_ Array of input values
    function setInputs(address account_, bytes32[] calldata inputs_) external {
        TransientStorageLib.setInputs(account_, inputs_);
    }

    /// @notice Sets output parameters for a specific account in transient storage
    /// @param account_ The address of the account
    /// @param outputs_ Array of output values
    function setOutputs(address account_, bytes32[] calldata outputs_) external {
        TransientStorageLib.setOutputs(account_, outputs_);
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
}
