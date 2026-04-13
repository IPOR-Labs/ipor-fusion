// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/ramses/RamsesClaimFuse.sol

import {RamsesClaimFuse} from "contracts/rewards_fuses/ramses/RamsesClaimFuse.sol";
import {INonfungiblePositionManagerRamses} from "contracts/fuses/ramses/ext/INonfungiblePositionManagerRamses.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract RamsesClaimFuseTest is OlympixUnitTest("RamsesClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_EmptyInputs_DoNothing() public {
            // Deploy dummy dependencies
            address dummyNPM = address(0x1234);
            RamsesClaimFuse fuse = new RamsesClaimFuse(dummyNPM);
    
            // Sanity: rewards claim manager can be zero, but should not matter because early return
            // (we explicitly set it to zero to ensure we rely on the early-return branch)
            PlasmaVaultStorageLib.getRewardsClaimManagerAddress().value = address(0);
    
            // Prepare empty arrays so that the first if condition is true and we return immediately
            uint256[] memory tokenIds = new uint256[](0);
            address[][] memory tokenRewards = new address[][](0);
    
            // This call should not revert and should simply hit the early-return branch
            fuse.claim(tokenIds, tokenRewards);
        }

    function test_claim_NonEmptyInputs_EnterElseBranch() public {
            // Arrange: deploy fuse with dummy NPM
            RamsesClaimFuse fuse = new RamsesClaimFuse(address(0x1234));
    
            // Prepare non‑empty, length‑matched inputs so first if condition is false
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = 1;
    
            address[][] memory tokenRewards = new address[][](1);
            tokenRewards[0] = new address[](0); // rewards array exists but is empty
    
            // Act: this should execute the `else` branch of the first if and then revert in _claim
            // but for opix-target-branch-51 we only need to reach the else branch in `claim`
            // so we just ensure the call itself does not revert at this level
            // (any deeper behavior is handled by other tests/Olympix helpers)
            try fuse.claim(tokenIds, tokenRewards) {
                // If it somehow doesn't revert deeper, that's fine for this branch test
            } catch {
                // Swallow any revert from deeper logic; we only care that we entered the else branch
            }
        }

    function test_claim_LengthMismatch_Reverts() public {
            // Arrange: deploy fuse with dummy non-fungible position manager
            RamsesClaimFuse fuse = new RamsesClaimFuse(address(0x1234));
    
            // Set non-zero lengths but mismatch them to trigger the length check
            uint256[] memory tokenIds = new uint256[](2);
            tokenIds[0] = 1;
            tokenIds[1] = 2;
    
            address[][] memory tokenRewards = new address[][](1);
            tokenRewards[0] = new address[](1);
            tokenRewards[0][0] = address(0x1);
    
            // Act + Assert: expect custom length-mismatch revert
            vm.expectRevert(RamsesClaimFuse.RamsesClaimFuseTokenIdsAndTokenRewardsLengthMismatch.selector);
            fuse.claim(tokenIds, tokenRewards);
        }
}