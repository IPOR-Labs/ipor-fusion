// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {PlasmaVaultMarketsLibCaller} from "test/test_helpers/lib_callers/PlasmaVaultMarketsLibCaller.sol";

/// @dev Target: PlasmaVaultMarketsLibCaller (library PlasmaVaultMarketsLib wrapped for Olympix targeting).

contract PlasmaVaultMarketsLibTest is OlympixUnitTest("PlasmaVaultMarketsLibCaller") {
    PlasmaVaultMarketsLibCaller internal caller;

    function setUp() public override {
        caller = new PlasmaVaultMarketsLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_withdrawFromMarkets_simpleCall() public {
            address asset = address(0x1234);
            // the library computes `left = assets_ - vaultCurrentBalanceUnderlying_`, so the
            // requested amount must be >= the vault's current balance or the call underflows
            uint256 amount = 1000;
            uint256 vaultCurrentBalance = 100;

            // Just call the function to hit the branch guarded by `if (true)`
            uint256[] memory result = caller.withdrawFromMarkets(asset, amount, vaultCurrentBalance);

            // Basic sanity check on returned array (library internals are tested elsewhere):
            // no instant-withdrawal fuses are configured in the caller's storage, so the
            // withdrawal loop is skipped and the returned markets array is empty
            assertEq(result.length, 0);
        }
    
}