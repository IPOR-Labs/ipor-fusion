// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ExternalStatePausePreHook} from "../../../../contracts/handlers/pre_hooks/pre_hooks/ExternalStatePausePreHook.sol";
import {ExternalStateExecutor} from "../../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {IExternalStateExecutor} from "../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateErrors} from "../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";
import {ExternalStateSubstrateLib} from "../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";

import {MockPlasmaVaultForExternalState} from "./mocks/MockPlasmaVaultForExternalState.sol";
import {ExternalStateTestConstants, ExternalStateSlotHelpers} from "./ExternalStateTestHelpers.sol";

/// @title ExternalStatePausePreHookTest
/// @notice 8 unit tests for ExternalStatePausePreHook via delegatecall from MockPlasmaVaultForExternalState.
contract ExternalStatePausePreHookTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;
    uint256 internal constant STALENESS_MAX_S = 3600;

    MockPlasmaVaultForExternalState internal vault;
    ExternalStatePausePreHook internal hook;

    address internal custodianA;
    address internal custodianB;
    address internal balanceAccount;
    address internal balanceAccount2;

    function setUp() public {
        vault = new MockPlasmaVaultForExternalState();
        hook = new ExternalStatePausePreHook(MARKET_ID);
        custodianA = makeAddr("custA");
        custodianB = makeAddr("custB");
        balanceAccount = makeAddr("ba");
        balanceAccount2 = makeAddr("ba2");
    }

    // ---------- 6.1 ----------
    function test_constructor_setsMarketId() public view {
        assertEq(hook.MARKET_ID(), MARKET_ID);
    }

    // ---------- 6.2 ----------
    function test_run_passesWhenNotPausedAndFresh() public {
        _setupExecutor();
        _setPaused(false);
        // No confirmed update yet → oldest == 0, exempt
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- 6.3 ----------
    function test_run_revertsWhenPausedFlagSet() public {
        _setupExecutor();
        _setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookPaused.selector));
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- 6.4 ----------
    function test_run_revertsWhenStale() public {
        address executor = _setupExecutor();
        _confirm(executor, 100);
        uint256 lastUpdated = block.timestamp;
        vm.warp(block.timestamp + STALENESS_MAX_S + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStatePreHookStale.selector,
                lastUpdated,
                block.timestamp,
                STALENESS_MAX_S
            )
        );
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- 6.5 ----------
    function test_run_exemptWhenOldestTimestampZero() public {
        _setupExecutor();
        // No custodian confirms yet — oldest remains 0.
        vm.warp(block.timestamp + STALENESS_MAX_S + 999);
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- 6.6 ----------
    function test_run_revertsWhenExecutorNotDeployed() public {
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookExecutorNotDeployed.selector));
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- 6.7 ----------
    function test_run_pauseTakesPrecedenceOverStaleness() public {
        address executor = _setupExecutor();
        _confirm(executor, 100);
        vm.warp(block.timestamp + STALENESS_MAX_S + 1);
        _setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookPaused.selector));
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- 6.8 ----------
    function test_run_selectorIgnored() public {
        _setupExecutor();
        _setPaused(false);
        // selector value doesn't alter behavior (no oldest update to check either)
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0xdeadbeef))));
    }

    // ---------- TQ-14: pre-hook without executor locks all gated ops ----------

    /// @notice When the pre-hook is active but no executor has been deployed, every gated
    ///         selector reverts — the vault is effectively locked until createExecutor is called.
    function test_run_noExecutor_allSelectorsBlocked() public {
        // No executor deployed (fresh vault). Different selectors should all revert the same way.
        bytes4[3] memory selectors = [
            bytes4(0x6e553f65), // deposit(uint256,address)
            bytes4(0xba087652), // redeem(uint256,address,address)
            bytes4(0xb460af94) // withdraw(uint256,address,address)
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookExecutorNotDeployed.selector)
            );
            vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (selectors[i])));
        }
    }

    // ---------- TQ-11 (pre-hook): inline big-change detection ----------

    /// @notice Pre-hook detects unprocessed big-change from custodian confirm even when pause flag is false.
    function test_run_inlineBigChangeDetection_revertsBeforeBalanceOf() public {
        address executor = _setupExecutor();
        // Seed baseline: addBalance + balanceOf to establish lastTotalBalance and lastCheckedCustodianTs
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100, address(0), 0);
        // Write lastTotalBalance and lastCheckedCustodianConfirmCount via storage (mimic balanceOf)
        ExternalStateSlotHelpers.setLastTotalBalance(address(vault), 100); // lastTotalBalance = 100
        // lastCheckedCustodianConfirmCount starts at 0, executor.confirmCount also 0 → match

        // Custodian confirm: +200% (100 → 300)
        _confirm(executor, 300);

        // Now executor.confirmCount != vault's lastCheckedCustodianConfirmCount
        // and delta (200/100 = 200%) > bigChangeBps (1000 bps = 10%)
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStatePreHookBigChangeDetected.selector,
                uint256(100),
                uint256(300),
                uint256(1000)
            )
        );
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- IL-7969 regression: same-block second confirm must still gate user ops ----------

    /// @notice Reproduces the IL-7969 defect chain at the pre-hook: a custodian pair confirms an
    ///         innocuous change on BA1, the balance fuse's `balanceOf()` observes it in the same
    ///         block (advancing the watermark), and then the same pair confirms an arbitrarily large
    ///         balance on a second account BA2 — still in the same block. Pre-fix, the pre-hook's
    ///         `lastCustodianTs != lastChecked` comparison is blind to the second confirm because both
    ///         share `block.timestamp`, so `run()` returns without reverting and the gated user op is
    ///         allowed through at the inflated NAV. Post-fix, the watermark is `confirmCount`, so the
    ///         second confirm is always observed and `run()` reverts.
    function test_run_SameBlockSecondConfirm_Reverts() public {
        vm.warp(1_700_000_000); // fix T explicitly; all calls below stay in this same block/timestamp
        (address executor, ) = _setupExecutorTwoAccounts();

        // Step 1: custodian pair confirms an innocuous change on BA1 (first-ever confirm: prevTotal==0
        // so the mimicked balanceOf below establishes the baseline without pausing).
        _confirmAccount(executor, balanceAccount, 100);

        // Step 2: mimic the keeper's balanceOf() read in the SAME block by writing exactly what
        // `ExternalStateBalanceFuse.balanceOf()` would persist: the current total as `lastTotalBalance`
        // and the current snapshot watermark as `lastCheckedCustodianConfirmCount`. This is read live
        // from the executor (not hardcoded), so it reflects whatever `getBalanceFuseSnapshot()`
        // actually returns for its third value.
        (uint256 totalAfterStep1, , uint256 checkedAfterStep1) = IExternalStateExecutor(executor)
            .getBalanceFuseSnapshot();
        ExternalStateSlotHelpers.setLastTotalBalance(address(vault), totalAfterStep1);
        ExternalStateSlotHelpers.setLastCheckedCustodianConfirmCount(address(vault), checkedAfterStep1);

        // No-op control: immediately after establishing the baseline (no new confirm yet), run() must
        // NOT false-positive.
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));

        uint256 tsAfterStep1 = ExternalStateExecutor(executor).lastCustodianUpdateTimestamp();
        uint256 confirmCountAfterStep1 = ExternalStateExecutor(executor).confirmCount();

        // Step 3: the SAME custodian pair confirms an arbitrarily large balance on BA2 (first update
        // for BA2, `minUpdateInterval`-exempt), STILL in the same block — no `vm.warp` between step 1
        // and step 3.
        _confirmAccount(executor, balanceAccount2, 10_000);

        // On-chain proof of the defect this fix closes: the OLD timestamp watermark is UNCHANGED by
        // the second confirm, while `confirmCount` strictly increased.
        assertEq(
            ExternalStateExecutor(executor).lastCustodianUpdateTimestamp(),
            tsAfterStep1,
            "defect proof: same-block confirms share one timestamp (pre-fix watermark would be blind)"
        );
        assertEq(
            ExternalStateExecutor(executor).confirmCount(),
            confirmCountAfterStep1 + 1,
            "fix proof: confirmCount strictly increases per confirmation even within the same block"
        );

        // Step 4: run() must revert with the big-change error instead of silently letting the user op
        // through. prevTotal=100, totalBalance=100+10_000=10_100 → delta/prev = 10_000% >> 10%.
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStatePreHookBigChangeDetected.selector,
                uint256(100),
                uint256(10_100),
                uint256(1000)
            )
        );
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    /// @notice Control: the same two-confirm sequence, but the second confirm lands in a LATER block.
    ///         Normal breaker behaviour is unaffected by the fix: a big change in a later block still
    ///         reverts. Passes both before and after the fix.
    function test_run_DifferentBlock_Control() public {
        (address executor, ) = _setupExecutorTwoAccounts();

        _confirmAccount(executor, balanceAccount, 100);
        (uint256 totalAfterStep1, , uint256 checkedAfterStep1) = IExternalStateExecutor(executor)
            .getBalanceFuseSnapshot();
        ExternalStateSlotHelpers.setLastTotalBalance(address(vault), totalAfterStep1);
        ExternalStateSlotHelpers.setLastCheckedCustodianConfirmCount(address(vault), checkedAfterStep1);

        // No-op control: nothing new happened yet — run() must not false-positive.
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));

        vm.warp(block.timestamp + 1); // DIFFERENT block/timestamp for the second confirm
        _confirmAccount(executor, balanceAccount2, 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStatePreHookBigChangeDetected.selector,
                uint256(100),
                uint256(10_100),
                uint256(1000)
            )
        );
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _setupExecutor() internal returns (address executor) {
        bytes32[] memory subs = new bytes32[](6);
        subs[0] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[1] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[4] = ExternalStateSubstrateLib.encodeDustThresholdSubstrate(100);
        subs[5] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(1000);
        vault.grantMarketSubstrates(MARKET_ID, subs);

        executor = address(new ExternalStateExecutor(MARKET_ID, address(vault)));
        (bool ok, ) = executor.call(abi.encodeCall(IExternalStateExecutor.syncSubstrates, ()));
        require(ok, "sync failed");
        ExternalStateSlotHelpers.setExecutor(address(vault), executor);
    }

    /// @notice Same as `_setupExecutor` but grants a SECOND balance account (`balanceAccount2`),
    ///         needed to reproduce the IL-7969 defect chain without hitting `minUpdateInterval` on a
    ///         same-account re-confirm.
    function _setupExecutorTwoAccounts() internal returns (address executor, address ba2) {
        ba2 = balanceAccount2;
        bytes32[] memory subs = new bytes32[](7);
        subs[0] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[1] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount2);
        subs[4] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[5] = ExternalStateSubstrateLib.encodeDustThresholdSubstrate(100);
        subs[6] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(1000);
        vault.grantMarketSubstrates(MARKET_ID, subs);

        executor = address(new ExternalStateExecutor(MARKET_ID, address(vault)));
        (bool ok, ) = executor.call(abi.encodeCall(IExternalStateExecutor.syncSubstrates, ()));
        require(ok, "sync failed");
        ExternalStateSlotHelpers.setExecutor(address(vault), executor);
    }

    function _confirm(address executor_, uint256 newValue_) internal {
        _confirmAccount(executor_, balanceAccount, newValue_);
    }

    function _confirmAccount(address executor_, address balanceAccount_, uint256 newValue_) internal {
        vm.prank(custodianA);
        IExternalStateExecutor(executor_).proposeBalance(balanceAccount_, newValue_);
        (, , uint64 pa, uint256 n) = ExternalStateExecutor(executor_).pendingProposals(balanceAccount_);
        bytes32 h = keccak256(abi.encode(executor_, block.chainid, balanceAccount_, newValue_, custodianA, pa, n));
        vm.prank(custodianB);
        IExternalStateExecutor(executor_).confirmBalance(balanceAccount_, h);
    }

    function _setPaused(bool v_) internal {
        ExternalStateSlotHelpers.setPaused(address(vault), v_);
    }
}
