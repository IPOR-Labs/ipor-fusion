// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ActionsV4
/// @notice Uniswap V4 periphery action codes used by the PositionManager (liquidity subset).
/// @dev Vendored from Uniswap v4-periphery src/libraries/Actions.sol (constants verified against
///      upstream main). Declared as uint8 so they can be packed directly with abi.encodePacked.
library ActionsV4 {
    /// @notice Add liquidity to an existing position (params: tokenId, liquidity, amount0Max, amount1Max, hookData)
    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    /// @notice Remove liquidity from a position (params: tokenId, liquidity, amount0Min, amount1Min, hookData)
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    /// @notice Mint a new position (params: poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
    uint8 internal constant MINT_POSITION = 0x02;
    /// @notice Burn a position NFT, removing all liquidity (params: tokenId, amount0Min, amount1Min, hookData)
    uint8 internal constant BURN_POSITION = 0x03;
    /// @notice Pay two currencies owed to the pool manager (params: currency0, currency1)
    uint8 internal constant SETTLE_PAIR = 0x0d;
    /// @notice Receive two currencies owed by the pool manager (params: currency0, currency1, recipient)
    uint8 internal constant TAKE_PAIR = 0x11;
}
