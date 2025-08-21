# Ebisu Fork Implementation Summary

## 🎯 Mission Accomplished

Successfully forked the existing Liquity implementation into a new Ebisu strategy while preserving the original Liquity implementation intact. The Ebisu fork provides comprehensive support for both Trove management and Stability Pool operations.

## 📁 Files Created

### New Directories
- `contracts/fuses/ebisu/` - Main Ebisu fuse implementation directory
- `contracts/fuses/ebisu/ext/` - External interfaces and utilities for Ebisu protocol
- `test/fuses/ebisu/` - Comprehensive test suite for Ebisu functionality

### New Contract Files

#### Core Ebisu Fuses
- `contracts/fuses/ebisu/EbisuFuse.sol` - Main Ebisu Trove management fuse
  - Handles trove creation, management, and liquidation
  - Supports collateral operations (add/withdraw)
  - Manages debt operations (borrow/repay)
  - Interest rate management functionality
  - Comprehensive event logging for all operations
  - IMPROVEMENT: Swap and Pop for efficient array management.

- `contracts/fuses/ebisu/EbisuStabilityPoolFuse.sol` - Stability Pool operations fuse
  - Manages ebUSD deposits to Stability Pool
  - Handles collateral reward claiming
  - Supports partial and full exits from Stability Pool
  - Integration with Universal Token Swapper for reward conversion

- `contracts/fuses/ebisu/EbisuTroveBalanceFuse.sol` - Trove balance calculation fuse
  - Calculates USD-denominated trove positions
  - Handles multiple collateral types (weETH, sUSDe, WBTC, LBTC)
  - Integrates with Ebisu price feeds for accurate valuation

- `contracts/fuses/ebisu/EbisuBalanceFuse.sol` - General Ebisu balance fuse
  - Calculates overall Ebisu protocol exposure
  - Supports both trove and stability pool positions
  - Handles ebUSD and collateral token balances

#### External Interfaces and Utilities
- `contracts/fuses/ebisu/ext/IAddressesRegistry.sol` - Ebisu registry interface 
- `contracts/fuses/ebisu/ext/IActivePool.sol` - Active pool interface
- `contracts/fuses/ebisu/ext/IBorrowerOperations.sol` - Borrower operations interface
- `contracts/fuses/ebisu/ext/IPriceFeed.sol` - Price feed interface
- `contracts/fuses/ebisu/ext/IStabilityPool.sol` - Stability pool interface
- `contracts/fuses/ebisu/ext/ITroveManager.sol` - Trove manager interface
- `contracts/fuses/ebisu/ext/EbisuMath.sol` - Mathematical utilities for Ebisu

#### Storage Management
- `contracts/libraries/EbisuFuseStorageLib.sol` - Ebisu-specific storage library
  - Manages trove position tracking
  - Handles owner index management
  - Provides efficient storage access patterns
  - Implements ERC-7201 storage layout

### New Test Files
- `test/fuses/ebisu/EbisuTroveTest.t.sol` - Comprehensive trove testing
  - Tests trove creation and management
  - Validates collateral and debt operations
  - Tests interest rate management
  - Integration testing with price feeds

- `test/fuses/ebisu/EbisuStabilityPoolFuseTest.t.sol` - Stability pool testing
  - Tests ebUSD deposits and withdrawals
  - Validates collateral reward claiming
  - Tests integration with Universal Token Swapper
  - Comprehensive edge case testing

## 📝 Files Modified

### Market Integration
- `contracts/libraries/IporFusionMarkets.sol`
  - Added `EBISU_TROVE = 34`
  - Added `EBISU_STABILITY_POOL = 35`

## 🏦 Ebisu Addresses Used

### Registry Addresses (weETH Branch)
- `REGISTRY_WEETH = 0x329a7BAA50BB43A6149AF8C9cF781876b6Fd7B3A` - weETH registry
- `REGISTRY_SUSDE = 0x411ED8575a1e3822Bbc763DC578dd9bFAF526C1f` - sUSDe registry
- `REGISTRY_WBTC = 0x0CAc6a40EE0D35851Fd6d9710C5180F30B494350` - WBTC registry
- `REGISTRY_LBTC = 0x7f034988AF49248D3d5bD81a2CE76ED4a3006243` - LBTC registry

### Token Addresses
- `EBUSD = 0x09fD37d9AA613789c517e76DF1c53aEce2b60Df4` - Ebisu stablecoin
- `WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee` - Wrapped eETH
- `SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` - Staked USDe
- `WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` - Wrapped Bitcoin
- `LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494` - Liquid Bitcoin
- `WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` - Wrapped Ether (for fees)

### Price Feed Addresses
- `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` - EBUSD price feed
- `0x36Fb029e6fEeC43d96BE2F8ccC0e572D1663F5fc` - WEETH price feed
- `0x3E58FB6FFd3A568487c72A170411eBf7BE6A2062` - sUSDe price feed
- `0x83387FF1234C2525ec0eb37DFE30d005356A222b` - WBTC price feed
- `0x71AA4e0Ae5435AA3d4724d14dF91C5a26720Cc4f` - LBTC price feed

### Important Implementation Notes
- **Naming Convention**: All possible variables have been renamed from "Liquity" to "Ebisu" and from "BOLD" to "ebUSD" for consistency BUT some variables retain their original names to maintain compatibility with already deployed contracts and external integrations.

## 🚀 Ready for Production

The Ebisu fork is **functionally complete** and pending review by IPOR.

**Status**: ✅ **PENDING REVIEW**