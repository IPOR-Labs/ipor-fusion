// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {INonfungiblePositionManager} from "./INonfungiblePositionManager.sol";
import {ICLPool} from "./ICLPool.sol";

interface ILeafCLGauge {
    /// @notice NonfungiblePositionManager used to create nfts this gauge accepts
    function nft() external view returns (INonfungiblePositionManager);

    /// @notice Used to deposit a CL position into the gauge
    /// @notice Allows the user to receive emissions instead of fees
    /// @param tokenId The tokenId of the position
    function deposit(uint256 tokenId) external;

    /// @notice Used to withdraw a CL position from the gauge
    /// @notice Allows the user to receive fees instead of emissions
    /// @notice Outstanding emissions will be collected on withdrawal
    /// @param tokenId The tokenId of the position
    function withdraw(uint256 tokenId) external;

    /// @notice Fetch all tokenIds staked by a given account
    /// @param depositor The address of the user
    /// @return The tokenIds of the staked positions
    function stakedValues(address depositor) external view returns (uint256[] memory);

    /// @notice Cached address of token0, corresponding to token0 of the pool
    function token0() external view returns (address);

    /// @notice Cached address of token1, corresponding to token1 of the pool
    function token1() external view returns (address);

    /// @notice Address of the CL pool linked to the gauge
    function pool() external view returns (ICLPool);
}
