// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/fluid_instadapp/FluidInstadappClaimFuse.sol

import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {FluidInstadappClaimFuse} from "contracts/rewards_fuses/fluid_instadapp/FluidInstadappClaimFuse.sol";
contract FluidInstadappClaimFuseTest is OlympixUnitTest("FluidInstadappClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_NoSubstrates_ReturnsEarly() public {
            // Deploy fuse with arbitrary marketId; in this isolated test context
            // PlasmaVaultConfigLib.getMarketSubstrates(marketId) will return an empty array
            // so len == 0 and the function should hit the early-return branch
            uint256 marketId = 1;
            FluidInstadappClaimFuse fuse = new FluidInstadappClaimFuse(marketId);
    
            // Just ensure the call does not revert; reaching here means the len == 0 branch was taken
            fuse.claim();
        }
}