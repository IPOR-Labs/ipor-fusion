// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/curve_gauge/CurveChildLiquidityGaugeErc4626BalanceFuse.sol

import {CurveChildLiquidityGaugeErc4626BalanceFuse} from "contracts/fuses/curve_gauge/CurveChildLiquidityGaugeErc4626BalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IChildLiquidityGauge} from "contracts/fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
contract CurveChildLiquidityGaugeErc4626BalanceFuseTest is OlympixUnitTest("CurveChildLiquidityGaugeErc4626BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_WhenNoSubstrates_ShouldReturnZero() public {
        // Deploy underlying ERC20 and ERC4626 vault (PlasmaVault mock) so that
        // CurveChildLiquidityGaugeErc4626BalanceFuse can read IERC4626(address(this)).asset()
        MockERC20 underlying = new MockERC20("Token", "TKN", 18);
        MockERC4626 vault = new MockERC4626(underlying, "Vault", "vTKN");
    
        // Set the vault as the current contract storage context by using vm.etch
        // so that address(this) inside the fuse (used as PlasmaVault address)
        // points to an ERC4626-compatible contract with the correct asset()
        bytes memory code = address(vault).code;
        vm.etch(address(this), code);
    
        // Configure PlasmaVaultLib price oracle to a mock
        PriceOracleMiddlewareMock oracle = new PriceOracleMiddlewareMock(address(0), 18, address(0));
        PlasmaVaultLib.setPriceOracleMiddleware(address(oracle));
    
        // Ensure MARKET_ID has no substrates so that getMarketSubstrates(MARKET_ID) returns empty array
        uint256 marketId = 1;
        PlasmaVaultStorageLib.MarketSubstratesStruct storage ms =
            PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
        delete ms.substrates;
    
        // Instantiate the fuse for that market
        CurveChildLiquidityGaugeErc4626BalanceFuse fuse = new CurveChildLiquidityGaugeErc4626BalanceFuse(marketId);
    
        // When: balanceOf is called and there are no substrates, we should hit
        // the `if (len == 0)` branch and immediately return 0
        uint256 balance = fuse.balanceOf();
    
        // Then
        assertEq(balance, 0, "Balance should be zero when there are no substrates");
    }
}