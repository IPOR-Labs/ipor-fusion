// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/tac/TacStakingRedelegateFuse.sol

import {TacStakingRedelegateFuse, TacStakingRedelegateFuseEnterData} from "contracts/fuses/tac/TacStakingRedelegateFuse.sol";
import {TacStakingStorageLib} from "contracts/fuses/tac/lib/TacStakingStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {TacStakingDelegator} from "contracts/fuses/tac/TacStakingDelegator.sol";
import {MockStaking} from "test/fuses/tac/MockStaking.sol";
contract TacStakingRedelegateFuseTest is OlympixUnitTest("TacStakingRedelegateFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_ZeroValidatorsHitsEarlyReturnBranch() public {
            // Deploy fuse with some marketId
            TacStakingRedelegateFuse fuse = new TacStakingRedelegateFuse(1);
    
            // Prepare data with zero-length validatorSrcAddresses to hit
            // the `if (validatorSrcAddressesLength == 0) { return; }` branch
            TacStakingRedelegateFuseEnterData memory data_;
            data_.validatorSrcAddresses = new string[](0);
            data_.validatorDstAddresses = new string[](0);
            data_.wTacAmounts = new uint256[](0);
    
            // Call should simply return without reverting and thus
            // cover opix-target-branch-47-True
            fuse.enter(data_);
        }

    function test_enter_NonEmptyValidatorsHitsElseBranchAndRevertsOnInvalidDelegator() public {
            // Arrange: deploy fuse with some marketId
            TacStakingRedelegateFuse fuse = new TacStakingRedelegateFuse(1);
    
            // Prepare data with non‑empty validator arrays so
            // `validatorSrcAddressesLength == 0` is false and
            // the corresponding else branch is taken (opix-target-branch-49-False / else)
            string[] memory src = new string[](1);
            string[] memory dst = new string[](1);
            uint256[] memory amounts = new uint256[](1);
    
            src[0] = "validator-src";
            dst[0] = "validator-dst";
            amounts[0] = 1e18;
    
            TacStakingRedelegateFuseEnterData memory data_ = TacStakingRedelegateFuseEnterData({
                validatorSrcAddresses: src,
                validatorDstAddresses: dst,
                wTacAmounts: amounts
            });
    
            // We do NOT set TacStakingStorageLib delegator address,
            // so getTacStakingDelegator() returns address(0) and
            // the fuse must revert with TacStakingRedelegateFuseInvalidDelegatorAddress.
            vm.expectRevert(TacStakingRedelegateFuse.TacStakingRedelegateFuseInvalidDelegatorAddress.selector);
    
            // Act
            fuse.enter(data_);
        }
}