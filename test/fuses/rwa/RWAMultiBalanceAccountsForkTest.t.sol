// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RWAForkTestBase} from "./RWAForkTestBase.t.sol";
import {IRWAExecutor} from "../../../contracts/fuses/rwa/IRWAExecutor.sol";
import {RWAExecutor} from "../../../contracts/fuses/rwa/RWAExecutor.sol";

/// @title RWAMultiBalanceAccountsForkTest
/// @notice Fork coverage for multi-balance-account accounting: two balance accounts are updated
///         independently and the aggregate on the balance fuse equals their sum. Also verifies
///         enter/exit targets the specific account passed in `balanceAccount`.
contract RWAMultiBalanceAccountsForkTest is RWAForkTestBase {
    function test_fork_multipleBalanceAccounts_independentUpdates() public {
        _createExecutor();

        _custodianConfirm(balanceAccountA, 100e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S + 1);
        _custodianConfirm(balanceAccountB, 250e6);

        address executor = _executorAddress();
        assertEq(RWAExecutor(executor).balances(balanceAccountA), 100e6, "account A balance");
        assertEq(RWAExecutor(executor).balances(balanceAccountB), 250e6, "account B balance");

        // A subsequent update to A must not touch B.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S + 1);
        _custodianConfirm(balanceAccountA, 150e6);
        assertEq(RWAExecutor(executor).balances(balanceAccountA), 150e6, "A updated independently");
        assertEq(RWAExecutor(executor).balances(balanceAccountB), 250e6, "B unchanged");
    }

    function test_fork_multipleBalanceAccounts_sumIsTotalBalance() public {
        _createExecutor();

        _custodianConfirm(balanceAccountA, 100e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S + 1);
        _custodianConfirm(balanceAccountB, 300e6);

        (uint256 total,,) = IRWAExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 400e6, "sum across balance accounts");

        // USD WAD: 400 underlying USDC @ $1 -> 400e18.
        assertEq(_readBalanceOf(), 400e18, "balance fuse matches aggregate");
    }

    function test_fork_multipleBalanceAccounts_addBalanceTargetsCorrectAccount() public {
        deal(USDC, address(vault), 1_000e6);

        _enter(USDC, 400e6, balanceAccountA);
        _enter(USDC, 600e6, balanceAccountB);

        address executor = _executorAddress();
        assertEq(RWAExecutor(executor).balances(balanceAccountA), 400e6, "A credited");
        assertEq(RWAExecutor(executor).balances(balanceAccountB), 600e6, "B credited");
    }

    function test_fork_multipleBalanceAccounts_removeBalanceTargetsCorrectAccount() public {
        deal(USDC, address(vault), 1_000e6);

        _enter(USDC, 400e6, balanceAccountA);
        _enter(USDC, 600e6, balanceAccountB);

        // Exit partially from B only.
        _exit(USDC, 100e6, balanceAccountB);

        address executor = _executorAddress();
        assertEq(RWAExecutor(executor).balances(balanceAccountA), 400e6, "A untouched");
        assertEq(RWAExecutor(executor).balances(balanceAccountB), 500e6, "B decremented by 100e6");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 100e6, "vault received exit");
    }
}
