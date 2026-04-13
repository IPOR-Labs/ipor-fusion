// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/syrup/SyrupClaimFuse.sol

import {SyrupClaimFuse} from "contracts/rewards_fuses/syrup/SyrupClaimFuse.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {ISyrup} from "contracts/rewards_fuses/syrup/ext/ISyrup.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract SyrupClaimFuseTest is OlympixUnitTest("SyrupClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_RevertsWhenRewardsClaimManagerZeroAddress() public {
            // Deploy mock reward token
            MockERC20 rewardToken = new MockERC20("Reward", "RWD", 18);
    
            // Deploy a minimal mock Syrup contract via address cast using a simple contract that satisfies ISyrup
            // Here we create a very small inline Syrup-like contract via type(...) and then cast its address to ISyrup
            // but since we cannot declare it here, we instead just need a non-zero REWARD_DISTRIBUTOR; its behavior
            // is irrelevant for this revert-path test because the function reverts before any external call.
            address dummySyrup = address(0x1234);
    
            // Deploy SyrupClaimFuse with non-zero reward distributor
            SyrupClaimFuse fuse = new SyrupClaimFuse(dummySyrup);
    
            // Ensure RewardsClaimManager address is zero in PlasmaVaultStorageLib
            // getRewardsClaimManagerAddress().value defaults to zero, so no setup is required.
    
            // Expect revert with SyrupClaimFuseRewardsClaimManagerZeroAddress when calling claim
            vm.expectRevert(SyrupClaimFuse.SyrupClaimFuseRewardsClaimManagerZeroAddress.selector);
            fuse.claim(1, 100, new bytes32[](0));
        }
}