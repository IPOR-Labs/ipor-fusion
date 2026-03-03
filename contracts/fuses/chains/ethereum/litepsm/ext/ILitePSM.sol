// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

interface ILitePSM {
    /// @notice Sell USDC (gem) for USDS. Takes USDC from msg.sender, gives USDS to `usr`.
    /// @param usr Address to receive USDS
    /// @param gemAmt Amount of USDC (6 decimals) to sell
    function sellGem(address usr, uint256 gemAmt) external;

    /// @notice Buy USDC (gem) with USDS. Takes USDS from msg.sender, gives USDC to `usr`.
    /// @param usr Address to receive USDC
    /// @param gemAmt Amount of USDC (6 decimals) to buy
    function buyGem(address usr, uint256 gemAmt) external;
}
