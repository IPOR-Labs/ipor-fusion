// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IPositionManagerV4
/// @notice Minimal interface of the Uniswap V4 PositionManager (periphery) used by IPOR Fusion fuses.
/// @dev Extracted from Uniswap v4-periphery src/interfaces/IPositionManager.sol (v4-periphery is not
///      a repository dependency). Selectors verified against the deployed PositionManager bytecode:
///      modifyLiquidities: 0xdd46508f, getPoolAndPositionInfo: 0x7ba03aad,
///      getPositionLiquidity: 0x1efeed33, nextTokenId: 0x75794a3c.
interface IPositionManagerV4 {
    /// @notice Unlocks Uniswap V4 PoolManager and batches actions for modifying liquidity
    /// @param unlockData is an encoding of actions, and parameters for those actions
    /// @param deadline is the deadline for the batched actions to be executed
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice Used to get the ID that will be used for the next minted liquidity position
    /// @return uint256 The next token ID
    function nextTokenId() external view returns (uint256);

    /// @notice Returns the pool key and packed position info of a position
    /// @param tokenId the ERC721 tokenId
    /// @return poolKey the pool key of the position
    /// @return info packed position info: [0..7] hasSubscriber flag, [8..31] tickLower (int24),
    ///         [32..55] tickUpper (int24), [56..255] truncated (upper 200 bits of) poolId
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);

    /// @notice Returns the liquidity of a position
    /// @param tokenId the ERC721 tokenId
    /// @return liquidity the position's liquidity as a liquidityAmount
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    /// @notice Returns the owner of the position NFT (ERC721)
    /// @param tokenId the ERC721 tokenId
    /// @return owner the owner of the NFT
    function ownerOf(uint256 tokenId) external view returns (address owner);
}
