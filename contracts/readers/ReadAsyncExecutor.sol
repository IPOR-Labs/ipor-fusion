// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AsyncActionFuseLib} from "../fuses/async_action/AsyncActionFuseLib.sol";

/**
 * @title ReadAsyncExecutor
 * @notice Contract for reading AsyncExecutor address from storage
 * @dev Provides method to access the AsyncExecutor address using AsyncActionFuseLib
 *      This function is designed to be called via delegatecall through UniversalReader
 *      on a contract that uses AsyncActionFuseLib (e.g., PlasmaVault)
 */
contract ReadAsyncExecutor {
    /**
     * @notice Reads the AsyncExecutor address from storage
     * @return executorAddress The address of the AsyncExecutor, or address(0) if not set
     * @dev Returns the executor address stored in AsyncActionFuseLib storage
     *      This function must be called via delegatecall from a contract that uses AsyncActionFuseLib
     */
    function readAsyncExecutorAddress() external view returns (address executorAddress) {
        executorAddress = AsyncActionFuseLib.getAsyncExecutor();
    }
}
