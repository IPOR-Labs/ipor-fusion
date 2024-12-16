# WETHPriceFeed

## Overview

WETHPriceFeed is a price feed contract that provides the USD price for WETH (Wrapped Ether) tokens. It implements the IPriceFeed interface and uses Chainlink's ETH/USD price feed to determine the WETH price in USD, leveraging the 1:1 peg between WETH and ETH.

## Purpose

The contract serves two main purposes:

1. Provides a standardized price feed interface for WETH tokens
2. Delivers accurate WETH/USD pricing by:
    - Using ETH/USD price from Chainlink Oracle
    - Applying the 1:1 WETH/ETH ratio

## Key Components

### Constants

-   PRICE_FEED_DECIMALS: Fixed decimal precision (8) for price output
-   ETH_USD_CHAINLINK_FEED: Address of Chainlink's ETH/USD price feed
    -   Arbitrum: 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
    -   Ethereum: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419

### Dependencies

-   AggregatorV3Interface: For interacting with Chainlink price feeds
-   IPriceFeed: Interface defining the price feed standard

### Events

-   PriceFeedInitialized: Emitted when the contract is initialized with the Chainlink feed address

### Custom Errors

-   ZeroAddress: When zero address is provided for Chainlink feed
-   InvalidDecimals: When decimal precision doesn't match requirements
-   InvalidPrice: When ETH/USD price is invalid (≤ 0)

## Key Functions

### constructor

Initializes the contract by:

-   Validating the Chainlink feed address is not zero
-   Ensuring the contract's decimal precision matches the Chainlink feed
-   Emitting PriceFeedInitialized event

### decimals

Returns the number of decimal places for price values (8)

### latestRoundData

Returns the latest WETH price data with the following steps:

1. Fetches ETH/USD price data from Chainlink Oracle
2. Validates the price data
3. Returns the price data in Chainlink-compatible format

Key validations:

-   Ensures ETH/USD price is above zero
-   Validates timestamp is non-zero

## Security Considerations

1. Oracle Security:

    - Uses Chainlink's ETH/USD price feed
    - Validates price data to ensure it's positive
    - Uses immutable address for Chainlink feed

2. Price Validation:

    - Checks for invalid price values (≤ 0)
    - Validates timestamp to ensure fresh data
    - Maintains original Chainlink round data for auditability

3. Error Handling:

    - Custom errors for different failure scenarios:
        - ZeroAddress: Invalid Chainlink feed address
        - InvalidDecimals: Decimal precision mismatch
        - InvalidPrice: Invalid price data

4. Decimal Precision:
    - Maintains 8 decimal places for consistency
    - Validates decimal precision at construction
    - Uses constant for decimal specification

## Integration Notes

The contract is designed to work with:

-   Chainlink Oracle system
-   Systems requiring WETH/USD price data
-   Price Oracle systems expecting Chainlink-compatible interfaces

The price feed leverages two key properties:

1. Reliable ETH/USD price from Chainlink
2. The fundamental 1:1 peg between WETH and ETH

This ensures accurate pricing that reflects:

-   The current market price of ETH
-   The perfect fungibility between WETH and ETH

## Technical Details

The price calculation is straightforward due to the 1:1 peg:
