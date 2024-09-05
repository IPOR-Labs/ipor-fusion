// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";

import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./ext/INonfungiblePositionManager.sol";
import {PositionValue} from "./ext/PositionValue.sol";

/// @title Fuse balance for Uniswap V3 positions.
contract UniswapV3Balance is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;
    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable UNISWAP_FACTORY;

    constructor(uint256 marketId_, address nonfungiblePositionManager_, address uniswapFactory_) {
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        UNISWAP_FACTORY = uniswapFactory_;
    }

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
            (, , token0, token1, fee, , , , , , , ) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER)
                .positions(tokenIds[i]);

            (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(IUniswapV3Factory(UNISWAP_FACTORY).getPool(token0, token1, fee))
                .slot0();

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
