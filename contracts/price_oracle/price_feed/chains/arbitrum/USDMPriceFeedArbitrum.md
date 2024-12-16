# USDMPriceFeedArbitrum

## Overview

USDMPriceFeedArbitrum is a price feed contract that provides the USD price for USDM tokens on Arbitrum. It implements the IPriceFeed interface and uses (Chronicle's)[https://chroniclelabs.org/] push-based oracle system to obtain price data for wUSDM (wrapped USDM).

## Purpose

The contract serves two main purposes:

1. Provides a standardized price feed interface for USDM tokens
2. Calculates the USDM price by combining:
    - wUSDM/USD price from Chronicle Oracle
    - wUSDM/USDM exchange rate from the wUSDM ERC4626 vault

## Key Components

### Constants

-   WAD_UNIT: Standard decimal unit (1e18) used for precise calculations
-   CHRONICLE_DECIMALS: Number of decimals used by Chronicle Oracle (18)
-   WUSDM_USD_ORACLE_FEED: Address of Chronicle Oracle for wUSDM/USD price
-   WUSDM: Address of the wrapped USDM (wUSDM) ERC4626 vault

### State Variables

-   CHRONICLE: Immutable reference to the Chronicle Oracle contract
-   PRICE_DENOMINATOR: Immutable scaling factor to convert between decimal precisions

## Key Functions

### constructor

Initializes the contract by:

-   Setting up Chronicle Oracle reference
-   Validating Oracle decimals
-   Computing price denominator for decimal conversion

### latestRoundData

Returns the latest USDM price data with the following steps:

1. Fetches wUSDM/USD price from Chronicle Oracle
2. Gets wUSDM total supply and assets to calculate exchange rate
3. Combines prices to determine USDM/USD value
4. Applies decimal scaling
5. Returns price data in Chainlink-compatible format

Key validations:

-   Checks for zero price from Oracle
-   Validates non-zero total supply
-   Ensures final price is non-zero

### decimals

Returns the number of decimal places for price values (8)

## Security Considerations

1. Oracle Security:

    - Chronicle Oracle must whitelist this contract as an authorized reader
    - Price feed is only as secure as the underlying Chronicle Oracle

2. Price Calculation:

    - Multiple checks for zero values to prevent invalid prices
    - Careful ordering of mathematical operations to maintain precision
    - Use of SafeCast for type conversions

3. Immutability:
    - Core components (Oracle address, WUSDM address) are immutable
    - Decimal configurations are validated at construction

## Integration Notes

The contract is designed to be used with:

-   Chronicle Oracle system on Arbitrum
-   wUSDM ERC4626 vault
-   Price Oracle systems expecting Chainlink-compatible interfaces

Price updates are push-based through Chronicle, ensuring fresh price data without active maintenance.
