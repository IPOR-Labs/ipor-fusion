// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../../test/OlympixUnitTest.sol";
import {ExchangeRateValidatorPreHook} from "../../../../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorPreHook.sol";

import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {ExchangeRateValidatorConfigLib, ExchangeRateValidatorConfig, ValidatorData, HookType} from "contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";
contract ExchangeRateValidatorPreHookTest is OlympixUnitTest("ExchangeRateValidatorPreHook") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_run_NoSubstrates_EarlyReturn_DoesNotRevert() public {
            // given: ensure MARKET_ID storage has no substrates configured
            uint256 marketId = 1;
            ExchangeRateValidatorPreHook preHook = new ExchangeRateValidatorPreHook(marketId);
    
            // explicitly clear any existing substrates for this market
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultConfigLib.getMarketSubstratesStorage(marketId);
            delete marketSubstrates.substrates;
    
            // when / then: calling run should hit the `substrates.length == 0` branch and simply return
            preHook.run(bytes4(0x12345678));
        }
}