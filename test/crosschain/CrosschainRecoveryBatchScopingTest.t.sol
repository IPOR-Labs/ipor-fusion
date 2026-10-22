// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FusesLib} from "../../contracts/libraries/FusesLib.sol";
import {PlasmaVaultMarketsLib} from "../../contracts/vaults/lib/PlasmaVaultMarketsLib.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";

import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";

import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {CrosschainRecoveryContextTestLib} from "./mocks/CrosschainRecoveryContextTestLib.sol";

/// @title PlasmaVaultExecuteHarness
/// @notice Minimal stand-in for `PlasmaVault` reproducing the exact shape of `PlasmaVault.execute()` for
///         the CROSSCHAIN market: delegatecall the fuse, then `_updateMarketsBalances(markets)` —
///         which delegatecalls the balance fuse and PERSISTS the returned value into `PlasmaVaultLib`
///         market storage.
/// @dev Deliberately never clears the transient recovery context between batches, exactly like
///      production `PlasmaVault.execute`. That is the property under test: several batches in one
///      transaction must not each re-apply an earlier batch's recovery correction.
contract PlasmaVaultExecuteHarness {
    using Address for address;

    address public immutable UNDERLYING;
    uint256 public immutable UNDERLYING_DECIMALS;
    uint256 public immutable MARKET_ID;

    address public claimFuse;
    address public balanceFuse;

    constructor(address underlying_, uint256 underlyingDecimals_, uint256 marketId_) {
        UNDERLYING = underlying_;
        UNDERLYING_DECIMALS = underlyingDecimals_;
        MARKET_ID = marketId_;
    }

    /// @dev `CrosschainBalanceFuse._cachedBalanceValueUsd` reads `IERC4626(address(this)).asset()`.
    function asset() external view returns (address) {
        return UNDERLYING;
    }

    function setFuses(address claimFuse_, address balanceFuse_) external {
        claimFuse = claimFuse_;
        balanceFuse = balanceFuse_;
        FusesLib.addBalanceFuse(MARKET_ID, balanceFuse_);
    }

    function grantSubstrates(bytes32[] calldata substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(MARKET_ID, substrates_);
    }

    function setPriceOracleMiddleware(address priceOracleMiddleware_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    /// @dev Seeds the persisted market cache a previous successful NAV update would have left behind.
    function seedMarketBalance(uint256 amountInUnderlying_) external {
        PlasmaVaultLib.updateTotalAssetsInMarket(MARKET_ID, amountInUnderlying_);
        PlasmaVaultLib.addToTotalAssetsInAllMarkets(int256(amountInUnderlying_));
    }

    /// @notice One `execute()` batch containing a single claim fuse call.
    function executeClaimBatch(CrosschainClaimFuseEnterData memory data_) external {
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (data_)));
        _refreshBalances();
    }

    /// @notice One `execute()` batch containing TWO claim fuse calls — the cache is persisted once, at
    ///         the end, so both claims must be corrected for against the same cache snapshot.
    function executeDoubleClaimBatch(
        CrosschainClaimFuseEnterData memory first_,
        CrosschainClaimFuseEnterData memory second_
    ) external {
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (first_)));
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (second_)));
        _refreshBalances();
    }

    /// @notice A later batch in the same transaction that refreshes NAV without running any recovery
    ///         fuse (e.g. `updateMarketsBalances`, or an `execute` whose fuses do not mark recovery).
    ///         The transient recovery marker from the earlier batch is still set.
    function refreshBalancesOnly() external {
        _refreshBalances();
    }

    function cachedMarketBalance() external view returns (uint256) {
        return PlasmaVaultLib.getTotalAssetsInMarket(MARKET_ID);
    }

    /// @notice `PlasmaVault.totalAssets()` == idle underlying balance + Σ market values.
    function totalAssets() external view returns (uint256) {
        return IERC20(UNDERLYING).balanceOf(address(this)) + PlasmaVaultLib.getTotalAssetsInAllMarkets();
    }

    /// @notice Models a top-level transaction boundary, using the test-only slot copy.
    function clearRecoveryContext() external {
        CrosschainRecoveryContextTestLib.clearContext(MARKET_ID);
    }

    function _refreshBalances() private {
        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_ID;
        PlasmaVaultMarketsLib.updateMarketsBalances(markets, UNDERLYING, UNDERLYING_DECIMALS, 0);
    }
}

/// @notice Regression tests for the batch scoping of the transient recovery context
///         (`CrosschainRecoveryLib`) consumed by `CrosschainBalanceFuse._cachedBalanceValueUsd`.
///
/// `recoveredUsd` corrects a market cache that is re-persisted at the end of every `execute()` batch,
/// while transient storage lives for the whole transaction. Two batches in one transaction are readily
/// reachable — `CrosschainNavValidationPreHook` returns early for the `execute` selector and ALPHA is
/// commonly a Safe using MultiSend — so the correction has to be rebased per batch, otherwise an earlier
/// batch's recovery is subtracted again from a cache that no longer contains it, and the understated
/// value is persisted (audit: stale_accounting_double_subtraction).
///
/// The invariant every test here asserts: a recovery only MOVES value from the crosschain market into
/// the vault's own balance, so `totalAssets()` must be conserved.
contract CrosschainRecoveryBatchScopingTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;

    uint256 internal constant M0 = 1_000e6; // cached crosschain market value, 1000 USDC
    uint256 internal constant CLAIM_1 = 300e6;
    uint256 internal constant CLAIM_2 = 200e6;

    MockERC20 internal usdc;
    PlasmaVaultExecuteHarness internal vault;
    MockExecutor internal executor;
    MockPriceOracleMiddleware internal oracle;

    CrosschainClaimFuse internal claimFuse;
    CrosschainBalanceFuse internal balanceFuse;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new PlasmaVaultExecuteHarness(address(usdc), 6, MARKET);

        claimFuse = new CrosschainClaimFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(claimFuse), address(balanceFuse));

        executor = new MockExecutor(address(vault), address(usdc)); // MANAGER == vault
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(subs);

        oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8); // $1.00 on an 8-decimal feed
        vault.setPriceOracleMiddleware(address(oracle));

        // The executor physically holds the settled assets and the persisted cache reflects them.
        usdc.mint(address(executor), M0);
        vault.seedMarketBalance(M0);

        // Live NAV is fail-closed for the whole scenario — the documented condition under which the
        // recovery path (recovery fuse + cached NAV) is used.
        executor.setBalanceReverts(true);
    }

    /// @dev H-1 must stay fixed: within a single batch the recovered value is removed from the cache
    ///      exactly once, so it is not counted both in the cache and in the vault's own balance.
    function test_singleBatch_subtractsRecoveredValueExactlyOnce() public {
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}));

        assertEq(usdc.balanceOf(address(vault)), CLAIM_1, "claimed assets are idle in the vault");
        assertEq(vault.cachedMarketBalance(), M0 - CLAIM_1, "cache reduced by exactly the claimed amount");
        assertEq(vault.totalAssets(), M0, "totalAssets conserved");
    }

    /// @dev Two recovery fuse calls inside ONE batch share a single cache snapshot, so both must be
    ///      corrected for. This is what stops the per-batch rebase from degenerating into "only the
    ///      last recovery counts" and reintroducing H-1.
    function test_twoRecoveriesInOneBatch_accumulateAgainstOneCacheSnapshot() public {
        vault.executeDoubleClaimBatch(
            CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}),
            CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_2})
        );

        assertEq(usdc.balanceOf(address(vault)), CLAIM_1 + CLAIM_2, "both claims are idle in the vault");
        assertEq(vault.cachedMarketBalance(), M0 - CLAIM_1 - CLAIM_2, "cache reduced by both claims, once each");
        assertEq(vault.totalAssets(), M0, "totalAssets conserved");
    }

    /// @dev The finding: two `execute()` batches in ONE transaction. The first batch's recovery has
    ///      already been removed from the persisted cache, so it must not be subtracted again.
    function test_twoBatchesInOneTx_doNotSubtractTheFirstRecoveryTwice() public {
        assertEq(vault.totalAssets(), M0, "precondition: totalAssets == cached crosschain NAV");

        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}));

        assertEq(vault.cachedMarketBalance(), M0 - CLAIM_1, "batch1: cache reduced by x");
        assertEq(vault.totalAssets(), M0, "batch1: totalAssets conserved");

        // Same transaction, second batch. `recoveredUsd` is still usd(x) unless it is rebased.
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_2}));

        assertEq(usdc.balanceOf(address(vault)), CLAIM_1 + CLAIM_2, "batch2: both claims are idle in the vault");
        assertEq(
            vault.cachedMarketBalance(),
            M0 - CLAIM_1 - CLAIM_2,
            "batch2: cache must not double-subtract the first claim"
        );
        assertEq(vault.totalAssets(), M0, "batch2: totalAssets conserved");
    }

    /// @dev A later NAV refresh in the same transaction that runs NO recovery fuse still sees
    ///      `isRecovery()` set (transient, transaction-scoped) and takes the cached path. The stale
    ///      accumulator must be ignored entirely — nothing was recovered against the cache it now reads.
    function test_navRefreshAfterRecoveryBatch_ignoresSpentAccumulator() public {
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}));

        uint256 cacheAfterRecovery = vault.cachedMarketBalance();
        assertEq(cacheAfterRecovery, M0 - CLAIM_1, "precondition: cache reduced once");

        vault.refreshBalancesOnly();

        assertEq(vault.cachedMarketBalance(), cacheAfterRecovery, "idempotent: refresh must not re-subtract");
        assertEq(vault.totalAssets(), M0, "totalAssets conserved across the refresh");

        // Repeated refreshes must stay idempotent — the accumulator is not consumed a little at a time.
        vault.refreshBalancesOnly();
        assertEq(vault.cachedMarketBalance(), cacheAfterRecovery, "still idempotent on a second refresh");
        assertEq(vault.totalAssets(), M0, "totalAssets still conserved");
    }

    /// @dev Three batches: the error compounds once per batch if the accumulator is never rebased.
    function test_threeBatchesInOneTx_conserveTotalAssets() public {
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: 100e6}));
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: 100e6}));
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: 100e6}));

        assertEq(usdc.balanceOf(address(vault)), 300e6, "all three claims are idle in the vault");
        assertEq(vault.cachedMarketBalance(), M0 - 300e6, "cache reduced by 3x100, once each");
        assertEq(vault.totalAssets(), M0, "totalAssets conserved across three batches");
    }

    /// @dev `CrosschainRecoveryContextTestLib` duplicates the production library's `private` slot
    ///      constants. If a slot string is ever renamed, that copy would silently become a no-op and
    ///      every harness that models a transaction boundary would quietly stop doing so. Pin it: after
    ///      a real recovery the cached path is live (no revert); after `clearContext()` the recovery
    ///      marker must be gone, so the balance fuse rethrows the executor's fail-closed revert.
    function test_testOnlyClearContext_stillTargetsTheProductionSlots() public {
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}));

        // Recovery marker set: the cached path absorbs the fail-closed executor.
        vault.refreshBalancesOnly();

        vault.clearRecoveryContext();

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.refreshBalancesOnly();
    }

    /// @dev The per-market accumulator and cache snapshot slots must really be cleared: with the cache restored
    ///      to the value the first claim saw, a stale snapshot would keep accumulating (CLAIM_1 + CLAIM_2).
    function test_testOnlyClearContext_clearsPerMarketAccumulatorAndSnapshot() public {
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}));
        vault.clearRecoveryContext();

        // Same cache value as the first claim observed, so a surviving snapshot would match and not rebase.
        vault.seedMarketBalance(M0);
        assertEq(vault.cachedMarketBalance(), M0, "cache restored to the first claim's snapshot");

        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_2}));
        assertEq(vault.cachedMarketBalance(), M0 - CLAIM_2, "second claim subtracts only its own amount");
    }

    /// @dev Happy path unaffected: when live NAV is readable the cached fallback is never taken and the
    ///      recovery accumulator has no influence on the reported value.
    function test_liveBalanceAvailable_ignoresRecoveryAccumulator() public {
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}));

        // The chain unblocks: the executor now reports its true remaining balance.
        executor.setBalanceReverts(false);
        executor.setBalance(M0 - CLAIM_1);

        vault.refreshBalancesOnly();

        assertEq(vault.cachedMarketBalance(), M0 - CLAIM_1, "live balance is used verbatim");
        assertEq(vault.totalAssets(), M0, "totalAssets conserved");
    }

    // ---------------------------------------------------------------------
    // IL-8598: CrosschainRecoveredUsdClamped
    // ---------------------------------------------------------------------

    event CrosschainRecoveredUsdClamped(uint256 marketId, uint256 cachedUsd, uint256 recoveredUsd);

    /// @dev Cached value and recovered value in 18-decimal USD ($1.00 price, 6-decimal underlying).
    function _usd(uint256 amount_) private pure returns (uint256) {
        return amount_ * 1e12;
    }

    function _clampedEventCount() private view returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == CrosschainRecoveredUsdClamped.selector) {
                ++count;
            }
        }
    }

    function testShouldEmitRecoveredUsdClampedAndValueMarketAtZeroWhenClaimExceedsCache() public {
        uint256 overClaim = M0 + 50e6;
        usdc.mint(address(executor), 50e6); // the executor holds more than the cache says

        vm.expectEmit(false, false, false, true, address(vault));
        emit CrosschainRecoveredUsdClamped(MARKET, _usd(M0), _usd(overClaim));
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: overClaim}));

        assertEq(usdc.balanceOf(address(vault)), overClaim, "the whole over-claim is idle in the vault");
        assertEq(vault.cachedMarketBalance(), 0, "market valued at zero, never negative");
    }

    function testShouldNotEmitRecoveredUsdClampedOnPartialClaim() public {
        vm.recordLogs();
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}));

        assertEq(_clampedEventCount(), 0, "partial claim must not emit the clamp event");
        assertEq(vault.cachedMarketBalance(), M0 - CLAIM_1, "market valued at the remainder");
    }

    function testShouldNotEmitRecoveredUsdClampedOnExactFullClaim() public {
        vm.recordLogs();
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: M0}));

        assertEq(_clampedEventCount(), 0, "exact full recovery is not a clamp");
        assertEq(vault.cachedMarketBalance(), 0, "market valued at zero");
        assertEq(vault.totalAssets(), M0, "totalAssets conserved");
    }
}
