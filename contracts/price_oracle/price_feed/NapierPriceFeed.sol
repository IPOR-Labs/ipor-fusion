// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";

/// @notice Standard interface for {TokiTWAPChainlinkOracle} and {TokiLinearChainlinkOracle}
interface ITokiChainlinkCompatOracle is AggregatorV3Interface {
    /// @notice Returns the immutable arguments of the Toki Chainlink compatible oracle
    /// @dev Linear discount oracle supports only PT as base asset
    /// @return liquidityToken Address of the Napier liquidity token (Toki pool token)
    /// @return base Address of the base asset (PT or LP)
    /// @return quote Address of the pricing asset (asset or underlying)
    function parseImmutableArgs() external view returns (address liquidityToken, address base, address quote, uint256);
}

/// @title Price feed for Napier v2 Principal Tokens and LP tokens
/// @notice Provides USD price data for Napier PT tokens using the Toki chainlink compatible oracle
/// @dev Implementation notes:
/// - Expects the provided Toki chainlink compatible oracle to be pre-initialized and populated for the pool
/// - PriceOracleMiddleware must have a source configured for the chosen pricing asset (asset or underlying),
///   as determined by the Toki oracle's immutable configuration
contract NapierPriceFeed is IPriceFeed {
    using SafeCast for *;

    uint8 public constant TOKI_CHAINLINK_ORACLE_DECIMALS = 18;

    /// @notice Address of the Napier Toki Chainlink AggregatorV3Interface compatible oracle
    ITokiChainlinkCompatOracle public immutable TOKI_CHAINLINK_ORACLE;

    /// @notice Address of the Napier liquidity token (Toki pool token)
    address public immutable LIQUIDITY_TOKEN;

    /// @notice Address of the price oracle middleware expected to supply USD prices
    address public immutable PRICE_MIDDLEWARE;

    /// @notice Address of the asset used as base for the pricing asset (either PT or LP)
    address public immutable BASE;

    /// @notice Address of the asset used for pricing (either PT asset or PT underlying)
    address public immutable QUOTE;

    error PriceOracleZeroAddress();
    error PriceOracleInvalidPrice();

    constructor(address priceMiddleware_, address tokiChainlinkOracle_) {
        if (tokiChainlinkOracle_ == address(0) || priceMiddleware_ == address(0)) {
            revert PriceOracleZeroAddress();
        }

        (address liquidityToken, address base, address quote, ) = ITokiChainlinkCompatOracle(tokiChainlinkOracle_)
            .parseImmutableArgs();

        TOKI_CHAINLINK_ORACLE = ITokiChainlinkCompatOracle(tokiChainlinkOracle_);
        LIQUIDITY_TOKEN = liquidityToken;
        PRICE_MIDDLEWARE = priceMiddleware_;
        BASE = base;
        QUOTE = quote;
    }

    /// @notice PT prices are returned in 8 decimals to match Chainlink semantics
    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IPriceFeed
    function latestRoundData()
        external
        view
        returns (
            uint80 /* roundId */,
            int256 price,
            uint256 /* startedAt */,
            uint256 time,
            uint80 /* answeredInRound */
        )
    {
        (, int256 unitPrice, , , ) = TOKI_CHAINLINK_ORACLE.latestRoundData();

        (uint256 assetPrice, uint256 priceDecimals) = IPriceOracleMiddleware(msg.sender).getAssetPrice(QUOTE);

        uint256 scalingFactor = TOKI_CHAINLINK_ORACLE_DECIMALS + priceDecimals - decimals();
        price = ((unitPrice.toUint256() * assetPrice) / 10 ** scalingFactor).toInt256();

        if (price <= 0) {
            revert PriceOracleInvalidPrice();
        }

        time = block.timestamp;
    }

    /// @notice Returns the current price of the configured pricing asset from the middleware
    /// @return price Asset price expressed in USD
    /// @return decimals_ Number of decimals returned by the middleware
    function getPricingAssetPrice() external view returns (uint256 price, uint256 decimals_) {
        return IPriceOracleMiddleware(PRICE_MIDDLEWARE).getAssetPrice(QUOTE);
    }
}
