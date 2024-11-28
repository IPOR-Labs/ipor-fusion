// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

struct ReadResult {
    bytes data;
}

/**
 * @title UniversalReader
 * @notice Abstract contract that defines the interface for reading data from various protocols
 * @dev This contract serves as a base for implementing protocol-specific readers
 */
abstract contract UniversalReader {
    using Address for address;

    // Custom errors
    error ZeroAddress();
    error UnauthorizedCaller();

    /**
     * @notice Reads data from a target contract
     * @param target The address of the contract to read from
     * @param data The encoded function call data
     * @return result The decoded result data
     * @dev Uses delegatecall to execute the read operation in the context of this contract
     */
    function staticRead(address target, bytes memory data) external view returns (ReadResult memory result) {
        if (target == address(0)) revert ZeroAddress();

        bytes memory returnData = address(this).functionStaticCall(
            abi.encodeWithSignature("readInternal(address,bytes)", target, data)
        );

        result = abi.decode(returnData, (ReadResult));
    }

    function readInternal(address target, bytes memory data) external onlyThis returns (ReadResult memory result) {
        result.data = target.functionDelegateCall(data);
        return result;
    }

    modifier onlyThis() {
        if (msg.sender != address(this)) {
            revert UnauthorizedCaller();
        }
        _;
    }
}
