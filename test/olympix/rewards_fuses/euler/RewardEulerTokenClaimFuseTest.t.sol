// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";

/// @dev Target contract: contracts/rewards_fuses/euler/RewardEulerTokenClaimFuse.sol

import {RewardEulerTokenClaimFuse, ClaimData} from "contracts/rewards_fuses/euler/RewardEulerTokenClaimFuse.sol";

import {IREUL} from "contracts/rewards_fuses/euler/ext/IREUL.sol";
contract RewardEulerTokenClaimFuseTest is OlympixUnitTest("RewardEulerTokenClaimFuse") {
    RewardEulerTokenClaimFuse public rewardEulerTokenClaimFuse;
    MockERC20 public rEUL;
    MockERC20 public EUL;

    function setUp() public override {
        rEUL = new MockERC20("rEUL", "rEUL", 18);
        EUL = new MockERC20("EUL", "EUL", 18);
        rewardEulerTokenClaimFuse = new RewardEulerTokenClaimFuse(address(rEUL), address(EUL));
    }

    function test_example_deployment_doesNotRevert() public view {
        assertTrue(address(rewardEulerTokenClaimFuse) != address(0));
    }

    function test_example_rEULImmutable() public view {
        assertEq(rewardEulerTokenClaimFuse.rEUL(), address(rEUL));
    }

    function test_example_EULImmutable() public view {
        assertEq(rewardEulerTokenClaimFuse.EUL(), address(EUL));
    }

    function test_example_revertsOnZeroREUL() public {
        vm.expectRevert(RewardEulerTokenClaimFuse.RewardEulerTokenClaimFuseInvalidAddress.selector);
        new RewardEulerTokenClaimFuse(address(0), address(EUL));
    }

    function test_example_revertsOnZeroEUL() public {
        vm.expectRevert(RewardEulerTokenClaimFuse.RewardEulerTokenClaimFuseInvalidAddress.selector);
        new RewardEulerTokenClaimFuse(address(rEUL), address(0));
    }

    function test_example_claimRevertsWhenRewardsManagerNotSet() public {
        // PlasmaVaultLib reads storage from caller (the fuse); default-zero address triggers revert.
        ClaimData memory data = ClaimData({lockTimestamps: new uint256[](0), allowRemainderLoss: false});
        vm.expectRevert(RewardEulerTokenClaimFuse.RewardEulerTokenClaimFuseRewardsClaimManagerNotSet.selector);
        rewardEulerTokenClaimFuse.claim(data);
    }

    function test_example_claimSucceedsWithMockedManager() public {
        // Set the rewards claim manager address in fuse storage via the namespaced slot
        bytes32 slot = 0x08c469289c3f85d9b575f3ae9be6831541ff770a06ea135aa343a4de7c962d00;
        address mgr = address(0xCAFE);
        vm.store(address(rewardEulerTokenClaimFuse), slot, bytes32(uint256(uint160(mgr))));

        // Mock IREUL.withdrawToByLockTimestamps (declared `returns (bool)`, so the mock must
        // return abi-encoded data — empty returndata makes the typed call's decoder revert)
        vm.mockCall(
            address(rEUL),
            abi.encodeWithSignature("withdrawToByLockTimestamps(address,uint256[],bool)"),
            abi.encode(true)
        );

        // EUL balance before = 0, after = 100 (simulated reward)
        vm.mockCall(address(EUL), abi.encodeWithSignature("balanceOf(address)", mgr), abi.encode(uint256(0)));
        // Need second mock to return new value after the withdraw call — sequence not directly mockable;
        // instead mint to mgr directly so real balanceOf returns 100 after the no-op withdraw mock.
        vm.clearMockedCalls();
        vm.mockCall(
            address(rEUL),
            abi.encodeWithSignature("withdrawToByLockTimestamps(address,uint256[],bool)"),
            abi.encode(true)
        );
        EUL.mint(mgr, 100);

        ClaimData memory data = ClaimData({lockTimestamps: new uint256[](1), allowRemainderLoss: false});
        data.lockTimestamps[0] = 1000;
        // Pre balance is 100 (we minted), post is also 100 (mock withdraw is no-op) → not a revert
        // because eulerRewardsManagerBalanceBefore == eulerRewardsManagerBalanceAfter (not >)
        rewardEulerTokenClaimFuse.claim(data);
    }

    function test_claim_DoesNotRevertWhenBalanceAfterNotLower() public {
            // arrange rewardsClaimManager in PlasmaVaultLib storage (namespaced slot)
            bytes32 slot = 0x08c469289c3f85d9b575f3ae9be6831541ff770a06ea135aa343a4de7c962d00;
            address rewardsManager = address(0xBEEF);
            vm.store(address(rewardEulerTokenClaimFuse), slot, bytes32(uint256(uint160(rewardsManager))));
    
            // mock rEUL withdraw call so it succeeds without changing state
            uint256[] memory locks = new uint256[](1);
            locks[0] = 123;
            ClaimData memory data = ClaimData({lockTimestamps: locks, allowRemainderLoss: false});
    
            vm.mockCall(
                address(rEUL),
                abi.encodeWithSelector(IREUL.withdrawToByLockTimestamps.selector, rewardsManager, locks, false),
                abi.encode(true)
            );
    
            // give rewards manager some initial EUL balance and keep it unchanged so
            // eulerRewardsManagerBalanceBefore == eulerRewardsManagerBalanceAfter,
            // making the `if (before > after)` condition false and entering the else branch
            EUL.mint(rewardsManager, 100 ether);
    
            // act - should not revert and should take the `else` branch in the balance check
            rewardEulerTokenClaimFuse.claim(data);
        }
}