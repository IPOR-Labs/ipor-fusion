// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

struct ReadResult {
    bytes data;
}

/**
 * @title UniversalReader
 * @notice A base contract for reading data from various protocols in a secure and standardized way
 * @dev This abstract contract provides a secure pattern for delegated reads from external contracts
 *      It uses a two-step read process to ensure security:
 *      1. External call to read()
 *      2. Internal delegatecall through readInternal()
 *
 * Security considerations:
 * - Uses delegatecall for reading data while maintaining context
 * - Implements access control through onlyThis modifier
 * - Prevents calls to zero address
 * - Ensures atomic read operations
 *
 * Usage:
 * - Inherit from this contract to implement protocol-specific readers
 * - Override readInternal() if custom read logic is needed
 * - Always validate target addresses before reading
 *
 * @custom:access Public
 */
abstract contract UniversalReader {
    using Address for address;

    // Custom errors
    /// @notice Thrown when attempting to interact with zero address
    error ZeroAddress();
    /// @notice Thrown when an unauthorized caller tries to access restricted functions
    error UnauthorizedCaller();

    /**
     * @dev Modifier that restricts function access to the contract itself
     * @custom:access Internal
     */
    modifier onlyThis() {
        if (msg.sender != address(this)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    /**
     * @notice Performs a secure read operation on a target contract
     * @dev Uses a two-step process to safely execute delegatecall:
     *      1. Validates target address
     *      2. Executes readInternal through a static call
     *      This ensures that the read operation cannot modify state
     *
     * @param target The address of the contract to read from
     * @param data The encoded function call data to execute on the target
     * @return result The decoded result data from the read operation
     * @custom:access Public
     */
    function read(address target, bytes memory data) external view returns (ReadResult memory result) {
        if (target == address(0)) revert ZeroAddress();

        bytes memory returnData = address(this).functionStaticCall(
            abi.encodeWithSignature("readInternal(address,bytes)", target, data)
        );

        result = abi.decode(returnData, (ReadResult));
    }

    /**
     * @notice Internal function that performs the actual delegatecall to the target
     * @dev This function:
     *      - Can only be called by the contract itself
     *      - Executes the provided data on the target contract using delegatecall
     *      - Maintains the contract's context during the call
     *
     * @param target The address of the contract to delegatecall
     * @param data The encoded function call data
     * @return result The result of the delegatecall wrapped in ReadResult struct
     * @custom:access Internal - only callable by this contract
     */
    function readInternal(address target, bytes memory data) external onlyThis returns (ReadResult memory result) {
        result.data = target.functionDelegateCall(data);
        return result;
    }

    
}
