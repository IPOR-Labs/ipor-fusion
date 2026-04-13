// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/velodrome_superchain/VelodromeSuperchainGaugeClaimFuse.sol

import {VelodromeSuperchainGaugeClaimFuse} from "contracts/rewards_fuses/velodrome_superchain/VelodromeSuperchainGaugeClaimFuse.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {ILeafGauge} from "contracts/fuses/velodrome_superchain/ext/ILeafGauge.sol";
import {VelodromeSuperchainSubstrateLib, VelodromeSuperchainSubstrate, VelodromeSuperchainSubstrateType} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract VelodromeSuperchainGaugeClaimFuseTest is OlympixUnitTest("VelodromeSuperchainGaugeClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_RevertWhen_EmptyGaugesArray_hitsIfBranch() public {
            // Deploy fuse with arbitrary marketId
            VelodromeSuperchainGaugeClaimFuse fuse = new VelodromeSuperchainGaugeClaimFuse(1);
    
            // Expect revert for empty gauges array to hit `if (len == 0)` true branch
            vm.expectRevert(VelodromeSuperchainGaugeClaimFuse.VelodromeSuperchainGaugeClaimFuseEmptyArray.selector);
            address[] memory gauges = new address[](0);
            fuse.claim(gauges);
        }

    function test_claim_NonEmptyGaugesArray_hitsElseBranchOnLengthCheck() public {
            // Arrange
            uint256 marketId = 1;
            VelodromeSuperchainGaugeClaimFuse fuse = new VelodromeSuperchainGaugeClaimFuse(marketId);
    
            // Mock PlasmaVaultLib.getRewardsClaimManagerAddress to return non-zero
            address rewardsClaimManager = address(0xBEEF);
            vm.mockCall(
                address(PlasmaVaultLib),
                abi.encodeWithSignature("getRewardsClaimManagerAddress()"),
                abi.encode(rewardsClaimManager)
            );
    
            // Create non-empty gauges array so `len == 0` is false and the `else` branch is entered
            address[] memory gauges = new address[](1);
            gauges[0] = address(0xABCD);
    
            // We expect revert from unsupported gauge in _claim, but only after len>0 else-branch is hit
            vm.expectRevert();
            fuse.claim(gauges);
        }

    function test_claim_RevertWhen_RewardsManagerZeroAddress_hitsIfBranch() public {
            // Deploy fuse with arbitrary marketId
            VelodromeSuperchainGaugeClaimFuse fuse = new VelodromeSuperchainGaugeClaimFuse(1);
    
            // Prepare non-empty gauges array to reach rewardsClaimManager check
            address[] memory gauges = new address[](1);
            gauges[0] = address(0x1234);
    
            // rewardsClaimManager is zero by default, so this should revert
            vm.expectRevert(VelodromeSuperchainGaugeClaimFuse.VelodromeSuperchainGaugeClaimFuseRewardsClaimManagerZeroAddress.selector);
            fuse.claim(gauges);
        }
}