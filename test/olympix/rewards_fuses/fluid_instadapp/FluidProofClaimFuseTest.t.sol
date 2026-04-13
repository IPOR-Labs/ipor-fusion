// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/fluid_instadapp/FluidProofClaimFuse.sol

import {FluidProofClaimFuse} from "contracts/rewards_fuses/fluid_instadapp/FluidProofClaimFuse.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
contract FluidProofClaimFuseTest is OlympixUnitTest("FluidProofClaimFuse") {


    function test_claim_RevertWhenRewardsClaimManagerZeroAddress() public {
            // Arrange: set rewardsClaimManager to zero address
            PlasmaVaultLib.setRewardsClaimManagerAddress(address(0));
    
            FluidProofClaimFuse fuse = new FluidProofClaimFuse(1);
    
            // Expect revert on first branch: rewardsClaimManager == address(0)
            vm.expectRevert(abi.encodeWithSelector(FluidProofClaimFuse.FluidProofClaimFuseRewardsClaimManagerZeroAddress.selector, address(fuse)));

            fuse.claim({
                distributor_: address(0x1),
                cumulativeAmount_: 0,
                positionType_: 0,
                positionId_: bytes32(0),
                cycle_: 0,
                merkleProof_: new bytes32[](0),
                metadata_: ""
            });
        }
}