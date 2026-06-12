// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RWAForkTestBase, MockRWAProtocolForFork} from "./RWAForkTestBase.t.sol";
import {IRWAExecutor, RWAExecutorAction} from "../../../contracts/fuses/rwa/IRWAExecutor.sol";

/// @title RWAFuseForkTest
/// @notice End-to-end fork scenarios covering enter / execute / exit paths of the RWA fuse
///         family against a forked mainnet, real USDC, and the shared RWA fork fixture.
contract RWAFuseForkTest is RWAForkTestBase {
    /// @notice Happy-path deposit + alpha action + full exit. Verifies the executor receives the
    ///         tokens, emits the `deposit` action, and returns them to the vault on exit.
    function test_fork_enter_action_exit_happy() public {
        // Seed the vault with USDC — this simulates a user having deposited into the PlasmaVault.
        deal(USDC, address(vault), 1_000e6);

        // Build an action invoking the RWA target's `deposit(address,uint256)` selector. The
        // target substrate is bound to this exact selector in the default substrate grant set.
        RWAExecutorAction[] memory actions = new RWAExecutorAction[](1);
        actions[0] = RWAExecutorAction({
            target: address(rwaProtocol), data: abi.encodeCall(MockRWAProtocolForFork.deposit, (USDC, 1_000e6))
        });

        _enter(USDC, 1_000e6, balanceAccountA, actions);
        address executor = _executorAddress();
        assertTrue(executor != address(0), "executor deployed");

        // Tokens moved vault -> executor, and the mock protocol recorded the deposit.
        assertEq(IERC20(USDC).balanceOf(executor), 1_000e6, "executor holds USDC");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault drained");
        assertEq(rwaProtocol.totalDeposits(), 1_000e6, "protocol recorded deposit");

        // Tracked balance equals underlying amount at 1:1 USDC-USD
        (uint256 tracked,,) = IRWAExecutor(executor).getBalanceFuseSnapshot();
        assertEq(tracked, 1_000e6, "tracked balance correct");

        // Exit the full amount back to vault (no actions — just transfer-back)
        _exit(USDC, 1_000e6, balanceAccountA);

        (uint256 trackedAfter,,) = IRWAExecutor(executor).getBalanceFuseSnapshot();
        assertEq(trackedAfter, 0, "tracked balance cleared");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 1_000e6, "vault received funds back");
        assertEq(IERC20(USDC).balanceOf(executor), 0, "executor empty");
    }

    /// @notice Two-phase enter: first a pure transfer, then a separate action-only enter — the
    ///         composition must credit the balance account exactly once for the transfer.
    function test_fork_enter_transferOnly_thenSeparateExecuteCall() public {
        deal(USDC, address(vault), 500e6);

        // Phase 1: transfer only (no actions). Balance credited, executor deployed lazily.
        _enter(USDC, 500e6, balanceAccountA);
        address executor = _executorAddress();
        (uint256 tracked1,,) = IRWAExecutor(executor).getBalanceFuseSnapshot();
        assertEq(tracked1, 500e6, "tracked credited once");

        // Phase 2: actions-only (amount == 0). Tracked balance must NOT change.
        RWAExecutorAction[] memory actions = new RWAExecutorAction[](1);
        actions[0] = RWAExecutorAction({
            target: address(rwaProtocol), data: abi.encodeCall(MockRWAProtocolForFork.deposit, (USDC, 500e6))
        });
        _enter(address(0), 0, address(0), actions);

        (uint256 tracked2,,) = IRWAExecutor(executor).getBalanceFuseSnapshot();
        assertEq(tracked2, 500e6, "balance unchanged by actions-only enter");
        assertEq(rwaProtocol.totalDeposits(), 500e6, "protocol recorded the action");
    }

    /// @notice Explicit createExecutor before first enter — the executor address must match on
    ///         the subsequent enter (no re-deploy).
    function test_fork_createExecutorBeforeFirstEnter() public {
        address executor1 = _createExecutor();

        deal(USDC, address(vault), 200e6);
        _enter(USDC, 200e6, balanceAccountA);

        address executor2 = _executorAddress();
        assertEq(executor1, executor2, "executor address stable across explicit + lazy deploy");
    }

    /// @notice A confirmed custodian balance update must show up in the balance fuse the next
    ///         time it is called, provided the delta stays below `BIG_CHANGE_BPS` (no pause).
    function test_fork_balanceFuseReflectsBalanceAfterCustodianUpdate() public {
        deal(USDC, address(vault), 1_000e6);
        _enter(USDC, 1_000e6, balanceAccountA);

        // Baseline fuse read — stores lastTotalBalance = 1_000e6 and lastCheckedCustodianTs.
        uint256 value0 = _readBalanceOf();
        // USDC (6d) at $1 → 1_000e18 USD WAD.
        assertEq(value0, 1_000e18, "baseline WAD value");

        // Custodian updates to 1_050e6 (+5%, below 10% threshold).
        _custodianConfirm(balanceAccountA, 1_050e6);

        uint256 value1 = _readBalanceOf();
        assertEq(value1, 1_050e18, "post-update WAD value reflects custodian write");
        assertFalse(_readPaused(), "below threshold, not paused");
    }

    /// @notice Balance fuse returns USD WAD consistent with the configured oracle. We explicitly
    ///         bump USDC to $1.01 to verify the fuse uses the oracle and not a hard 1:1 constant.
    function test_fork_balanceFuseReturnsUsdWad_consistentWithOracle() public {
        oracle.setPrice(USDC, 101e6, 8); // $1.01 in 8-decimal quote
        deal(USDC, address(vault), 100e6); // 100 USDC

        _enter(USDC, 100e6, balanceAccountA);

        uint256 value = _readBalanceOf();
        // 100 underlying USDC at $1.01 → 101e18 USD WAD.
        assertEq(value, 101e18, "USD WAD tracks oracle price");
    }
}
