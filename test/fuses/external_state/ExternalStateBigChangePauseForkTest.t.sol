// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExternalStateForkTestBase} from "./ExternalStateForkTestBase.t.sol";
import {ExternalStateUnpauseData} from "../../../contracts/fuses/external_state/ExternalStateUnpauseFuse.sol";
import {ExternalStateErrors} from "../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {IExternalStateExecutor} from "../../../contracts/fuses/external_state/IExternalStateExecutor.sol";

/// @title ExternalStateBigChangePauseForkTest
/// @notice Fork coverage for big-change detection, the pause flag, the pre-hook gate applied on
///         real user deposit/withdraw calls, and the atomist-signed unpause path.
///
///         The user-facing flow is exercised end-to-end: `ExternalStatePausePreHook` is registered on the
///         real `PlasmaVault` via `setPreHookImplementations` for the deposit / mint / withdraw /
///         redeem selectors, and the tests call those functions as a real user — exactly the
///         production wiring.
contract ExternalStateBigChangePauseForkTest is ExternalStateForkTestBase {
    /// @notice Big custodian update above `BIG_CHANGE_BPS` trips the pause flag on the next
    ///         balance fuse read.
    function test_fork_bigChangeTriggersPause() public {
        deal(USDC, address(vault), 1_000e6);
        _enter(USDC, 1_000e6, balanceAccountA);

        // Baseline fuse read — captures lastTotalBalance = 1_000e6, lastCheckedCustodianTs = 0.
        _readBalanceOf();
        assertFalse(_readPaused(), "baseline not paused");

        // Custodian confirms 2_000e6 (+100%, far above 10%)
        _custodianConfirm(balanceAccountA, 2_000e6);

        _readBalanceOf();
        assertTrue(_readPaused(), "big change tripped pause");
    }

    /// @notice An alpha-driven enter (even a large one) must not trigger big-change pause — the
    ///         detector only fires when a new custodian update is observed.
    function test_fork_bigChangeDoesNotTriggerOnAlphaEnter() public {
        deal(USDC, address(vault), 100e6);
        _enter(USDC, 100e6, balanceAccountA);
        _readBalanceOf(); // baseline 100e6
        assertFalse(_readPaused(), "pre-condition");

        // Alpha enters another 10_000e6 — a massive change, but no custodian update.
        deal(USDC, address(vault), 10_000e6);
        _enter(USDC, 10_000e6, balanceAccountA);

        _readBalanceOf();
        assertFalse(_readPaused(), "alpha enter does not trip big-change");
    }

    /// @notice Pause flag blocks user deposits via the pre-hook (real `PlasmaVault.deposit`).
    function test_fork_pauseBlocksUserDeposit() public {
        _createExecutor();
        _registerPausePreHook();
        _forcePaused(true);

        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookPaused.selector));
        vm.prank(user);
        vault.deposit(100e6, user);
    }

    /// @notice Pause flag blocks user withdraws via the pre-hook (real `PlasmaVault.withdraw`).
    function test_fork_pauseBlocksUserWithdraw() public {
        _createExecutor();
        _registerPausePreHook();

        // Deposit while unpaused so the user has shares to withdraw.
        _userDeposit(100e6);

        _forcePaused(true);

        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookPaused.selector));
        vm.prank(user);
        vault.withdraw(10e6, user, user);
    }

    /// @notice Pause flag does NOT block alpha-driven `execute` (the fuse `enter`/`exit` path).
    ///         Only user-facing selectors go through the pre-hook; alpha actions are never gated.
    function test_fork_pauseDoesNotBlockAlphaExecute() public {
        _registerPausePreHook();
        deal(USDC, address(vault), 500e6);
        _enter(USDC, 500e6, balanceAccountA);
        _forcePaused(true);

        // Alpha can still enter / exit — the op fuse does not consult the pause flag.
        deal(USDC, address(vault), 100e6);
        _enter(USDC, 100e6, balanceAccountA);

        (uint256 total,,) = IExternalStateExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 600e6, "alpha enter succeeded under pause");
    }

    /// @notice A valid atomist signature clears the pause flag.
    function test_fork_atomistSignatureUnpauses_clearsFlag() public {
        deal(USDC, address(vault), 500e6);
        _enter(USDC, 500e6, balanceAccountA);
        _forcePaused(true);

        ExternalStateUnpauseData memory d = _buildUnpauseData(500e6, 1, block.timestamp + 1 hours);
        _executeFuse(address(unpauseFuse), abi.encodeCall(unpauseFuse.unpause, (d)));

        assertFalse(_readPaused(), "pause cleared");
    }

    /// @notice TQ-14: enabling the pre-hook BEFORE the executor is deployed deterministically locks
    ///         every gated user operation (deposit / withdraw / mint / redeem) via
    ///         `ExternalStatePreHookExecutorNotDeployed`. This matches the production wiring order expectation:
    ///         operators MUST call `ExternalStateOperationFuse.createExecutor()` (or the first alpha enter)
    ///         prior to registering the pre-hook against user selectors — otherwise the vault is
    ///         effectively bricked until the executor is deployed.
    function test_fork_preHookRevertsWhenExecutorNotDeployed() public {
        // Sanity: setUp() wires substrates but does NOT deploy the executor.
        _registerPausePreHook();
        assertEq(_executorAddress(), address(0), "no executor yet");

        // Every gated user operation reverts before any share/asset math — the pre-hook runs
        // first (inside the restricted modifier), so no funding or approvals are needed.
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookExecutorNotDeployed.selector));
        vm.prank(user);
        vault.deposit(1e6, user);

        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookExecutorNotDeployed.selector));
        vm.prank(user);
        vault.mint(1e6, user);

        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookExecutorNotDeployed.selector));
        vm.prank(user);
        vault.withdraw(1e6, user, user);

        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookExecutorNotDeployed.selector));
        vm.prank(user);
        vault.redeem(1e6, user, user);

        // After the executor is lazily deployed (via createExecutor) the pre-hook no longer reverts
        // on the missing-executor path — it now runs the pause / staleness / big-change checks, and
        // in this test's state (no paused flag, no confirmed balances, custodianTs == lastChecked)
        // all three pass, so a real deposit goes through.
        _createExecutor();
        _userDeposit(1e6);
    }

    /// @notice A signature binds the atomist to a specific confirmed balance. If the balance
    ///         drifts (e.g. alpha exit) before unpause, the signature is rejected.
    function test_fork_atomistSignatureFailsIfBalanceChangesAfterSigning() public {
        deal(USDC, address(vault), 500e6);
        _enter(USDC, 500e6, balanceAccountA);
        _forcePaused(true);

        // Atomist signs for 500e6.
        ExternalStateUnpauseData memory d = _buildUnpauseData(500e6, 1, block.timestamp + 1 hours);

        // Balance drifts (alpha exits 100e6) — executor now reports 400e6.
        _exit(USDC, 100e6, balanceAccountA);

        vm.expectRevert(
            abi.encodeWithSelector(ExternalStateErrors.ExternalStateUnpauseBalanceMismatch.selector, uint256(500e6), uint256(400e6))
        );
        _executeFuse(address(unpauseFuse), abi.encodeCall(unpauseFuse.unpause, (d)));
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @dev Fund `user` with USDC and deposit into the real vault (goes through the pre-hook).
    function _userDeposit(uint256 amount_) internal {
        deal(USDC, user, amount_);
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), amount_);
        vault.deposit(amount_, user);
        vm.stopPrank();
    }
}
