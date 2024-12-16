# PtPriceFeed

## Overview

PtPriceFeed is a price feed contract that provides USD pricing for Pendle Principal Tokens (PT). It implements the IPriceFeed interface and combines Pendle market rates with underlying asset prices from a middleware oracle to determine PT prices in USD.

## Purpose

The contract serves three main purposes:

1. Provides a standardized price feed interface for Pendle Principal Tokens
2. Calculates PT prices by combining:
    - PT to asset rate from Pendle market
    - Underlying asset price from price oracle middleware
3. Ensures reliable price data through TWAP mechanisms

## Key Components

### Constants

-   MIN_TWAP_WINDOW: Minimum time window for TWAP calculations (5 minutes)
-   FEED_DECIMALS: Standard decimal precision for internal calculations (18)
-   decimals: Output decimal precision for price feed (8)

### Immutable State Variables

-   PENDLE_MARKET: Address of the Pendle market contract
-   TWAP_WINDOW: Duration of the TWAP window (recommended 15 minutes)
-   PRICE_MIDDLEWARE: Address of the price oracle middleware
-   ASSET_ADDRESS: Address of the underlying asset
-   ASSET_DECIMALS: Decimal precision of the underlying asset

### Dependencies

-   IPriceFeed: Standard interface for price feeds
-   IPMarket: Interface for Pendle market interactions
-   PendlePYOracleLib: Library for Pendle oracle calculations
-   IStandardizedYield: Interface for standardized yield token information
-   IPPYLpOracle: Interface for Pendle LP oracle
-   SafeCast: For safe numerical type conversions

## Key Functions

### constructor

Initializes the contract with extensive validation:

1. Validates TWAP window duration (minimum 5 minutes)
2. Verifies non-zero addresses for critical components
3. Checks Pendle oracle readiness
4. Retrieves and stores underlying asset information

### latestRoundData

Returns the latest PT price data through the following steps:

1. Fetches PT to asset rate from Pendle market using TWAP
2. Gets underlying asset price from middleware oracle
3. Combines rates to calculate final PT price in USD
4. Returns price data in Chainlink-compatible format

### getPtToAssetRate

Returns the raw PT to asset rate without price adjustment:

-   Uses Pendle's oracle library for calculations
-   Returns rate with 18 decimal precision

### getUnderlyingPrice

Returns the underlying asset price from middleware:

-   Fetches price directly from configured middleware
-   Returns both price and decimal precision

## Security Considerations

1. Oracle Security:

    - Uses TWAP for manipulation resistance
    - Validates Pendle oracle readiness at deployment
    - Multiple price validation checks

2. Price Calculation:

    - Safe mathematical operations
    - Proper decimal scaling
    - Non-zero price validation

3. Configuration Safety:

    - Immutable critical addresses
    - Validated TWAP window
    - Middleware compatibility checks

4. Error Handling:
    - Custom errors for different failure scenarios:
        - PriceOracleInvalidConfiguration
        - PriceOracleInvalidTwapWindow
        - PriceOraclePendleOracleNotReady
        - PriceOracleZeroAddress
        - PriceOracleInvalidPrice

## Integration Notes

The contract is designed to work with:

-   Pendle Protocol's market system
-   Price oracle middleware supporting the underlying asset
-   Systems expecting Chainlink-compatible price feeds

Key integration requirements:

1. Price Oracle Middleware:

    - Must support the underlying asset
    - Must provide prices with known decimal precision

2. Pendle Market:

    - Must have active oracle
    - Must have sufficient historical data for TWAP

3. TWAP Configuration:
    - Minimum 5 minutes
    - Recommended 15 minutes for optimal security

## Technical Details

The price calculation follows the formula:
