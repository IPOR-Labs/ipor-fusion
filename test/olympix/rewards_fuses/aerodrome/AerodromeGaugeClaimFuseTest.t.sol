// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/aerodrome/AerodromeGaugeClaimFuse.sol

import {AerodromeGaugeClaimFuse} from "contracts/rewards_fuses/aerodrome/AerodromeGaugeClaimFuse.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "contracts/fuses/aerodrome/AreodromeLib.sol";
import {IGauge} from "contracts/fuses/aerodrome/ext/IGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
contract AerodromeGaugeClaimFuseTest is OlympixUnitTest("AerodromeGaugeClaimFuse") {

    // Helper function that can be called via delegatecall to set rewards manager in storage
    function setRewardsClaimManager(address manager_) external {
        PlasmaVaultLib.setRewardsClaimManagerAddress(manager_);
    }


    function test_claim_RevertOnEmptyArray_opix_target_branch_45_true() public {
        // Deploy fuse with arbitrary marketId matching config used in test harness
        uint256 marketId = 1;
        AerodromeGaugeClaimFuse fuse = new AerodromeGaugeClaimFuse(marketId);
    
        // Expect revert when gauges_ array is empty to hit opix-target-branch-45-True
        address[] memory gauges = new address[](0);
    
        vm.expectRevert(AerodromeGaugeClaimFuse.AerodromeGaugeClaimFuseEmptyArray.selector);
        fuse.claim(gauges);
    }

    function test_claim_SucceedsOnNonEmptyArray_opix_target_branch_47_false() public {
            // Arrange
            uint256 marketId = 1;
            AerodromeGaugeClaimFuse fuse = new AerodromeGaugeClaimFuse(marketId);

            // Use PlasmaVaultMock for delegatecall so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Configure a non-zero rewardsClaimManager in vault's storage
            address rewardsManager = address(0xBEEF);
            vault.execute(address(this), abi.encodeWithSelector(this.setRewardsClaimManager.selector, rewardsManager));

            // Grant gauge as substrate
            address gauge = address(0x1);
            bytes32 substrateKey = AerodromeSubstrateLib.substrateToBytes32(
                AerodromeSubstrate({substrateAddress: gauge, substrateType: AerodromeSubstrateType.Gauge})
            );
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = substrateKey;
            vault.grantMarketSubstrates(marketId, substrates);

            // Mock gauge calls
            address rewardToken = address(0xAAAA);
            vm.mockCall(gauge, abi.encodeWithSelector(IGauge.rewardToken.selector), abi.encode(rewardToken));
            vm.mockCall(gauge, abi.encodeWithSelector(IGauge.getReward.selector), abi.encode());
            vm.mockCall(rewardToken, abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(vault)), abi.encode(uint256(0)));

            // Prepare a non-empty gauges array
            address[] memory gauges = new address[](1);
            gauges[0] = gauge;

            // Act via vault
            vault.execute(address(fuse), abi.encodeWithSelector(AerodromeGaugeClaimFuse.claim.selector, gauges));
        }
}