// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/moonwell/MoonwellClaimFuse.sol

import {MoonwellClaimFuse, MoonwellClaimFuseData} from "contracts/rewards_fuses/moonwell/MoonwellClaimFuse.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
import {MoonwellClaimFuse} from "contracts/rewards_fuses/moonwell/MoonwellClaimFuse.sol";
import {MComptroller} from "contracts/fuses/moonwell/ext/MComptroller.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
contract MoonwellClaimFuseTest is OlympixUnitTest("MoonwellClaimFuse") {


    function test_claim_RevertWhenEmptyArray() public {
            // Create a dummy comptroller implementation address so that call
            // goes into a valid contract and reverts from our target logic,
            // not with "call to non-contract".
            MComptroller comptroller = MComptroller(address(0x1));
    
            // Deploy the fuse with any marketId and the dummy comptroller
            MoonwellClaimFuse fuse = new MoonwellClaimFuse(1, address(comptroller));
    
            // Prepare empty data_.mTokens array => len == 0
            MoonwellClaimFuseData memory data_;
    
            // Expect the specific custom error from MoonwellClaimFuse when len == 0
            vm.expectRevert(MoonwellClaimFuse.MoonwellClaimFuseEmptyArray.selector);
            fuse.claim(data_);
        }

    function test_claim_NonEmptyArrayHitsElseBranchAndRewardDistributorZero() public {
            // Deploy a dummy comptroller at a non-zero address
            MComptroller comptroller = MComptroller(address(0x1));

            // Deploy the fuse with arbitrary marketId and dummy comptroller
            MoonwellClaimFuse fuse = new MoonwellClaimFuse(1, address(comptroller));

            // Prepare data with a non-empty mTokens array so len != 0
            address[] memory mTokens = new address[](1);
            mTokens[0] = address(0x1234);
            MoonwellClaimFuseData memory data_ = MoonwellClaimFuseData({mTokens: mTokens});

            // Mock COMPTROLLER.rewardDistributor() to return address(0) so the check triggers
            vm.mockCall(
                address(comptroller),
                abi.encodeWithSelector(MComptroller.rewardDistributor.selector),
                abi.encode(address(0))
            );

            vm.expectRevert(MoonwellClaimFuse.MoonwellClaimFuseRewardDistributorZeroAddress.selector);
            fuse.claim(data_);
        }

    function test_claim_RewardDistributorZeroAddress_branchTrue() public {
            // Arrange: deploy dummy comptroller and fuse
            MComptroller comptroller = MComptroller(address(0x1));
            MoonwellClaimFuse fuse = new MoonwellClaimFuse(1, address(comptroller));
    
            // Prepare non-empty mTokens array so first `if (len == 0)` is false (else branch taken)
            address[] memory mTokens = new address[](1);
            mTokens[0] = address(0x1234);
            MoonwellClaimFuseData memory data_ = MoonwellClaimFuseData({mTokens: mTokens});
    
            // Ensure rewardDistributor() returns zero so that
            // `if (rewardDistributor == address(0))` condition is true
            // and the opix-target-branch-59 True branch is taken.
            vm.mockCall(
                address(comptroller),
                abi.encodeWithSelector(MComptroller.rewardDistributor.selector),
                abi.encode(address(0))
            );
    
            vm.expectRevert(MoonwellClaimFuse.MoonwellClaimFuseRewardDistributorZeroAddress.selector);
            fuse.claim(data_);
        }

    function test_claim_RevertWhenRewardsClaimManagerZeroAddress_branchTrue() public {
            // Arrange: deploy dummy comptroller and fuse
            MComptroller comptroller = MComptroller(address(0x1));
            MoonwellClaimFuse fuse = new MoonwellClaimFuse(1, address(comptroller));
    
            // Prepare non–empty mTokens array so the first `if (len == 0)` is false (else branch taken)
            address[] memory mTokens = new address[](1);
            mTokens[0] = address(0x1234);
            MoonwellClaimFuseData memory data_ = MoonwellClaimFuseData({mTokens: mTokens});
    
            // Set up storage so that:
            // 1) COMPTROLLER.rewardDistributor() returns a non‑zero address
            //    -> we point it to `address(this)` which has a compatible rewardDistributor() view
            // 2) PlasmaVaultLib.getRewardsClaimManagerAddress() returns address(0)
            
            // 1) spoof rewardDistributor() via vm.mockCall so that the check
            //    `if (rewardDistributor == address(0))` is false and we reach the next branch
            vm.mockCall(
                address(comptroller),
                abi.encodeWithSelector(MComptroller.rewardDistributor.selector),
                abi.encode(address(this))
            );
    
            // 2) Ensure rewardsClaimManager is zero in storage (default), but we write explicitly
            PlasmaVaultStorageLib.RewardsClaimManagerAddress storage s = PlasmaVaultStorageLib.getRewardsClaimManagerAddress();
            s.value = address(0);
    
            // Assert: now the branch `if (rewardsClaimManager == address(0))` is true
            vm.expectRevert(MoonwellClaimFuse.MoonwellClaimFuseRewardsClaimManagerZeroAddress.selector);
            fuse.claim(data_);
        }
}