// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface MComptroller {
    /// @notice Enters multiple markets (enables them as collateral)
    /// @param mTokens The list of markets to enter
    /// @return uint[] Returns array of error codes (0=success, otherwise a failure)
    function enterMarkets(address[] calldata mTokens) external returns (uint256[] memory);

    /// @notice Exits a market (disables it as collateral)
    /// @param mToken The market to exit
    /// @return uint Returns error code (0=success, otherwise a failure)
    function exitMarket(address mToken) external returns (uint256);

    function claimReward(address holder, address[] memory mTokens) external;

    function rewardDistributor() external view returns (address);
}
