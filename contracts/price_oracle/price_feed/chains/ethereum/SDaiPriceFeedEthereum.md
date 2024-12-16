# SDaiPriceFeedEthereum

## Overview

SDaiPriceFeedEthereum is a price feed contract that provides the USD price for sDai (Savings Dai) tokens on Ethereum Mainnet. It implements the IPriceFeed interface and combines Chainlink's DAI/USD price feed with the sDai/DAI exchange rate from the Savings Dai contract to determine the sDai price in USD.

## Purpose

The contract serves two main purposes:

1. Provides a standardized price feed interface for sDai tokens
2. Calculates the sDai price by combining:
    - DAI/USD price from Chainlink Oracle
    - sDai/DAI exchange rate from the Savings Dai contract

## Key Components

### Constants

-   DAI_CHAINLINK_FEED: Address of Chainlink's DAI/USD price feed on Ethereum Mainnet (0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9)
-   SDAI: Address of the Savings Dai contract on Ethereum Mainnet (0x83F20F44975D03b1b09e64809B757c47f942BEeA)

### Dependencies

-   SafeCast: For safe numerical type conversions
-   Math: For safe mathematical operations
-   AggregatorV3Interface: For interacting with Chainlink price feeds
-   ISavingsDai: For interacting with the Savings Dai contract

## Key Functions

### constructor

Initializes the contract by:

-   Validating that the contract's decimal precision matches the Chainlink feed
-   This check is only needed at construction since DAI_CHAINLINK_FEED is immutable

### decimals

Returns the number of decimal places for price values (8)

### latestRoundData

Returns the latest sDai price data with the following steps:

1. Fetches DAI/USD price from Chainlink Oracle
2. Gets sDai/DAI exchange rate from the Savings Dai contract
3. Combines both rates to calculate sDai/USD price
4. Returns price data in Chainlink-compatible format

Key validations:

-   Ensures DAI/USD price is positive
-   Validates non-zero exchange ratio
-   Uses safe mathematical operations throughout

## Security Considerations

1. Oracle Security:

    - Relies on Chainlink's DAI/USD price feed
    - Validates price data to ensure it's positive
    - Uses immutable addresses for critical contracts

2. Price Calculation:

    - Multiple checks for invalid values
    - Safe mathematical operations using OpenZeppelin's Math library
    - Safe type conversions using SafeCast

3. Error Handling:

    - Custom errors for different failure scenarios:
        - InvalidExchangeRatio: When sDai/DAI exchange rate is invalid
        - InvalidPrice: When DAI/USD price is non-positive
        - WrongDecimals: When decimal precision doesn't match requirements

4. Decimal Precision:
    - Maintains 8 decimal places for compatibility with other price feeds
    - Properly scales values during calculations
    - Validates decimal precision at construction

## Integration Notes

The contract is designed to work with:

-   Chainlink Oracle system on Ethereum Mainnet
-   MakerDAO's Savings Dai (sDai) system
-   Price Oracle systems expecting Chainlink-compatible interfaces

The price feed combines two sources of data:

1. DAI/USD price from Chainlink (external)
2. sDai/DAI exchange rate (on-chain from Savings Dai contract)

This ensures accurate pricing that reflects both:

-   The current market price of DAI
-   The additional value accrued in sDai from earned interest

## Events

-   PriceUpdated: Emitted when a new price is calculated
    -   roundId: The round ID from Chainlink feed
    -   price: The calculated price
    -   timestamp: When the price was updated
