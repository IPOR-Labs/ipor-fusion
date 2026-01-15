// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPriceFeed} from "./IPriceFeed.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {ITokiChainlinkCompatOracle} from "./ext/ITokiChainlinkCompatOracle.sol";
import {IPrincipalToken} from "../../../contracts/fuses/napier/ext/IPrincipalToken.sol";
import {ITokiPoolToken} from "../../../contracts/fuses/napier/ext/ITokiPoolToken.sol";

/// @title Price feed for Napier v2 Yield Tokens
/// @notice Provides USD price data for Napier YT using the on-chain {TokiOracle}
/// @dev The deployer must first deploy a linear price oracle whose base asset is the principal token,
///      then pass that oracle to this constructor
contract NapierYtLinearPriceFeed is IPriceFeed {
    using SafeCast for *;

    int256 constant PT_PAR_PRICE = 1e18;

    uint8 public constant TOKI_CHAINLINK_ORACLE_DECIMALS = 18;

    /// @notice Address of the Napier Toki Chainlink AggregatorV3Interface compatible oracle
    ITokiChainlinkCompatOracle public immutable TOKI_CHAINLINK_ORACLE;

    /// @notice Address of the Napier liquidity token (Toki pool token)
    address public immutable LIQUIDITY_TOKEN;

    /// @notice Address of the price oracle middleware expected to supply USD prices
    address public immutable PRICE_MIDDLEWARE;

    /// @notice Address of the asset used as base for the pricing asset
    address public immutable BASE;

    /// @notice Address of the asset used for pricing
    address public immutable QUOTE;

    error PriceOracleZeroAddress();
    error PriceOracleInvalidPrice();
    error PriceOracleInvalidQuoteAsset();
    error PriceOracleInvalidBaseAsset();

    /// @notice Configure the YT price feed
    constructor(address priceMiddleware_, address tokiChainlinkOracle_) {
        if (tokiChainlinkOracle_ == address(0) || priceMiddleware_ == address(0)) {
            revert PriceOracleZeroAddress();
        }

        (address liquidityToken, address base, address quote, ) = ITokiChainlinkCompatOracle(tokiChainlinkOracle_)
            .parseImmutableArgs();

        PoolKey memory key = ITokiPoolToken(liquidityToken).i_poolKey();
        address pt = Currency.unwrap(key.currency1);

        if (base != pt) {
            revert PriceOracleInvalidBaseAsset();
        }

        address baseAsset = IPrincipalToken(pt).i_asset();

        if (quote != baseAsset) {
            revert PriceOracleInvalidQuoteAsset();
        }

        TOKI_CHAINLINK_ORACLE = ITokiChainlinkCompatOracle(tokiChainlinkOracle_);
        LIQUIDITY_TOKEN = liquidityToken;
        PRICE_MIDDLEWARE = priceMiddleware_;
        BASE = IPrincipalToken(pt).i_yt();
        QUOTE = quote;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
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
        // YT price in asset = 1 - PT price in asset
        (, int256 unitPtPrice, , , ) = TOKI_CHAINLINK_ORACLE.latestRoundData();
        int256 unitPrice = PT_PAR_PRICE - unitPtPrice;

        (uint256 assetPrice, uint256 priceDecimals) = IPriceOracleMiddleware(PRICE_MIDDLEWARE).getAssetPrice(QUOTE);

        price = ((unitPrice.toUint256() * assetPrice) / 10 ** priceDecimals).toInt256();

        if (price == 0 && unitPrice != 0) {
            revert PriceOracleInvalidPrice();
        }

        if (price < 0) {
            revert PriceOracleInvalidPrice();
        }

        time = block.timestamp;
    }

    /// @notice Returns the current price of the configured quote asset from the middleware
    function getPricingAssetPrice() external view returns (uint256 price, uint256 decimals_) {
        return IPriceOracleMiddleware(PRICE_MIDDLEWARE).getAssetPrice(QUOTE);
    }
}
