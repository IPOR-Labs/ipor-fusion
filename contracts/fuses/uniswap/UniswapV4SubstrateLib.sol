// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @title UniswapV4SubstrateLib
/// @notice Substrate gating for the Uniswap V4 positions market (IporFusionMarkets.UNISWAP_V4).
/// @dev Two-level whitelist:
///      1. Pool identity — the raw PoolId (keccak256(abi.encode(PoolKey))) must be granted as a market
///         substrate. Because the PoolKey contains the hook address, fee tier and tick spacing, granting
///         a PoolId transitively whitelists the pool's hook and parameters.
///      2. Tokens — both pool currencies must be granted as substrate-as-asset (required for
///         price-oracle valuation in UniswapV4Balance and for asset distribution protection).
///      Native-currency pools (currency0 == address(0)) are rejected: the vault holds ERC-20 only and
///      the price oracle middleware has no feed for the zero address.
library UniswapV4SubstrateLib {
    using PoolIdLibrary for PoolKey;

    error UniswapV4UnsupportedPool(bytes32 poolId);
    error UniswapV4UnsupportedToken(address token);
    error UniswapV4NativeCurrencyNotSupported();

    /// @notice Computes the PoolId substrate value for a given PoolKey
    /// @param poolKey_ The Uniswap V4 pool key
    /// @return The PoolId as bytes32 (keccak256(abi.encode(poolKey_))), used as market substrate
    function poolKeyToId(PoolKey memory poolKey_) internal pure returns (bytes32) {
        return PoolId.unwrap(poolKey_.toId());
    }

    /// @notice Validates that the pool and both its tokens are whitelisted for the market
    /// @dev Reverts when the pool uses the native currency, when the PoolId is not granted as a market
    ///      substrate, or when either token is not granted as substrate-as-asset.
    /// @param marketId_ The market ID of the fuse
    /// @param poolKey_ The Uniswap V4 pool key to validate
    function checkPoolKeyGranted(uint256 marketId_, PoolKey memory poolKey_) internal view {
        address token0 = Currency.unwrap(poolKey_.currency0);
        address token1 = Currency.unwrap(poolKey_.currency1);

        if (token0 == address(0)) {
            revert UniswapV4NativeCurrencyNotSupported();
        }

        bytes32 poolId = poolKeyToId(poolKey_);

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, poolId)) {
            revert UniswapV4UnsupportedPool(poolId);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(marketId_, token0)) {
            revert UniswapV4UnsupportedToken(token0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(marketId_, token1)) {
            revert UniswapV4UnsupportedToken(token1);
        }
    }
}
