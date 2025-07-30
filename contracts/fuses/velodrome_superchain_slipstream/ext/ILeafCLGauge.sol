// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {INonfungiblePositionManager} from "./INonfungiblePositionManager.sol";

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
}
