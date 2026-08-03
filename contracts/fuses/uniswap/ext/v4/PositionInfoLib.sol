// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title PositionInfoLib
/// @notice Decoder for the packed PositionInfo value returned by the Uniswap V4 PositionManager.
/// @dev Layout of the uint256 (verified on-chain against a live position, matches
///      Uniswap v4-periphery src/libraries/PositionInfoLibrary.sol):
///      - bits [0..7]     hasSubscriber flag
///      - bits [8..31]    tickLower (int24)
///      - bits [32..55]   tickUpper (int24)
///      - bits [56..255]  truncated (upper 200 bits of) poolId
library PositionInfoLib {
    /// @notice Extracts the lower tick of the position
    /// @param info_ Packed position info returned by IPositionManagerV4.getPoolAndPositionInfo
    /// @return The tickLower of the position
    function tickLower(uint256 info_) internal pure returns (int24) {
        return int24(uint24(info_ >> 8));
    }

    /// @notice Extracts the upper tick of the position
    /// @param info_ Packed position info returned by IPositionManagerV4.getPoolAndPositionInfo
    /// @return The tickUpper of the position
    function tickUpper(uint256 info_) internal pure returns (int24) {
        return int24(uint24(info_ >> 32));
    }
}
