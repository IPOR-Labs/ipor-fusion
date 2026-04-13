// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/async_action/AsyncActionBalanceFuse.sol

import {AsyncActionBalanceFuse} from "contracts/fuses/async_action/AsyncActionBalanceFuse.sol";
import {AsyncActionFuseLib} from "contracts/fuses/async_action/AsyncActionFuseLib.sol";
import {AsyncExecutor} from "contracts/fuses/async_action/AsyncExecutor.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
contract AsyncActionBalanceFuseTest is OlympixUnitTest("AsyncActionBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_returnsZeroWhenExecutorNotSet_opix_target_branch_43_true() public {
            // Deploy underlying token and ERC4626 vault
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            MockERC4626 vault = new MockERC4626(underlying, "Vault", "vTKN");
    
            // Deploy AsyncActionBalanceFuse with arbitrary marketId
            AsyncActionBalanceFuse fuse = new AsyncActionBalanceFuse(1);
    
            // Make the fuse think the caller is the vault by using prank
            vm.startPrank(address(vault));
            uint256 balanceUsd = fuse.balanceOf();
            vm.stopPrank();
    
            // Since AsyncActionFuseLib.getAsyncExecutor() returns address(0) by default,
            // the first if(executor == address(0)) branch is taken and function returns 0
            assertEq(balanceUsd, 0, "balanceUsd should be zero when executor is not set");
        }
}