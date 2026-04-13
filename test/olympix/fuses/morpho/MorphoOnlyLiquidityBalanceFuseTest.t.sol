// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/morpho/MorphoOnlyLiquidityBalanceFuse.sol

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MorphoOnlyLiquidityBalanceFuse} from "contracts/fuses/morpho/MorphoOnlyLiquidityBalanceFuse.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
contract MorphoOnlyLiquidityBalanceFuseTest is OlympixUnitTest("MorphoOnlyLiquidityBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_NoSubstratesReturnsZero() public {
            // setUp(): deploy a minimal environment around the fuse running via delegatecall
            // 1) Deploy mocks
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            IMorpho morpho = IMorpho(address(0x1234)); // dummy, not touched when no substrates
    
            // Price oracle mock that always returns 0 so it will also be safe if ever queried
            PriceOracleMiddlewareMock oracle = new PriceOracleMiddlewareMock(address(0), 18, address(0));
    
            // 2) Configure PlasmaVaultLib storage in the context of this test contract
            PlasmaVaultLib.setPriceOracleMiddleware(address(oracle));
    
            // 3) Ensure there are NO substrates configured for this MARKET_ID
            uint256 marketId = 1;
            PlasmaVaultStorageLib.MarketSubstratesStruct storage ms =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            // Clear any possible leftovers
            uint256 len = ms.substrates.length;
            for (uint256 i; i < len; ++i) {
                ms.substrateAllowances[ms.substrates[i]] = 0;
            }
            delete ms.substrates;
    
            // 4) Deploy the fuse which will be delegatecalled from this contract
            MorphoOnlyLiquidityBalanceFuse fuse = new MorphoOnlyLiquidityBalanceFuse(marketId, address(morpho));
    
            // 5) Delegatecall balanceOf() so that `address(this)` is treated as the PlasmaVault
            (bool ok, bytes memory data) = address(fuse).delegatecall(abi.encodeWithSignature("balanceOf()"));
            assertTrue(ok, "delegatecall to balanceOf should succeed");
            uint256 balance = abi.decode(data, (uint256));
    
            // Expect branch: len == 0 -> return 0
            assertEq(balance, 0, "Balance should be zero when no substrates are configured");
        }
}