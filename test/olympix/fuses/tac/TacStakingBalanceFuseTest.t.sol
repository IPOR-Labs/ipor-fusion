// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {TacStakingBalanceFuse} from "../../../../contracts/fuses/tac/TacStakingBalanceFuse.sol";

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {TacStakingStorageLib} from "contracts/fuses/tac/lib/TacStakingStorageLib.sol";
import {MockStaking, Coin, UnbondingDelegationOutput} from "test/fuses/tac/MockStaking.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";
contract TacStakingBalanceFuseTest is OlympixUnitTest("TacStakingBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_NoSubstrates_ReturnsZero() public {
            // set up minimal environment
            uint256 marketId = 1;
            address wTac = address(0x1001);
            address stakingAddr = address(new MockStaking(vm));
            TacStakingBalanceFuse fuse = new TacStakingBalanceFuse(marketId, wTac, stakingAddr);
    
            // ensure no substrates for this market
            bytes32[] memory emptySubs = new bytes32[](0);
            PlasmaVaultConfigLib.grantMarketSubstrates(marketId, emptySubs);
    
            // price oracle must be non‑zero to avoid revert on that branch
            address oracle = address(new MockPriceOracle());
            PlasmaVaultLib.setPriceOracleMiddleware(oracle);
    
            // tacStakingDelegator must be non‑zero so we do NOT take the early-return path there
            TacStakingStorageLib.setTacStakingDelegator(address(0xDEAD));
    
            // act & assert: since substrates length == 0, function should short‑circuit to 0
            uint256 balanceInUSD = fuse.balanceOf();
            assertEq(balanceInUSD, 0, "Balance should be zero when no substrates are configured");
        }
}