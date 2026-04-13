// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/midas/MidasBalanceFuse.sol

import {MidasBalanceFuse} from "contracts/fuses/midas/MidasBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
contract MidasBalanceFuseTest is OlympixUnitTest("MidasBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_NoSubstratesReturnsZeroAndConstructorRevertsOnZeroMarketId() public {
            // constructor branch: marketId_ == 0 should revert with Errors.WrongValue
            vm.expectRevert(Errors.WrongValue.selector);
            new MidasBalanceFuse(0);
    
            // arrange: create a fuse with a valid market id
            uint256 marketId = 1;
            MidasBalanceFuse fuse = new MidasBalanceFuse(marketId);
    
            // ensure there are no substrates configured for this market
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            // clear any existing substrates
            uint256 len = marketSubstrates.substrates.length;
            for (uint256 i; i < len; ++i) {
                marketSubstrates.substrateAllowances[marketSubstrates.substrates[i]] = 0;
            }
            delete marketSubstrates.substrates;
    
            // act: call balanceOf, should take the opix-target-branch-49-True path and return 0
            uint256 balance = fuse.balanceOf();
    
            // assert
            assertEq(balance, 0, "Balance should be zero when there are no substrates configured");
        }
}