// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/whitelist/FuseWhitelist.sol

import {FuseWhitelist} from "contracts/fuses/whitelist/FuseWhitelist.sol";
import {FuseWhitelistLib} from "contracts/fuses/whitelist/FuseWhitelistLib.sol";
import {UniversalReader} from "contracts/universal_reader/UniversalReader.sol";
contract FuseWhitelistTest is OlympixUnitTest("FuseWhitelist") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_getFuseMetadataInfo_RevertsOnZeroAddress_HitsTrueBranch358() public {
        // Deploy implementation directly (no proxy / no initialize needed for this view)
        FuseWhitelist whitelist = new FuseWhitelist();
    
        // Expect the custom error FuseWhitelistInvalidInput when passing zero address
        vm.expectRevert(FuseWhitelist.FuseWhitelistInvalidInput.selector);
    
        // Call the target function with zero address to hit the `fuseAddress_ == address(0)` true branch
        whitelist.getFuseMetadataInfo(address(0));
    }

    function test_getFuseMetadataInfo_NoMetadataHitsTrueBranch368() public {
            // Deploy implementation (not via proxy) and use it directly.
            // initialize() is protected with `initializer` and the constructor of
            // FuseWhitelistAccessControl already called _disableInitializers(),
            // so calling initialize() will revert with InvalidInitialization.
            // To avoid that, we intentionally DO NOT call initialize() here.
    
            FuseWhitelist whitelist = new FuseWhitelist();
    
            // We only need to hit the branch where `length == 0` in getFuseMetadataInfo.
            // That branch is taken when the fuse exists but has no metadata.
            // FuseWhitelistLib.getFuseByAddress reads from a storage slot that is
            // empty in this fresh contract, so fuseInfo.metadataIds.length == 0.
            // We must also avoid the revert on zero address, so use a non‑zero fuse.
    
            address fuse = address(0x1234);
    
            (uint256[] memory metadataIds, bytes32[][] memory metadata) = whitelist.getFuseMetadataInfo(fuse);
    
            // Expect the "length == 0" branch: both arrays should be empty
            assertEq(metadataIds.length, 0, "metadataIds should be empty when fuse has no metadata");
            assertEq(metadata.length, 0, "metadata array should be empty when fuse has no metadata");
        }
}