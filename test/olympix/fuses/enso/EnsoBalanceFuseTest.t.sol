// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/enso/EnsoBalanceFuse.sol

import {EnsoBalanceFuse} from "contracts/fuses/enso/EnsoBalanceFuse.sol";
import {EnsoStorageLib} from "contracts/fuses/enso/lib/EnsoStorageLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IEnsoExecutor} from "contracts/fuses/enso/interfaces/IEnsoExecutor.sol";
contract EnsoBalanceFuseTest is OlympixUnitTest("EnsoBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_ExecutorNotSet_ReturnsZero() public {
            // Deploy fuse with arbitrary market id
            EnsoBalanceFuse fuse = new EnsoBalanceFuse(1);
    
            // Ensure Enso executor storage is zero so the first `if (executorAddress == address(0))` is true
            // This hits opix-target-branch-31-True
            address executor = EnsoStorageLib.getEnsoExecutor();
            assertEq(executor, address(0), "executor should be zero by default");
    
            // When: calling balanceOf
            uint256 balance = fuse.balanceOf();
    
            // Then: should return 0
            assertEq(balance, 0, "balanceOf should return 0 when executor is not set");
        }
}