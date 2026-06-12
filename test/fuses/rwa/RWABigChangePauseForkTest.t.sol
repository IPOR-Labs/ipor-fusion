// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RWAForkTestBase} from "./RWAForkTestBase.t.sol";
import {RWAUnpauseData} from "../../../contracts/fuses/rwa/RWAUnpauseFuse.sol";
import {RWAErrors} from "../../../contracts/fuses/rwa/errors/RWAErrors.sol";
import {IRWAExecutor} from "../../../contracts/fuses/rwa/IRWAExecutor.sol";

/// @title RWABigChangePauseForkTest
/// @notice Fork coverage for big-change detection, the pause flag, the staleness pre-hook gate
///         applied on user deposit/withdraw calls, and the atomist-signed unpause path.
///
///         The user-facing deposit/withdraw flow is exercised by *directly* invoking the pre-hook
///         the same way the real `PlasmaVault.deposit` would (via delegatecall). This matches
///         how `RWAPausePreHook` is invoked in production and keeps the test independent of a
///         real mainnet vault deployment.
contract RWABigChangePauseForkTest is RWAForkTestBase {
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

    /// @notice Pause flag blocks user deposits via the pre-hook.
    function test_fork_pauseBlocksUserDeposit() public {
        _createExecutor();
        _forcePaused(true);

        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPreHookPaused.selector));
        vault.delegateExecute(
            address(preHook), abi.encodeCall(preHook.run, (bytes4(keccak256("deposit(uint256,address)"))))
        );
    }

    /// @notice Pause flag blocks user withdraws via the pre-hook.
    function test_fork_pauseBlocksUserWithdraw() public {
        _createExecutor();
        _forcePaused(true);

        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPreHookPaused.selector));
        vault.delegateExecute(
            address(preHook), abi.encodeCall(preHook.run, (bytes4(keccak256("withdraw(uint256,address,address)"))))
        );
    }

    /// @notice Pause flag does NOT block alpha-driven `execute` (the fuse `enter`/`exit` path).
    ///         Only user-facing selectors go through the pre-hook; alpha actions are never gated.
    function test_fork_pauseDoesNotBlockAlphaExecute() public {
        deal(USDC, address(vault), 500e6);
        _enter(USDC, 500e6, balanceAccountA);
        _forcePaused(true);

        // Alpha can still enter / exit — the op fuse does not consult the pause flag.
        deal(USDC, address(vault), 100e6);
        _enter(USDC, 100e6, balanceAccountA);

        (uint256 total,,) = IRWAExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 600e6, "alpha enter succeeded under pause");
    }

    /// @notice A valid atomist signature clears the pause flag.
    function test_fork_atomistSignatureUnpauses_clearsFlag() public {
        deal(USDC, address(vault), 500e6);
        _enter(USDC, 500e6, balanceAccountA);
        _forcePaused(true);

        RWAUnpauseData memory d = _buildUnpauseData(500e6, 1, block.timestamp + 1 hours);
        vault.delegateExecute(address(unpauseFuse), abi.encodeCall(unpauseFuse.unpause, (d)));

        assertFalse(_readPaused(), "pause cleared");
    }

    /// @notice TQ-14: enabling the pre-hook BEFORE the executor is deployed deterministically locks
    ///         every gated user operation (deposit / withdraw / mint / redeem) via
    ///         `RWAPreHookExecutorNotDeployed`. This matches the production wiring order expectation:
    ///         operators MUST call `RWAOperationFuse.createExecutor()` (or the first alpha enter)
    ///         prior to registering the pre-hook against user selectors — otherwise the vault is
    ///         effectively bricked until the executor is deployed.
    function test_fork_preHookRevertsWhenExecutorNotDeployed() public {
        // Sanity: setUp() wires substrates + the pre-hook but does NOT deploy the executor.
        assertEq(_executorAddress(), address(0), "no executor yet");

        bytes4[4] memory gatedSelectors = [
            bytes4(keccak256("deposit(uint256,address)")),
            bytes4(keccak256("mint(uint256,address)")),
            bytes4(keccak256("withdraw(uint256,address,address)")),
            bytes4(keccak256("redeem(uint256,address,address)"))
        ];

        for (uint256 i; i < gatedSelectors.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPreHookExecutorNotDeployed.selector));
            vault.delegateExecute(address(preHook), abi.encodeCall(preHook.run, (gatedSelectors[i])));
        }

        // After the executor is lazily deployed (via createExecutor) the pre-hook no longer reverts
        // on the missing-executor path — it now runs the pause / staleness / big-change checks, and
        // in this test's state (no paused flag, no confirmed balances, custodianTs == lastChecked)
        // all three pass.
        _createExecutor();
        vault.delegateExecute(address(preHook), abi.encodeCall(preHook.run, (gatedSelectors[0])));
    }

    /// @notice A signature binds the atomist to a specific confirmed balance. If the balance
    ///         drifts (e.g. alpha exit) before unpause, the signature is rejected.
    function test_fork_atomistSignatureFailsIfBalanceChangesAfterSigning() public {
        deal(USDC, address(vault), 500e6);
        _enter(USDC, 500e6, balanceAccountA);
        _forcePaused(true);

        // Atomist signs for 500e6.
        RWAUnpauseData memory d = _buildUnpauseData(500e6, 1, block.timestamp + 1 hours);

        // Balance drifts (alpha exits 100e6) — executor now reports 400e6.
        _exit(USDC, 100e6, balanceAccountA);

        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAUnpauseBalanceMismatch.selector, uint256(500e6), uint256(400e6))
        );
        vault.delegateExecute(address(unpauseFuse), abi.encodeCall(unpauseFuse.unpause, (d)));
    }
}
