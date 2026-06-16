// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {RWAPausePreHook} from "../../../../contracts/handlers/pre_hooks/pre_hooks/RWAPausePreHook.sol";
import {RWAExecutor} from "../../../../contracts/fuses/rwa/RWAExecutor.sol";
import {IRWAExecutor} from "../../../../contracts/fuses/rwa/IRWAExecutor.sol";
import {RWAErrors} from "../../../../contracts/fuses/rwa/errors/RWAErrors.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";
import {RWASubstrateLib} from "../../../../contracts/fuses/rwa/lib/RWASubstrateLib.sol";

import {MockPlasmaVaultForRWA} from "./mocks/MockPlasmaVaultForRWA.sol";
import {RWATestConstants, RWASlotHelpers} from "./RWATestHelpers.sol";

/// @title RWAPausePreHookTest
/// @notice 8 unit tests for RWAPausePreHook via delegatecall from MockPlasmaVaultForRWA.
contract RWAPausePreHookTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.RWA;
    uint256 internal constant STALENESS_MAX_S = 3600;

    MockPlasmaVaultForRWA internal vault;
    RWAPausePreHook internal hook;

    address internal custodianA;
    address internal custodianB;
    address internal balanceAccount;

    function setUp() public {
        vault = new MockPlasmaVaultForRWA();
        hook = new RWAPausePreHook(MARKET_ID);
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
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPreHookPaused.selector));
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- 6.4 ----------
    function test_run_revertsWhenStale() public {
        address executor = _setupExecutor();
        _confirm(executor, 100);
        uint256 lastUpdated = block.timestamp;
        vm.warp(block.timestamp + STALENESS_MAX_S + 1);
        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAPreHookStale.selector, lastUpdated, block.timestamp, STALENESS_MAX_S)
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
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPreHookExecutorNotDeployed.selector));
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ---------- 6.7 ----------
    function test_run_pauseTakesPrecedenceOverStaleness() public {
        address executor = _setupExecutor();
        _confirm(executor, 100);
        vm.warp(block.timestamp + STALENESS_MAX_S + 1);
        _setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPreHookPaused.selector));
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
            vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPreHookExecutorNotDeployed.selector));
            vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (selectors[i])));
        }
    }

    // ---------- TQ-11 (pre-hook): inline big-change detection ----------

    /// @notice Pre-hook detects unprocessed big-change from custodian confirm even when pause flag is false.
    function test_run_inlineBigChangeDetection_revertsBeforeBalanceOf() public {
        address executor = _setupExecutor();
        // Seed baseline: addBalance + balanceOf to establish lastTotalBalance and lastCheckedCustodianTs
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100);
        // Write lastTotalBalance and lastCheckedCustodianTimestamp via storage (mimic balanceOf)
        RWASlotHelpers.setLastTotalBalance(address(vault), 100); // lastTotalBalance = 100
        // lastCheckedCustodianTimestamp starts at 0, executor.lastCustodianUpdateTimestamp also 0 → match

        // Custodian confirm: +200% (100 → 300)
        _confirm(executor, 300);

        // Now executor.lastCustodianUpdateTimestamp != vault's lastCheckedCustodianTimestamp
        // and delta (200/100 = 200%) > bigChangeBps (1000 bps = 10%)
        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAPreHookBigChangeDetected.selector, uint256(100), uint256(300), uint256(1000))
        );
        vault.delegateExecute(address(hook), abi.encodeCall(hook.run, (bytes4(0))));
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _setupExecutor() internal returns (address executor) {
        bytes32[] memory subs = new bytes32[](6);
        subs[0] = RWASubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[1] = RWASubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[2] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = RWASubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[4] = RWASubstrateLib.encodeDustThresholdSubstrate(100);
        subs[5] = RWASubstrateLib.encodeBigChangeBpsSubstrate(1000);
        vault.grantMarketSubstrates(MARKET_ID, subs);

        executor = address(new RWAExecutor(MARKET_ID, address(vault)));
        (bool ok,) = executor.call(abi.encodeCall(IRWAExecutor.syncSubstrates, ()));
        require(ok, "sync failed");
        RWASlotHelpers.setExecutor(address(vault), executor);
    }

    function _confirm(address executor_, uint256 newValue_) internal {
        vm.prank(custodianA);
        IRWAExecutor(executor_).proposeBalance(balanceAccount, newValue_);
        (,, uint64 pa, uint256 n) = RWAExecutor(executor_).pendingProposals(balanceAccount);
        bytes32 h = keccak256(abi.encode(executor_, block.chainid, balanceAccount, newValue_, custodianA, pa, n));
        vm.prank(custodianB);
        IRWAExecutor(executor_).confirmBalance(balanceAccount, h);
    }

    function _setPaused(bool v_) internal {
        RWASlotHelpers.setPaused(address(vault), v_);
    }
}
