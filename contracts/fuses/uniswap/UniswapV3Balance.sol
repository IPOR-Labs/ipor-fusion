// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./ext/INonfungiblePositionManager.sol";
import {PositionValue} from "./ext/PositionValue.sol";

/**
 * @title UniswapV3Balance
 * @notice Fuse balance for Uniswap V3 positions
 * @dev This contract calculates the total balance of assets in Uniswap V3 liquidity positions
 *      by iterating through all position token IDs stored in fuse storage, calculating the
 *      value of each position (including fees and principal), and converting to USD using
 *      the price oracle middleware.
 * @author IPOR Labs
 */
contract UniswapV3Balance is IMarketBalanceFuse {
    using Address for address;

    error InvalidReturnData();

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to identify the market
    uint256 public immutable MARKET_ID;

    /// @notice Nonfungible Position Manager contract address
    /// @dev Manages NFTs representing Uniswap V3 liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /// @notice Uniswap V3 Factory contract address
    /// @dev Used to get pool addresses from token pairs and fees
    address public immutable UNISWAP_FACTORY;

    /**
     * @notice Initializes the UniswapV3Balance fuse with market ID and protocol addresses
     * @param marketId_ The market ID used to identify the market
     * @param nonfungiblePositionManager_ The address of the Uniswap V3 Nonfungible Position Manager
     * @param uniswapFactory_ The address of the Uniswap V3 Factory
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_, address uniswapFactory_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        UNISWAP_FACTORY = uniswapFactory_;
    }

    /// @notice Extracts token0, token1, and fee from a position using assembly for gas optimization.
    /// @param tokenId_ The ID of the token that represents the position
    /// @return token0 The address of the token0 for a specific pool
    /// @return token1 The address of the token1 for a specific pool
    /// @return fee The fee associated with the pool
    function getPositionInfo(uint256 tokenId_) internal view returns (address token0, address token1, uint24 fee) {
        // INonfungiblePositionManager.positions(tokenId) selector: 0x99fbab88
        // 0x99fbab88 = bytes4(keccak256("positions(uint256)"))
        bytes memory returnData = NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_)
        );

        // positions returns (
        //    uint96 nonce,                    // offset 0
        //    address operator,                // offset 1
        //    address token0,                  // offset 2
        //    address token1,                  // offset 3
        //    uint24 fee,                      // offset 4
        //    ... )
        // All types are padded to 32 bytes in ABI encoding.

        if (returnData.length < 160) revert InvalidReturnData();

        assembly {
            // returnData is a pointer to bytes array in memory.
            // First 32 bytes at returnData is the length of the array.
            // The actual data starts at returnData + 32.

            // We need to skip nonce (index 0) and operator (index 1).
            // Each slot is 32 bytes.
            // token0 is at index 2: 32 (length) + 32 * 2 = 96
            token0 := mload(add(returnData, 96))

            // token1 is at index 3: 32 (length) + 32 * 3 = 128
            token1 := mload(add(returnData, 128))

            // fee is at index 4: 32 (length) + 32 * 4 = 160
            // fee is uint24, so we need to mask the upper bits
            // mload loads 32 bytes, but fee is only 24 bits (3 bytes)
            // We need to mask to get only the lower 24 bits: 0xFFFFFF
            let feeValue := mload(add(returnData, 160))
            fee := and(feeValue, 0xFFFFFF)
        }
    }

    /// @notice Gets sqrtPriceX96 from a pool using assembly for gas optimization.
    /// @param token0_ The address of the token0 for a specific pool
    /// @param token1_ The address of the token1 for a specific pool
    /// @param fee_ The fee associated with the pool
    /// @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
    function getSqrtPriceX96(
        address token0_,
        address token1_,
        uint24 fee_
    ) internal view returns (uint160 sqrtPriceX96) {
        address pool = IUniswapV3Factory(UNISWAP_FACTORY).getPool(token0_, token1_, fee_);

        // IUniswapV3Pool.slot0() selector: 0x3850c7bd
        // 0x3850c7bd = bytes4(keccak256("slot0()"))
        bytes memory returnData = pool.functionStaticCall(abi.encodeWithSelector(IUniswapV3Pool.slot0.selector));

        // slot0 returns (
        //    uint160 sqrtPriceX96,            // offset 0
        //    int24 tick,                      // offset 1
        //    uint16 observationIndex,         // offset 2
        //    uint16 observationCardinality,   // offset 3
        //    uint16 observationCardinalityNext, // offset 4
        //    uint8 feeProtocol,               // offset 5
        //    bool unlocked                    // offset 6
        //    )
        // All types are padded to 32 bytes in ABI encoding.

        if (returnData.length < 64) revert InvalidReturnData();

        assembly {
            // returnData is a pointer to bytes array in memory.
            // First 32 bytes at returnData is the length of the array.
            // The actual data starts at returnData + 32.

            // sqrtPriceX96 is at index 0: 32 (length) + 32 * 0 = 32
            // sqrtPriceX96 is uint160, so we need to mask the upper bits
            // mload loads 32 bytes, but sqrtPriceX96 is only 160 bits (20 bytes)
            // We need to mask to get only the lower 160 bits: 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
            let sqrtPriceValue := mload(add(returnData, 32))
            sqrtPriceX96 := and(sqrtPriceValue, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /**
     * @notice Calculates the total assets in the market for Uniswap V3 positions
     * @dev This function:
     *      1. Retrieves all Uniswap V3 position token IDs from fuse storage
     *      2. For each position, extracts token0, token1, and fee information
     *      3. Gets the current pool price (sqrtPriceX96) from the Uniswap V3 pool
     *      4. Calculates the total value of the position (principal + fees) using PositionValue.total()
     *      5. Converts token0 and token1 amounts to USD using the price oracle middleware
     *      6. Sums all position values and returns the total balance in USD (WAD format, 18 decimals)
     * @return balance The total balance of assets in the market, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        uint256[] memory tokenIds = FuseStorageLib.getUniswapV3TokenIds().tokenIds;
        uint256 len = tokenIds.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware;
        uint256 balance;
        address token0;
        address token1;
        uint24 fee;
        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
        uint256 priceToken;
        uint256 priceDecimals;

        priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            {
                (token0, token1, fee) = getPositionInfo(tokenIds[i]);

                sqrtPriceX96 = getSqrtPriceX96(token0, token1, fee);
            }

            /// @dev Calculation of amount for token0 and token1 in existing position, take into account the fees
            /// and principal that a given nonfungible position manager token is worth
            (amount0, amount1) = PositionValue.total(
                INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER),
                tokenIds[i],
                sqrtPriceX96
            );

            (priceToken, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(token0);

            balance += IporMath.convertToWad((amount0) * priceToken, IERC20Metadata(token0).decimals() + priceDecimals);

            (priceToken, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(token1);
            balance += IporMath.convertToWad((amount1) * priceToken, IERC20Metadata(token1).decimals() + priceDecimals);
        }

        return balance;
    }
}
