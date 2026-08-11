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

    function setUp() public {
        vault = new MockPlasmaVaultForExternalState();
        hook = new ExternalStatePausePreHook(MARKET_ID);
        custodianA = makeAddr("custA");
        custodianB = makeAddr("custB");
        balanceAccount = makeAddr("ba");
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
            abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookStale.selector, lastUpdated, block.timestamp, STALENESS_MAX_S)
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
            bytes4(0xb460af94)  // withdraw(uint256,address,address)
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookExecutorNotDeployed.selector));
            vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (selectors[i])));
        }
    }

    // ---------- TQ-11 (pre-hook): inline big-change detection ----------

    /// @notice Pre-hook detects unprocessed big-change from custodian confirm even when pause flag is false.
    function test_run_inlineBigChangeDetection_revertsBeforeBalanceOf() public {
        address executor = _setupExecutor();
        // Seed baseline: addBalance + balanceOf to establish lastTotalBalance and lastCheckedCustodianTs
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100);
        // Write lastTotalBalance and lastCheckedCustodianTimestamp via storage (mimic balanceOf)
        ExternalStateSlotHelpers.setLastTotalBalance(address(vault), 100); // lastTotalBalance = 100
        // lastCheckedCustodianTimestamp starts at 0, executor.lastCustodianUpdateTimestamp also 0 → match

        // Custodian confirm: +200% (100 → 300)
        _confirm(executor, 300);

        // Now executor.lastCustodianUpdateTimestamp != vault's lastCheckedCustodianTimestamp
        // and delta (200/100 = 200%) > bigChangeBps (1000 bps = 10%)
        vm.expectRevert(
            abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookBigChangeDetected.selector, uint256(100), uint256(300), uint256(1000))
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
        (bool ok,) = executor.call(abi.encodeCall(IExternalStateExecutor.syncSubstrates, ()));
        require(ok, "sync failed");
        ExternalStateSlotHelpers.setExecutor(address(vault), executor);
    }

    function _confirm(address executor_, uint256 newValue_) internal {
        vm.prank(custodianA);
        IExternalStateExecutor(executor_).proposeBalance(balanceAccount, newValue_);
        (,, uint64 pa, uint256 n) = ExternalStateExecutor(executor_).pendingProposals(balanceAccount);
        bytes32 h = keccak256(abi.encode(executor_, block.chainid, balanceAccount, newValue_, custodianA, pa, n));
        vm.prank(custodianB);
        IExternalStateExecutor(executor_).confirmBalance(balanceAccount, h);
    }

    function _setPaused(bool v_) internal {
        ExternalStateSlotHelpers.setPaused(address(vault), v_);
    }
}
