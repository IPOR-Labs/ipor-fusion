// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ExternalStateBalanceFuse} from "../../../../contracts/fuses/external_state/ExternalStateBalanceFuse.sol";
import {ExternalStateExecutor} from "../../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {IExternalStateExecutor} from "../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateExecutorStorageLib} from "../../../../contracts/fuses/external_state/lib/ExternalStateExecutorStorageLib.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";
import {ExternalStateSubstrateLib} from "../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";
import {ExternalStateErrors} from "../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";

import {MockPlasmaVaultForExternalState} from "./mocks/MockPlasmaVaultForExternalState.sol";
import {MockERC20ForExternalState} from "./mocks/MockERC20ForExternalState.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {ExternalStateTestConstants, ExternalStateSlotHelpers} from "./ExternalStateTestHelpers.sol";

/// @title ExternalStateBalanceFuseTest
/// @notice 16 unit tests for ExternalStateBalanceFuse via delegatecall from MockPlasmaVaultForExternalState.
contract ExternalStateBalanceFuseTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;

    MockPlasmaVaultForExternalState internal vault;
    ExternalStateBalanceFuse internal fuse;
    MockPriceOracleMiddleware internal oracle;

    MockERC20ForExternalState internal underlying6; // 6 decimals
    MockERC20ForExternalState internal underlying18; // 18 decimals

    address internal custodianA;
    address internal custodianB;
    address internal balanceAccount;
    address internal balanceAccount2;

    uint256 internal constant BIG_CHANGE_BPS = 1000; // 10%

    function setUp() public {
        vault = new MockPlasmaVaultForExternalState();
        fuse = new ExternalStateBalanceFuse(MARKET_ID);
        oracle = new MockPriceOracleMiddleware();
        underlying6 = new MockERC20ForExternalState("U6", "U6", 6);
        underlying18 = new MockERC20ForExternalState("U18", "U18", 18);

        vault.setUnderlying(address(underlying6));
        vault.setPriceOracleMiddleware(address(oracle));
        oracle.setPrice(address(underlying6), 1e8, 8); // $1
        oracle.setPrice(address(underlying18), 1e8, 8); // $1

        custodianA = makeAddr("custA");
        custodianB = makeAddr("custB");
        balanceAccount = makeAddr("ba");
        balanceAccount2 = makeAddr("ba2");
    }

    // ---------- 5.1 ----------
    function test_constructor_setsMarketIdAndVersion() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.VERSION(), address(fuse));
    }

    // ---------- 5.2 ----------
    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateZeroMarketId.selector));
        new ExternalStateBalanceFuse(0);
    }

    // ---------- 5.3 ----------
    function test_balanceOf_returnsZeroWhenExecutorNotDeployed() public {
        bytes memory ret = vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        uint256 value = abi.decode(ret, (uint256));
        assertEq(value, 0);
    }

    // ---------- 5.4 ----------
    function test_balanceOf_returnsZeroWhenTotalBalanceZero() public {
        _setupWithExecutor();
        bytes memory ret = vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        uint256 value = abi.decode(ret, (uint256));
        assertEq(value, 0);
    }

    // ---------- 5.5 ----------
    function test_balanceOf_convertsUnderlyingToUsdWad() public {
        address executor = _setupWithExecutor();
        // Seed a balance via addBalance (simulating enter flow)
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0); // 100 underlying (6d) = $100

        bytes memory ret = vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        uint256 value = abi.decode(ret, (uint256));
        assertEq(value, 100e18);
    }

    // ---------- 5.6 ----------
    function test_balanceOf_writesLastTotalBalanceAlways() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 500e6, address(0), 0);

        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertEq(_readLastTotalBalance(), 500e6);
    }

    // ---------- 5.7 ----------
    function test_balanceOf_notView_successWhenCalledNonView() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 1e6, address(0), 0);
        // If balanceOf had view modifier, this would not compile. Its return reaches us.
        bytes memory ret = vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertEq(abi.decode(ret, (uint256)), 1e18);
    }

    // ---------- 5.8 ----------
    function test_balanceOf_doesNotTriggerBigChangeWhenCustodianTsUnchanged() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        // Large change via addBalance (no custodian update), big-change must NOT trip
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 1000e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused());
    }

    // ---------- 5.9 ----------
    function test_balanceOf_triggersPauseWhenCustodianTsChangedAndDeltaExceedsBps() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);

        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline 100e6

        // Custodian updates to 200e6 (+100%, above 10% threshold)
        _custodianConfirm(executor, 200e6);

        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused());
    }

    // ---------- 5.10 ----------
    function test_balanceOf_doesNotTriggerPauseWhenDeltaWithinBps() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));

        // Custodian updates to 105e6 (+5%, below 10% threshold)
        _custodianConfirm(executor, 105e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused());
    }

    // ---------- 5.11 ----------
    function test_balanceOf_updatesLastCheckedCustodianConfirmCountEvenIfBelowThreshold() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));

        _custodianConfirm(executor, 101e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        (, , uint256 confirmCount) = IExternalStateExecutor(executor).getBalanceFuseSnapshot();
        assertEq(_readLastCheckedCustodianConfirmCount(), confirmCount);
    }

    // ---------- 5.12 ----------
    function test_balanceOf_firstCall_prevTotalZero_skipsBigChange() public {
        address executor = _setupWithExecutor();
        // First custodian update without any prior balance fuse call: prev=0, big-change skipped
        _custodianConfirm(executor, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused());
    }

    // ---------- 5.13 ----------
    function test_balanceOf_bigChangeSymmetric_increaseAndDecrease() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline 100

        // Custodian sets to 10 (-90%)
        _custodianConfirm(executor, 10e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused());
    }

    // ---------- 5.14 ----------
    function test_balanceOf_emitsExternalStateBigChangeDetected() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));

        _custodianConfirm(executor, 300e6);

        vm.expectEmit(false, false, false, true, address(vault));
        emit ExternalStateBalanceFuse.ExternalStateBigChangeDetected(100e6, 300e6, BIG_CHANGE_BPS);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
    }

    // ---------- 5.15 ----------
    function test_balanceOf_revertsWhenPriceOracleNotSet() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.setPriceOracleMiddleware(address(0));

        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePriceOracleNotSet.selector));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
    }

    // ---------- 5.16 ----------
    function test_balanceOf_handlesDifferentUnderlyingDecimals() public {
        // reconfigure to underlying18
        vault.setUnderlying(address(underlying18));
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 10e18, address(0), 0);

        bytes memory ret = vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        uint256 value = abi.decode(ret, (uint256));
        assertEq(value, 10e18); // 10 underlying @ $1 = 10 USD WAD
    }

    // ---------- TQ-11: big-change adversarial scenarios ----------

    /// @notice Repeated balanceOf reads with massive addBalance deltas never trip pause (no custodian update).
    function test_balanceOf_repeatedReadsWithoutCustodianUpdate_neverPause() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        // 10 massive addBalance operations — each doubles balance but no custodian confirm
        for (uint256 i; i < 10; ++i) {
            vm.prank(address(vault));
            IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6 * (2 ** i), address(0), 0);
            vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
            assertFalse(_readPaused(), "pause should not trigger without custodian update");
        }
    }

    /// @notice Once big-change triggers pause, subsequent balanceOf calls do NOT clear the flag.
    function test_balanceOf_pauseOnCustodianUpdate_stickyUntilUnpause() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));

        _custodianConfirm(executor, 200e6); // +100% → triggers pause
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused());

        // Calling balanceOf again does not clear pause (no new custodian ts to check)
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "pause must be sticky");
    }

    // ---------- TQ-13: big-change math edge cases ----------

    /// @notice prevTotal=1, totalBalance=2 → delta/prev = 10000 bps (100%). At 10% threshold → pause.
    function test_balanceOf_bigChangeMath_smallValues_prevOne_totalTwo() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 1, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline: prevTotal=1

        _custodianConfirm(executor, 2); // +100%
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "100% change on small values should trigger pause");
    }

    /// @notice prevTotal=100, totalBalance=110 → delta/prev = 1000 bps (10%). At 10% threshold → exact boundary.
    function test_balanceOf_bigChangeMath_exactBoundary_10percent() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        // 10% increase: (10e6 * 10000) / 100e6 = 1000. threshold = 1000 → NOT exceeded (> not >=)
        _custodianConfirm(executor, 110e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused(), "exactly at threshold should not pause (strict >)");
    }

    /// @notice prevTotal=100, totalBalance=111 → delta/prev = 1100 bps (11%). At 10% threshold → pause.
    function test_balanceOf_bigChangeMath_justAboveBoundary() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        _custodianConfirm(executor, 111e6); // 11%
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "11% > 10% should trigger pause");
    }

    /// @notice Custodian confirm + balanceOf in the same block: pause is detected.
    function test_balanceOf_custodianUpdateAndReadSameBlock_pauseDetected() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(executor).addBalance(balanceAccount, 100e6, address(0), 0);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        // Same block: custodian confirm + balanceOf
        _custodianConfirm(executor, 250e6); // +150%
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "big-change must be detected in same block");
    }

    // ---------- IL-7969 regression: same-block second confirm must not bypass the breaker ----------

    /// @notice Reproduces the IL-7969 defect chain: a custodian pair confirms an innocuous change on
    ///         BA1, a keeper `balanceOf()` read observes it (advancing the old timestamp watermark to
    ///         T), and then the SAME custodian pair confirms an arbitrarily large balance on a second
    ///         account BA2 in the SAME block (same `block.timestamp` T). Pre-fix, the watermark
    ///         comparison `lastCustodianTs != lastChecked` is blind to the second confirm because both
    ///         confirms share timestamp T, so the big-change branch is skipped and `setPaused(true)`
    ///         never fires. Post-fix, the watermark is `confirmCount` — a strictly monotonic
    ///         per-confirmation counter — so the second confirm is always observed.
    function test_balanceOf_SameBlockSecondConfirm_TripsBreaker() public {
        vm.warp(1_700_000_000); // fix T explicitly; all calls below stay in this same block/timestamp
        (address executor, ) = _setupWithExecutorTwoAccounts();

        // Genesis confirm on BA1 establishes a non-zero baseline (first-ever confirm: prevTotal==0,
        // so no pause check fires yet — matches existing "5.12" baseline semantics).
        _custodianConfirmAccount(executor, balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused(), "genesis baseline must not pause");
        assertEq(_readLastTotalBalance(), 100e6);

        uint256 tsAfterGenesis = ExternalStateExecutor(executor).lastCustodianUpdateTimestamp();
        uint256 confirmCountAfterGenesis = ExternalStateExecutor(executor).confirmCount();

        // Step 1: custodian pair confirms an innocuous +5% change on BA1 (below the 10% threshold),
        // still at T.
        _custodianConfirmAccount(executor, balanceAccount, 105e6);

        // Step 2: keeper's balanceOf() runs in the SAME block: below-threshold, stays unpaused, and
        // adopts the new total as the baseline.
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused(), "below-threshold change must not pause");
        assertEq(_readLastTotalBalance(), 105e6, "baseline must adopt the small total");

        uint256 tsAfterStep1 = ExternalStateExecutor(executor).lastCustodianUpdateTimestamp();
        uint256 confirmCountAfterStep1 = ExternalStateExecutor(executor).confirmCount();

        // Step 3: the SAME custodian pair confirms an arbitrarily large balance on BA2 (first update
        // for BA2, `minUpdateInterval`-exempt), STILL in the same block — no `vm.warp` between step 1
        // and step 3.
        _custodianConfirmAccount(executor, balanceAccount2, 10_000e6);

        // On-chain proof of the defect this fix closes: the OLD timestamp watermark is UNCHANGED by
        // the second confirm (both confirms share `block.timestamp` T) — a `!=` comparison against it
        // would be blind to this second confirm. `confirmCount`, by contrast, strictly increased.
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
        assertGt(ExternalStateExecutor(executor).confirmCount(), confirmCountAfterGenesis + 1);

        // Step 4: next balanceOf() must trip the breaker instead of silently re-baselining past it.
        // prevTotal=105e6, totalBalance=105e6+10_000e6=10_105e6 → delta/prev ≈ 9524% >> 10% threshold.
        vm.expectEmit(false, false, false, true, address(vault));
        emit ExternalStateBalanceFuse.ExternalStateBigChangeDetected(105e6, 10_105e6, BIG_CHANGE_BPS);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "same-block second confirm must trip the circuit breaker");
    }

    /// @notice Control: the same two-confirm sequence, but the second confirm lands in a LATER block
    ///         (different `block.timestamp`). Normal breaker behaviour must be unchanged by the fix:
    ///         a below-threshold change stays unpaused and an above-threshold change on a fresh
    ///         account still pauses. This test passes both before and after the fix.
    function test_balanceOf_DifferentBlockConfirms_ControlUnchanged() public {
        (address executor, ) = _setupWithExecutorTwoAccounts();

        _custodianConfirmAccount(executor, balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline
        assertFalse(_readPaused());

        // Different block: below-threshold change stays unpaused.
        vm.warp(block.timestamp + 1);
        _custodianConfirmAccount(executor, balanceAccount, 105e6); // +5%
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused(), "below-threshold change in a later block must not pause");
        assertEq(_readLastTotalBalance(), 105e6);

        // Different block again: above-threshold change on BA2 pauses as expected.
        vm.warp(block.timestamp + 1);
        _custodianConfirmAccount(executor, balanceAccount2, 10_000e6); // huge jump
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "above-threshold change in a later block must pause (regression guard)");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _setupWithExecutor() internal returns (address executor) {
        bytes32[] memory subs = new bytes32[](5);
        subs[0] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[1] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[4] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(1 days);
        vault.grantMarketSubstrates(MARKET_ID, subs);

        executor = address(new ExternalStateExecutor(MARKET_ID, address(vault)));
        executor.call(abi.encodeCall(IExternalStateExecutor.syncSubstrates, ()));
        // Persist executor into ERC-7201 slot of the vault
        ExternalStateSlotHelpers.setExecutor(address(vault), executor);
    }

    /// @notice Same as `_setupWithExecutor` but grants a SECOND balance account (`balanceAccount2`),
    ///         needed to reproduce the IL-7969 defect chain, which requires two distinct accounts
    ///         (a second same-block confirm on the same account would hit `minUpdateInterval`, which
    ///         is exempt only on an account's first update).
    function _setupWithExecutorTwoAccounts() internal returns (address executor, address ba2) {
        ba2 = balanceAccount2;
        bytes32[] memory subs = new bytes32[](6);
        subs[0] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[1] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount2);
        subs[4] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[5] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(1 days);
        vault.grantMarketSubstrates(MARKET_ID, subs);

        executor = address(new ExternalStateExecutor(MARKET_ID, address(vault)));
        executor.call(abi.encodeCall(IExternalStateExecutor.syncSubstrates, ()));
        ExternalStateSlotHelpers.setExecutor(address(vault), executor);
    }

    function _custodianConfirm(address executor_, uint256 newValue_) internal {
        _custodianConfirmAccount(executor_, balanceAccount, newValue_);
    }

    function _custodianConfirmAccount(address executor_, address balanceAccount_, uint256 newValue_) internal {
        vm.prank(custodianA);
        IExternalStateExecutor(executor_).proposeBalance(balanceAccount_, newValue_);

        // fetch pending
        (, , uint64 pa, uint256 n) = ExternalStateExecutor(executor_).pendingProposals(balanceAccount_);
        bytes32 h = keccak256(abi.encode(executor_, block.chainid, balanceAccount_, newValue_, custodianA, pa, n));
        vm.prank(custodianB);
        IExternalStateExecutor(executor_).confirmBalance(balanceAccount_, h);
    }

    function _readPaused() internal view returns (bool) {
        return ExternalStateSlotHelpers.readPaused(address(vault));
    }

    function _readLastTotalBalance() internal view returns (uint256) {
        bytes32 s = bytes32(
            uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) +
                ExternalStateTestConstants.LAST_TOTAL_BALANCE_SLOT_OFFSET
        );
        return uint256(vm.load(address(vault), s));
    }

    function _readLastCheckedCustodianConfirmCount() internal view returns (uint256) {
        bytes32 s = bytes32(
            uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) +
                ExternalStateTestConstants.LAST_CHECKED_CUSTODIAN_CONFIRM_COUNT_SLOT_OFFSET
        );
        return uint256(vm.load(address(vault), s));
    }
}
