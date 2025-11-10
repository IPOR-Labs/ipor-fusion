// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IWETH9 Interface
/// @notice Interface for Wrapped Ether (WETH) token with deposit and withdraw functionality
interface IWETH9 {
    /// @notice Deposit ETH to receive WETH
    function deposit() external payable;

    /// @notice Withdraw ETH from WETH
    /// @param amount_ Amount of WETH to withdraw
    function withdraw(uint256 amount_) external;
}
