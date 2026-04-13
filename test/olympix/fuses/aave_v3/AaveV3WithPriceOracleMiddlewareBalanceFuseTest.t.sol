// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/aave_v3/AaveV3WithPriceOracleMiddlewareBalanceFuse.sol

import {AaveV3WithPriceOracleMiddlewareBalanceFuse} from "contracts/fuses/aave_v3/AaveV3WithPriceOracleMiddlewareBalanceFuse.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {ERC20Mock} from "test/fuses/aave_v4/ERC20Mock.sol";
import {IPoolAddressesProvider} from "contracts/fuses/aave_v3/ext/IPoolAddressesProvider.sol";
import {IAavePoolDataProvider} from "contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
contract AaveV3WithPriceOracleMiddlewareBalanceFuseTest is OlympixUnitTest("AaveV3WithPriceOracleMiddlewareBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_ReturnsZeroWhenNoSubstrates() public {
        // Arrange
        uint256 marketId = 1;
    
        // Mock Aave pool addresses provider (non-zero to pass constructor check)
        IPoolAddressesProvider poolAddressesProvider = IPoolAddressesProvider(address(0x1234));
    
        // Mock price oracle middleware with non-zero QUOTE_CURRENCY_DECIMALS
        PriceOracleMiddlewareMock oracle = new PriceOracleMiddlewareMock(address(0), 18, address(0));
    
        // Deploy a dummy ERC20 just to have a valid asset (won't be used since there are no substrates)
        ERC20Mock underlying = new ERC20Mock("Mock", "MOCK", 18);
    
        // Deploy the fuse
        AaveV3WithPriceOracleMiddlewareBalanceFuse fuse = new AaveV3WithPriceOracleMiddlewareBalanceFuse(
            marketId,
            address(poolAddressesProvider)
        );
    
        // Set PlasmaVaultLib price oracle middleware storage to our mock via the helper test contract context.
        // Olympix test harness deploys the target under test as address(this), so we can safely assume
        // PlasmaVaultLib.getPriceOracleMiddleware() will read whatever was configured during setup.
        // For the specific branch we target (len == 0) the oracle is not actually used, so we do not
        // need to perform low-level storage setup here.
    
        // Act
        uint256 balance = fuse.balanceOf();
    
        // Assert: when getMarketSubstrates(MARKET_ID) returns empty array, fuse must return 0
        assertEq(balance, 0, "Balance should be zero when there are no substrates configured");
    }
}