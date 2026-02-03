// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPriceFeed} from "./IPriceFeed.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {ITokiOracle} from "./ext/ITokiOracle.sol";
import {IPrincipalToken} from "../../../contracts/fuses/napier/ext/IPrincipalToken.sol";
import {ITokiPoolToken} from "../../../contracts/fuses/napier/ext/ITokiPoolToken.sol";

/// @title Price feed for Napier v2 Yield Tokens
/// @notice Provides USD price data for Napier YT using the on-chain {TokiOracle}
/// @dev Implementation notes:
/// - Expects the pool has sufficient TWAP snapshot capacity; otherwise increase cardinality
/// - Expects at least one TWAP snapshot (observation) to be populated for the pool
/// - Uses a TWAP window to smooth YT price reads; constructor checks oracle readiness for that window
/// @dev If the deployment fails with `PriceOracleOracleNotReady` error,
contract NapierYtTwapPriceFeed is IPriceFeed {
    using SafeCast for *;

    uint32 internal constant MIN_TWAP_WINDOW = 5 minutes;

    /// @notice Napier Toki oracle used for TWAP conversions
    ITokiOracle public immutable TOKI_ORACLE;

    /// @notice Napier liquidity token (Toki pool token)
    address public immutable LIQUIDITY_TOKEN;

    /// @notice Base asset being priced (YT token)
    address public immutable BASE;

    /// @notice Quote asset for pricing (underlying token or base asset)
    address public immutable QUOTE;

    /// @notice TWAP window used for oracle conversions
    uint32 public immutable TWAP_WINDOW;

    address public immutable UNDERLYING_TOKEN;

    /// @notice Expiry date
    uint256 public immutable MATURITY;

    /// @notice Decimals for YT and PT
    uint8 internal immutable BASE_DECIMALS;

    /// @notice Decimals for quote asset (underlying or base asset)
    uint8 internal immutable QUOTE_DECIMALS;

    error PriceOracleZeroAddress();
    error PriceOracleInvalidPrice();
    error PriceOracleInvalidQuoteAsset();
    error PriceOracleInvalidTwapWindow();
    error PriceOracleOracleNotReady(uint16 requiredCardinality);

    /// @notice Configure the YT price feed
    constructor(
        address tokiOracle_,
        address liquidityToken_,
        uint32 twapWindow_,
        address quote_
    ) {
        if (tokiOracle_ == address(0) || liquidityToken_ == address(0)) {
            revert PriceOracleZeroAddress();
        }

        if (twapWindow_ < MIN_TWAP_WINDOW) {
            revert PriceOracleInvalidTwapWindow();
        }

        PoolKey memory key = ITokiPoolToken(liquidityToken_).i_poolKey();
        address underlying = Currency.unwrap(key.currency0);
        address principalToken = Currency.unwrap(key.currency1);
        address baseAsset = IPrincipalToken(principalToken).i_asset();
        address yt = IPrincipalToken(principalToken).i_yt();

        // Allow either underlying token (e.g. YearnUSDC) or base asset (e.g. USDC)
        if (quote_ != underlying && quote_ != baseAsset) {
            revert PriceOracleInvalidQuoteAsset();
        }

        (bool needsCapacityIncrease, uint16 cardinalityRequired, bool hasOldestData) = ITokiOracle(tokiOracle_)
            .checkTwapReadiness(liquidityToken_, twapWindow_);

        // Refuse deployment if TWAP window requirements are not met to avoid stale/zero values.
        if (needsCapacityIncrease || !hasOldestData) {
            revert PriceOracleOracleNotReady(cardinalityRequired);
        }

        TOKI_ORACLE = ITokiOracle(tokiOracle_);
        LIQUIDITY_TOKEN = liquidityToken_;
        BASE = yt;
        QUOTE = quote_;
        TWAP_WINDOW = twapWindow_;
        UNDERLYING_TOKEN = underlying;
        MATURITY = IPrincipalToken(principalToken).maturity();
        BASE_DECIMALS = IERC20Metadata(yt).decimals();
        QUOTE_DECIMALS = IERC20Metadata(quote_).decimals();
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
        // Note Consider YT price to be 1 wei instead of zero, to bypass price validation.
        // 1 wei would be small enough not to affect the vault value
        if (block.timestamp >= MATURITY) {
            return (0, 1, 0, block.timestamp, 0);
        }

        // Use one whole YT unit as base; YT shares follow principal token decimals
        uint256 baseUnit = 10 ** BASE_DECIMALS;
        uint8 quoteDecimals = QUOTE_DECIMALS;

        // Select conversion path based on configured quote asset
        uint256 unitPriceQuote = QUOTE == UNDERLYING_TOKEN
            ? TOKI_ORACLE.convertYtToUnderlying(LIQUIDITY_TOKEN, TWAP_WINDOW, baseUnit)
            : TOKI_ORACLE.convertYtToAssets(LIQUIDITY_TOKEN, TWAP_WINDOW, baseUnit);

        // Normalize quote amount to 18 decimals for downstream USD multiplication
        uint256 unitPrice18 = quoteDecimals < 18
            ? unitPriceQuote * 10 ** (18 - quoteDecimals)
            : unitPriceQuote / 10 ** (quoteDecimals - 18);

        (uint256 quoteUsdPrice, uint256 quoteUsdDecimals) = IPriceOracleMiddleware(msg.sender).getAssetPrice(
            QUOTE
        );

        price = ((unitPrice18 * quoteUsdPrice) / 10 ** quoteUsdDecimals).toInt256();

        if (price <= 0) {
            revert PriceOracleInvalidPrice();
        }

        time = block.timestamp;
    }

    /// @notice Returns the current price of the configured quote asset from the caller middleware
    function getPricingAssetPrice() external view returns (uint256 price, uint256 decimals_) {
        return IPriceOracleMiddleware(msg.sender).getAssetPrice(QUOTE);
    }
}
