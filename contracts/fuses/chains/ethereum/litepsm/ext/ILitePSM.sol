// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

interface ILitePSM {
    /// @notice Sell USDC (gem) for USDS. Takes USDC from msg.sender, gives USDS to `usr`.
    /// @dev USDS output is reduced by the `tin` fee: usdsOut = gemAmt18 - gemAmt18 * tin / WAD
    /// @param usr Address to receive USDS
    /// @param gemAmt Amount of USDC (6 decimals) to sell
    /// @return usdsOutWad Amount of USDS received (18 decimals)
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsOutWad);

    /// @notice Buy USDC (gem) with USDS. Takes USDS from msg.sender, gives USDC to `usr`.
    /// @dev USDS input includes the `tout` fee: usdsIn = gemAmt18 + gemAmt18 * tout / WAD
    /// @param usr Address to receive USDC
    /// @param gemAmt Amount of USDC (6 decimals) to buy
    /// @return usdsInWad Amount of USDS consumed (18 decimals)
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsInWad);

    /// @notice Fee applied when selling gem (USDC -> USDS). WAD-based (1e18 = 100%).
    function tin() external view returns (uint256);

    /// @notice Fee applied when buying gem (USDS -> USDC). WAD-based (1e18 = 100%).
    function tout() external view returns (uint256);
}
