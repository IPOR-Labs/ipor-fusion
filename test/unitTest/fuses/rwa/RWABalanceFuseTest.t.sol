// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {RWABalanceFuse} from "../../../../contracts/fuses/rwa/RWABalanceFuse.sol";
import {RWAExecutor} from "../../../../contracts/fuses/rwa/RWAExecutor.sol";
import {IRWAExecutor} from "../../../../contracts/fuses/rwa/IRWAExecutor.sol";
import {RWAExecutorStorageLib} from "../../../../contracts/fuses/rwa/lib/RWAExecutorStorageLib.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";
import {RWASubstrateLib} from "../../../../contracts/fuses/rwa/lib/RWASubstrateLib.sol";
import {RWAErrors} from "../../../../contracts/fuses/rwa/errors/RWAErrors.sol";

import {MockPlasmaVaultForRWA} from "./mocks/MockPlasmaVaultForRWA.sol";
import {MockERC20ForRWA} from "./mocks/MockERC20ForRWA.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {RWATestConstants, RWASlotHelpers} from "./RWATestHelpers.sol";

/// @title RWABalanceFuseTest
/// @notice 16 unit tests for RWABalanceFuse via delegatecall from MockPlasmaVaultForRWA.
contract RWABalanceFuseTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.RWA;

    MockPlasmaVaultForRWA internal vault;
    RWABalanceFuse internal fuse;
    MockPriceOracleMiddleware internal oracle;

    MockERC20ForRWA internal underlying6; // 6 decimals
    MockERC20ForRWA internal underlying18; // 18 decimals

    address internal custodianA;
    address internal custodianB;
    address internal balanceAccount;

    uint256 internal constant BIG_CHANGE_BPS = 1000; // 10%

    function setUp() public {
        vault = new MockPlasmaVaultForRWA();
        fuse = new RWABalanceFuse(MARKET_ID);
        oracle = new MockPriceOracleMiddleware();
        underlying6 = new MockERC20ForRWA("U6", "U6", 6);
        underlying18 = new MockERC20ForRWA("U18", "U18", 18);

        vault.setUnderlying(address(underlying6));
        vault.setPriceOracleMiddleware(address(oracle));
        oracle.setPrice(address(underlying6), 1e8, 8); // $1
        oracle.setPrice(address(underlying18), 1e8, 8); // $1

        custodianA = makeAddr("custA");
        custodianB = makeAddr("custB");
        balanceAccount = makeAddr("ba");
    }

    // ---------- 5.1 ----------
    function test_constructor_setsMarketIdAndVersion() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.VERSION(), address(fuse));
    }

    // ---------- 5.2 ----------
    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAZeroMarketId.selector));
        new RWABalanceFuse(0);
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
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6); // 100 underlying (6d) = $100

        bytes memory ret = vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        uint256 value = abi.decode(ret, (uint256));
        assertEq(value, 100e18);
    }

    // ---------- 5.6 ----------
    function test_balanceOf_writesLastTotalBalanceAlways() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 500e6);

        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertEq(_readLastTotalBalance(), 500e6);
    }

    // ---------- 5.7 ----------
    function test_balanceOf_notView_successWhenCalledNonView() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 1e6);
        // If balanceOf had view modifier, this would not compile. Its return reaches us.
        bytes memory ret = vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertEq(abi.decode(ret, (uint256)), 1e18);
    }

    // ---------- 5.8 ----------
    function test_balanceOf_doesNotTriggerBigChangeWhenCustodianTsUnchanged() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        // Large change via addBalance (no custodian update), big-change must NOT trip
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 1000e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused());
    }

    // ---------- 5.9 ----------
    function test_balanceOf_triggersPauseWhenCustodianTsChangedAndDeltaExceedsBps() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);

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
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));

        // Custodian updates to 105e6 (+5%, below 10% threshold)
        _custodianConfirm(executor, 105e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertFalse(_readPaused());
    }

    // ---------- 5.11 ----------
    function test_balanceOf_updatesLastCheckedCustodianTimestampEvenIfBelowThreshold() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));

        _custodianConfirm(executor, 101e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        (,, uint256 custTs) = IRWAExecutor(executor).getBalanceFuseSnapshot();
        assertEq(_readLastCheckedCustodianTimestamp(), custTs);
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
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline 100

        // Custodian sets to 10 (-90%)
        _custodianConfirm(executor, 10e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused());
    }

    // ---------- 5.14 ----------
    function test_balanceOf_emitsRWABigChangeDetected() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));

        _custodianConfirm(executor, 300e6);

        vm.expectEmit(false, false, false, true, address(vault));
        emit RWABalanceFuse.RWABigChangeDetected(100e6, 300e6, BIG_CHANGE_BPS);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
    }

    // ---------- 5.15 ----------
    function test_balanceOf_revertsWhenPriceOracleNotSet() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.setPriceOracleMiddleware(address(0));

        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPriceOracleNotSet.selector));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
    }

    // ---------- 5.16 ----------
    function test_balanceOf_handlesDifferentUnderlyingDecimals() public {
        // reconfigure to underlying18
        vault.setUnderlying(address(underlying18));
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 10e18);

        bytes memory ret = vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        uint256 value = abi.decode(ret, (uint256));
        assertEq(value, 10e18); // 10 underlying @ $1 = 10 USD WAD
    }

    // ---------- TQ-11: big-change adversarial scenarios ----------

    /// @notice Repeated balanceOf reads with massive addBalance deltas never trip pause (no custodian update).
    function test_balanceOf_repeatedReadsWithoutCustodianUpdate_neverPause() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        // 10 massive addBalance operations — each doubles balance but no custodian confirm
        for (uint256 i; i < 10; ++i) {
            vm.prank(address(vault));
            IRWAExecutor(executor).addBalance(balanceAccount, 100e6 * (2 ** i));
            vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
            assertFalse(_readPaused(), "pause should not trigger without custodian update");
        }
    }

    /// @notice Once big-change triggers pause, subsequent balanceOf calls do NOT clear the flag.
    function test_balanceOf_pauseOnCustodianUpdate_stickyUntilUnpause() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
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
        IRWAExecutor(executor).addBalance(balanceAccount, 1);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline: prevTotal=1

        _custodianConfirm(executor, 2); // +100%
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "100% change on small values should trigger pause");
    }

    /// @notice prevTotal=100, totalBalance=110 → delta/prev = 1000 bps (10%). At 10% threshold → exact boundary.
    function test_balanceOf_bigChangeMath_exactBoundary_10percent() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
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
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        _custodianConfirm(executor, 111e6); // 11%
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "11% > 10% should trigger pause");
    }

    /// @notice Custodian confirm + balanceOf in the same block: pause is detected.
    function test_balanceOf_custodianUpdateAndReadSameBlock_pauseDetected() public {
        address executor = _setupWithExecutor();
        vm.prank(address(vault));
        IRWAExecutor(executor).addBalance(balanceAccount, 100e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ())); // baseline

        // Same block: custodian confirm + balanceOf
        _custodianConfirm(executor, 250e6); // +150%
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.balanceOf, ()));
        assertTrue(_readPaused(), "big-change must be detected in same block");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _setupWithExecutor() internal returns (address executor) {
        bytes32[] memory subs = new bytes32[](5);
        subs[0] = RWASubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[1] = RWASubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[2] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = RWASubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[4] = RWASubstrateLib.encodeStalenessMaxSubstrate(1 days);
        vault.grantMarketSubstrates(MARKET_ID, subs);

        executor = address(new RWAExecutor(MARKET_ID, address(vault)));
        executor.call(abi.encodeCall(IRWAExecutor.syncSubstrates, ()));
        // Persist executor into ERC-7201 slot of the vault
        RWASlotHelpers.setExecutor(address(vault), executor);
    }

    function _custodianConfirm(address executor_, uint256 newValue_) internal {
        vm.prank(custodianA);
        IRWAExecutor(executor_).proposeBalance(balanceAccount, newValue_);

        // fetch pending
        (,, uint64 pa, uint256 n) = RWAExecutor(executor_).pendingProposals(balanceAccount);
        bytes32 h = keccak256(abi.encode(executor_, block.chainid, balanceAccount, newValue_, custodianA, pa, n));
        vm.prank(custodianB);
        IRWAExecutor(executor_).confirmBalance(balanceAccount, h);
    }

    function _readPaused() internal view returns (bool) {
        return RWASlotHelpers.readPaused(address(vault));
    }

    function _readLastTotalBalance() internal view returns (uint256) {
        bytes32 s =
            bytes32(uint256(RWATestConstants.RWA_SLOT) + RWATestConstants.LAST_TOTAL_BALANCE_SLOT_OFFSET);
        return uint256(vm.load(address(vault), s));
    }

    function _readLastCheckedCustodianTimestamp() internal view returns (uint256) {
        bytes32 s =
            bytes32(uint256(RWATestConstants.RWA_SLOT) + RWATestConstants.LAST_CHECKED_CUSTODIAN_TS_SLOT_OFFSET);
        return uint256(vm.load(address(vault), s));
    }
}
