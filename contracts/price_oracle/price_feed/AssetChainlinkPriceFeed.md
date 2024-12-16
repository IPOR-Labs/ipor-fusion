# AssetChainlinkPriceFeed

## Overview

AssetChainlinkPriceFeed is a price feed contract that provides USD prices for any asset using two Chainlink price feeds. It implements the IPriceFeed interface and combines two price feeds (ASSET_X/ASSET_Y and ASSET_Y/USD) to calculate the ASSET_X price in USD.

## Purpose

The contract serves two main purposes:

1. Provides a standardized price feed interface for any asset that doesn't have a direct USD price feed
2. Calculates the asset's USD price by combining:
    - ASSET_X/ASSET_Y price from first Chainlink Oracle
    - ASSET_Y/USD price from second Chainlink Oracle

## Key Components

### Immutable State Variables

-   ASSET_X: Address of the asset for which the price feed is provided
-   ASSET_X_ASSET_Y_CHAINLINK_FEED: Address of Chainlink's ASSET_X/ASSET_Y price feed
-   ASSET_Y_USD_CHAINLINK_FEED: Address of Chainlink's ASSET_Y/USD price feed
-   PRICE_DENOMINATOR: Denominator used to normalize price decimals between feeds

### Dependencies

-   SafeCast: For safe numerical type conversions
-   Math: For safe mathematical operations
-   AggregatorV3Interface: For interacting with Chainlink price feeds
-   IPriceFeed: Interface that defines the price feed standard

## Key Functions

### constructor

Initializes the contract by:

-   Validating non-zero addresses for all inputs
-   Setting up immutable references to assets and price feeds
-   Calculating the price denominator based on decimal places of both feeds
-   Validating that feed decimals are within reasonable range (≤ 18)

### decimals

Returns the number of decimal places for price values (8)

### latestRoundData

Returns the latest asset price data with the following steps:

1. Fetches ASSET_Y/USD price from Chainlink Oracle
2. Fetches ASSET_X/ASSET_Y price from Chainlink Oracle
3. Validates both prices are positive
4. Combines both rates to calculate ASSET_X/USD price
5. Returns price data in Chainlink-compatible format including:
    - Combined round ID
    - Calculated price
    - Earlier of the two start times
    - Earlier of the two update times
    - Combined answered in round ID

## Security Considerations

1. Oracle Security:

    - Uses two independent Chainlink price feeds
    - Validates both price feeds return positive values
    - Uses immutable addresses for critical contracts

2. Price Calculation:

    - Multiple checks for invalid values
    - Safe mathematical operations using OpenZeppelin's Math library
    - Safe type conversions using SafeCast

3. Error Handling:

    - Custom errors for different failure scenarios:
        - ZeroAddress: When any input address is zero
        - InvalidDecimals: When feed decimals exceed 18
        - NegativeOrZeroPrice: When either price feed returns <= 0

4. Decimal Precision:
    - Maintains 8 decimal places for compatibility with other price feeds
    - Properly scales values during calculations using PRICE_DENOMINATOR
    - Validates decimal precision of input feeds at construction

## Integration Notes

The contract is designed to work with:

-   Any two compatible Chainlink Oracle price feeds
-   Systems requiring standardized price feed interfaces
-   DeFi protocols needing derived asset prices

The price calculation combines two sources of data:

1. ASSET_X/ASSET_Y price from first Chainlink feed
2. ASSET_Y/USD price from second Chainlink feed

This ensures accurate pricing that reflects:

-   The relationship between ASSET_X and ASSET_Y
-   The current market price of ASSET_Y in USD
-   Proper decimal scaling between different feed precisions

## Technical Details

The price calculation follows the formula:

price = (assetYPriceInUsd \* assetXPriceInAssetY) / PRICE_DENOMINATOR

Where:

-   assetYPriceInUsd: Price of ASSET_Y in USD from ASSET_Y_USD_CHAINLINK_FEED
-   assetXPriceInAssetY: Price of ASSET_X in terms of ASSET_Y from ASSET_X_ASSET_Y_CHAINLINK_FEED
-   PRICE_DENOMINATOR: Scaling factor calculated as 10^((decimalsX/Y + decimalsY/USD) - 8)

The PRICE_DENOMINATOR is calculated during construction to ensure the final price maintains 8 decimal places, regardless of the input feed decimal places.

## Round ID Handling

The contract combines round IDs from both price feeds using the formula:

combinedRoundId = (id1 + id2) / 2

This provides a unified round ID that represents data from both feeds while maintaining the expected uint80 format.

## Implementation Notes

1. The contract uses OpenZeppelin's:

    - SafeCast for safe numerical conversions between int256 and uint256
    - Math library for safe multiplication and division operations

2. All price validations ensure positive non-zero values

3. The contract maintains consistency with Chainlink's AggregatorV3Interface while providing derived asset prices

4. Timestamp handling uses the earlier of the two feeds' timestamps to ensure conservative price reporting
