// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";

/// @title TransientStorageSetInputsFuseMock
/// @notice Mock contract for executing fuse via delegatecall
/// @author IPOR Labs
contract TransientStorageSetInputsFuseMock {
    using Address for address;

    /// @notice The fuse contract address
    address public fuse;

    /// @notice Constructor
    /// @param fuse_ The address of the fuse contract
    constructor(address fuse_) {
        fuse = fuse_;
    }

    /// @notice Executes enter function via delegatecall
    /// @param data_ The data containing the fuse addresses and inputs
    function enter(TransientStorageSetInputsFuseEnterData calldata data_) external {
        address(fuse).functionDelegateCall(abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, data_));
    }

    /// @notice Retrieves all input parameters for a specific account
    /// @param account_ The address of the account
    /// @return inputs Array of input values
    function getInputs(address account_) external view returns (bytes32[] memory) {
        return TransientStorageLib.getInputs(account_);
    }
}
