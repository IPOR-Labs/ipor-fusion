# WstETHPriceFeedEthereum

## Overview

WstETHPriceFeedEthereum is a price feed contract that provides the USD price for wstETH (Wrapped Staked ETH) tokens on Ethereum Mainnet. It implements the IPriceFeed interface and combines Chainlink's stETH/USD price feed with the wstETH/stETH exchange rate from the wstETH contract to determine the wstETH price in USD.

## Purpose

The contract serves two main purposes:

1. Provides a standardized price feed interface for wstETH tokens
2. Calculates the wstETH price by combining:
    - stETH/USD price from Chainlink Oracle
    - wstETH/stETH exchange rate from the wstETH contract

## Key Components

### Constants

-   STETH_CHAINLINK_FEED: Address of Chainlink's stETH/USD price feed on Ethereum Mainnet (0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8)
-   WSTETH: Address of the Wrapped stETH contract on Ethereum Mainnet (0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0)
-   MIN_PRICE: Minimum acceptable price threshold (1e8, representing $1)

### Dependencies

-   SafeCast: For safe numerical type conversions
-   Math: For safe mathematical operations
-   AggregatorV3Interface: For interacting with Chainlink price feeds
-   IWstETH: For interacting with the Wrapped stETH contract

## Key Functions

### constructor

Initializes the contract by:

-   Validating that the contract's decimal precision matches the Chainlink feed
-   This check is only needed at construction since STETH_CHAINLINK_FEED is immutable

### decimals

Returns the number of decimal places for price values (8)

### latestRoundData

Returns the latest wstETH price data with the following steps:

1. Fetches stETH/USD price from Chainlink Oracle
2. Gets wstETH/stETH exchange rate from the wstETH contract
3. Combines both rates to calculate wstETH/USD price
4. Returns price data in Chainlink-compatible format

Key validations:

-   Ensures stETH/USD price is above minimum threshold
-   Validates timestamp is non-zero
-   Validates non-zero exchange ratio
-   Uses safe mathematical operations throughout

## Security Considerations

1. Oracle Security:

    - Relies on Chainlink's stETH/USD price feed
    - Validates price data to ensure it's above minimum threshold
    - Uses immutable addresses for critical contracts

2. Price Calculation:

    - Multiple checks for invalid values
    - Safe mathematical operations using OpenZeppelin's Math library
    - Safe type conversions using SafeCast

3. Error Handling:

    - Custom errors for different failure scenarios:
        - WrongDecimals: When decimal precision doesn't match requirements
        - WrongPrice: When stETH/USD price is below minimum threshold
        - InvalidTimestamp: When price timestamp is invalid
        - InvalidStEthRatio: When wstETH/stETH exchange rate is invalid

4. Decimal Precision:
    - Maintains 8 decimal places for compatibility with other price feeds
    - Properly scales values during calculations
    - Validates decimal precision at construction

## Integration Notes

The contract is designed to work with:

-   Chainlink Oracle system on Ethereum Mainnet
-   Lido's wstETH (Wrapped Staked ETH) system
-   Price Oracle systems expecting Chainlink-compatible interfaces

The price feed combines two sources of data:

1. stETH/USD price from Chainlink (external)
2. wstETH/stETH exchange rate (on-chain from wstETH contract)

This ensures accurate pricing that reflects both:

-   The current market price of stETH
-   The additional value accrued in wstETH from the wrapping mechanism

## Technical Details

The price calculation follows the formula:

price = (stEthUsdPrice \* stEthRatio) / 1e18

Where:

-   stEthUsdPrice: Price of stETH in USD from Chainlink feed
-   stEthRatio: Exchange rate between wstETH and stETH (obtained via getStETHByWstETH)
-   1e18: Denominator to account for stEthRatio's 18 decimal precision

### Error Conditions

The contract implements several error checks:

-   WrongDecimals: Thrown if Chainlink feed decimals don't match expected value (8)
-   WrongPrice: Thrown if stETH/USD price is below MIN_PRICE (1e8 = $1)
-   InvalidTimestamp: Thrown if Chainlink update time is zero
-   InvalidStEthRatio: Thrown if wstETH/stETH ratio is zero

### Price Validation

The contract performs the following validations:

1. Checks that the Chainlink price feed returns a price above MIN_PRICE (1e8)
2. Ensures the timestamp from Chainlink is non-zero
3. Validates that the wstETH/stETH ratio is non-zero

### Decimal Handling

-   The contract maintains 8 decimal places for price output
-   The wstETH/stETH ratio is provided with 18 decimal places
-   Final price calculation properly scales the result to 8 decimals

### Address Constants

-   STETH_CHAINLINK_FEED: 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8
-   WSTETH: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0

The contract preserves Chainlink's round data format while providing accurate wstETH pricing that accounts for both the stETH market price and the current wstETH/stETH exchange rate.
