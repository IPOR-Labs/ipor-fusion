# PriceOracleMiddleware

## Overview

PriceOracleMiddleware is a contract that provides standardized asset price feeds in USD. It implements a hybrid price feed system that combines custom price feeds with Chainlink's Feed Registry as a fallback mechanism. The contract follows the UUPS (Universal Upgradeable Proxy Standard) pattern and includes robust access control.

## Purpose

The contract serves three main purposes:

1. Provides a unified interface for fetching asset prices in USD
2. Supports custom price feed implementations for specific assets
3. Falls back to Chainlink Feed Registry when no custom feed is available

## Key Components

### Constants

-   QUOTE_CURRENCY: Chainlink's standard USD address (0x0000000000000000000000000000000000000348)
-   QUOTE_CURRENCY_DECIMALS: Standard decimal precision for price feeds (8)
-   CHAINLINK_FEED_REGISTRY: Address of Chainlink's Feed Registry (immutable, set in constructor)

### Dependencies

-   Ownable2StepUpgradeable: For secure ownership management
-   UUPSUpgradeable: For upgrade functionality
-   SafeCast: For safe numerical type conversions
-   FeedRegistryInterface: For Chainlink Feed Registry interaction
-   IPriceOracleMiddleware: Main interface definition
-   IPriceFeed: Interface for custom price feeds
-   PriceOracleMiddlewareStorageLib: Storage management

## Key Functions

### initialize

Initializes the contract with:

-   Initial owner (should be a multi-sig wallet)
-   UUPS upgradeability setup

### getAssetPrice

Returns the USD price for a single asset:

1. Checks for custom price feed
2. Falls back to Chainlink if no custom feed exists
3. Returns price and decimals

### getAssetsPrices

Batch operation to get prices for multiple assets:

1. Validates non-empty input array
2. Fetches prices for all assets
3. Returns arrays of prices and decimals

### setAssetsPricesSources

Owner function to configure custom price feeds:

1. Validates input arrays
2. Updates price feed sources for multiple assets
3. Only callable by owner

## Security Considerations

1. Access Control:

    - Two-step ownership transfer (Ownable2Step)
    - Admin functions restricted to owner
    - UUPS upgrade protection

2. Price Feed Security:

    - Validation of price feed decimals
    - Price sanity checks (> 0)
    - Custom error handling
    - Fallback mechanism to Chainlink

3. Input Validation:

    - Non-empty array checks
    - Array length matching
    - Zero address validation
    - Price feed decimal conformity

4. Upgradeability:
    - UUPS pattern for controlled upgrades
    - Protected upgrade authorization
    - Storage management through library

## Integration Notes

The contract is designed to work with:

1. Custom Price Feeds:

    - Must implement IPriceFeed interface
    - Must return prices with 8 decimals
    - Can be added/updated by owner

2. Chainlink Feed Registry:

    - Used as fallback when no custom feed exists
    - Must be configured at deployment
    - Can be disabled by setting to address(0)

3. Storage Management:
    - Uses separate storage library
    - Follows upgrade-safe storage patterns
    - Maintains price feed mappings

## Technical Details

### Price Feed Priority

1. Custom Price Feed:

    - First attempt to use configured custom feed
    - Must match QUOTE_CURRENCY_DECIMALS (8)
    - Must return positive price

2. Chainlink Fallback:
    - Used when no custom feed is set
    - Must be enabled (CHAINLINK_FEED_REGISTRY != address(0))
    - Must support asset/USD pair
    - Must match QUOTE_CURRENCY_DECIMALS (8)

### Error Conditions

The contract reverts when:

-   Empty arrays are provided
-   Array lengths don't match
-   Asset address is zero
-   Price is zero or negative
-   Decimals don't match requirements
-   Asset is unsupported
-   Unauthorized upgrade attempt

### Gas Optimization

The contract implements several gas optimization patterns:

-   Batch price fetching
-   Immutable variables
-   Storage library usage
-   Efficient array handling
-   Short-circuit evaluation
