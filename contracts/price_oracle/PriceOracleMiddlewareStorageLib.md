# PriceOracleMiddlewareStorageLib

## Overview

PriceOracleMiddlewareStorageLib is a storage library that manages price feed sources for assets in the Price Oracle system. It implements the ERC-7201 namespaced storage pattern to ensure secure and isolated storage management for price feed mappings.

## Purpose

The library serves two main purposes:

1. Provides a secure storage pattern for managing asset price feed sources
2. Implements validation and efficient updates for price feed source mappings

## Key Components

### Storage Structure

-   ASSETS_PRICES_SOURCES: Constant storage slot computed using ERC-7201 pattern
    -   Value: `0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00`
-   AssetsPricesSources: Storage structure containing mapping of asset addresses to price feed addresses
    -   Custom storage location: `erc7201:io.ipor.priceOracle.AssetsPricesSources`

### Events

-   AssetPriceSourceUpdated: Emitted when a price source for an asset is updated
    -   Parameters:
        -   asset: Address of the asset whose price source was updated
        -   source: New price feed source address

### Custom Errors

-   SourceAddressCanNotBeZero(): Thrown when attempting to set a zero address as price source
-   AssetsAddressCanNotBeZero(): Thrown when attempting to set a price source for zero asset address

## Key Functions

### getSourceOfAssetPrice

Returns the price feed source address for a given asset:

-   Input: asset\_ (address of the asset to query)
-   Output: source address (address(0) if no price source is set)
-   View function that reads from storage mapping
-   No state modifications

### setAssetPriceSource

Sets or updates the price feed source for an asset:

-   Inputs:
    -   asset\_: Address of the asset
    -   source\_: Address of the price feed source
-   Validations:
    -   Reverts if asset\_ is zero address with AssetsAddressCanNotBeZero
    -   Reverts if source\_ is zero address with SourceAddressCanNotBeZero
-   State changes:
    -   Updates the price feed source mapping only if the source has changed
    -   Emits AssetPriceSourceUpdated event only on actual changes
-   Gas optimization:
    -   Checks if new source differs from current source before updating
    -   Avoids unnecessary storage writes and events

### \_getAssetsPricesSources (Internal)

Internal function to access the storage slot for assets price sources:

-   Uses assembly for direct storage slot access
-   Returns storage reference to AssetsPricesSources struct
-   Implements ERC-7201 namespaced storage pattern
-   Private pure function

## Security Considerations

1. Storage Safety:

    - Uses ERC-7201 namespaced storage pattern
    - Fixed storage slot prevents collisions
    - Assembly-level storage access for efficiency

2. Input Validation:

    - Strict zero-address checks for both asset and source
    - Custom errors with descriptive messages
    - Prevents invalid state updates

3. State Management:
    - Optimized storage writes
    - Event emission only on actual changes
    - Atomic updates to price feed sources

## Integration Notes

### Implementation Pattern

To use this library:

1. Import the library in your contract
2. Use internal functions to manage price feed sources
3. Handle the emitted events appropriately
4. Implement proper access control in the calling contract

### Storage Pattern

The library implements ERC-7201 namespaced storage pattern with:

1. Namespace: "io.ipor.priceOracle.AssetsPricesSources"
2. Fixed storage slot for collision prevention
3. Structured mapping access through type-safe functions

## Gas Optimization

1. Storage Write Optimization:

    - Checks for value changes before updating storage
    - Prevents unnecessary event emissions
    - Uses assembly for efficient storage slot access

2. Error Handling:
    - Custom errors instead of strings for lower gas costs
    - Early validation to prevent wasted execution
