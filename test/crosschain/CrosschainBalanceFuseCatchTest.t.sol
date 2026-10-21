// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";

import {PlasmaVaultExecuteHarness} from "./CrosschainRecoveryBatchScopingTest.t.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @dev Exposes the fuse's internal selector constants.
contract CrosschainBalanceFuseSelectorHarness is CrosschainBalanceFuse {
    constructor() CrosschainBalanceFuse(0) {}

    function selectors() external pure returns (bytes4[5] memory s) {
        s = [CHAIN_BLOCKED, OBSERVATION_STALE, TRANSFER_STALE, NAV_SETTLED_STALE, NAV_TRANSFER_STALE];
    }
}

/// @title CrosschainBalanceFuseCatchTest
/// @notice IL-8564 / IL-8638: during a recovery batch the balance fuse may serve the cached market value only
///         for the executors' documented fail-closed reverts. A callee out-of-gas, a `Panic`, an `Error(string)`
///         and an unknown custom error must be rethrown with their original returndata.
contract CrosschainBalanceFuseCatchTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant M0 = 1_000e6;
    uint256 internal constant CLAIM = 300e6;

    error SomethingUnexpected(uint256 value);

    event CrosschainCachedBalanceServed(uint256 marketId, address executor, bytes4 reason);

    MockERC20 internal usdc;
    PlasmaVaultExecuteHarness internal vault;
    MockExecutor internal executor;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new PlasmaVaultExecuteHarness(address(usdc), 6, MARKET);

        CrosschainClaimFuse claimFuse = new CrosschainClaimFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(claimFuse), address(balanceFuse));

        executor = new MockExecutor(address(vault), address(usdc));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(subs);

        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));

        usdc.mint(address(executor), M0);
        vault.seedMarketBalance(M0);
    }

    function _claim() internal {
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM}));
    }

    function _servedEvents() internal view returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == CrosschainCachedBalanceServed.selector) ++count;
        }
    }

    function _assertNothingServed() internal view {
        assertEq(vault.cachedMarketBalance(), M0, "cache untouched: the reverted batch persisted nothing");
        assertEq(usdc.balanceOf(address(vault)), 0, "claim rolled back with the batch");
    }

    function testShouldServeCacheOnFailClosedRevertDuringRecovery() public {
        executor.setBalanceReverts(true); // reverts NavSettledStale(1)

        vm.expectEmit(false, false, false, true, address(vault));
        emit CrosschainCachedBalanceServed(MARKET, address(executor), MockExecutor.NavSettledStale.selector);
        _claim();

        assertEq(vault.cachedMarketBalance(), M0 - CLAIM, "cached value served, net of the claim");
        assertEq(vault.totalAssets(), M0, "totalAssets conserved");
    }

    function testShouldServeCacheOnEveryAllowlistedSelector() public {
        bytes[5] memory reasons = [
            abi.encodeWithSignature("ChainBlocked(uint256)", 1),
            abi.encodeWithSignature("ObservationStale(uint256)", 1),
            abi.encodeWithSignature("TransferStale(uint256,uint256)", 1, 2),
            abi.encodeWithSignature("NavSettledStale(uint256)", 1),
            abi.encodeWithSignature("NavTransferStale(uint256)", 1)
        ];
        for (uint256 i; i < reasons.length; ++i) {
            uint256 snap = vm.snapshotState();
            executor.setFailMode(MockExecutor.FailMode.RAW, reasons[i]);
            vm.expectEmit(false, false, false, true, address(vault));
            emit CrosschainCachedBalanceServed(MARKET, address(executor), bytes4(reasons[i]));
            _claim();
            assertEq(vault.cachedMarketBalance(), M0 - CLAIM, "cache served");
            vm.revertToState(snap);
        }
    }

    function testShouldRethrowOutOfGasDuringRecovery() public {
        executor.setFailMode(MockExecutor.FailMode.OUT_OF_GAS, "");

        vm.recordLogs();
        // The callee burns 63/64 of the gas; the caller keeps 1/64 and must revert instead of serving the cache.
        (bool ok,) = address(vault).call{gas: 15_000_000}(
            abi.encodeCall(
                PlasmaVaultExecuteHarness.executeClaimBatch,
                (CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM}))
            )
        );
        assertFalse(ok, "outer call must revert, not return the cache");
        assertEq(_servedEvents(), 0, "no cached-balance event");
        _assertNothingServed();
    }

    function testShouldRethrowPanicDuringRecovery() public {
        executor.setFailMode(MockExecutor.FailMode.PANIC, "");

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Panic(uint256)")), uint256(0x12)));
        _claim();
        assertEq(_servedEvents(), 0, "no cached-balance event");
        _assertNothingServed();
    }

    function testShouldRethrowUnknownRevertDuringRecovery() public {
        executor.setFailMode(MockExecutor.FailMode.RAW, abi.encodeWithSelector(SomethingUnexpected.selector, uint256(42)));

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(SomethingUnexpected.selector, uint256(42)));
        _claim();
        assertEq(_servedEvents(), 0, "no cached-balance event");
        _assertNothingServed();
    }

    function testShouldRethrowErrorStringDuringRecovery() public {
        executor.setFailMode(MockExecutor.FailMode.ERROR_STRING, "");

        vm.recordLogs();
        vm.expectRevert(bytes("x"));
        _claim();
        assertEq(_servedEvents(), 0, "no cached-balance event");
        _assertNothingServed();
    }

    function testShouldRethrowShortReturndataDuringRecovery() public {
        executor.setFailMode(MockExecutor.FailMode.RAW, hex"aabbcc");

        vm.recordLogs();
        vm.expectRevert(bytes(hex"aabbcc"));
        _claim();
        assertEq(_servedEvents(), 0, "no cached-balance event");
        _assertNothingServed();
    }

    function testShouldKeepSelectorConstantsInSyncWithExecutorErrors() public {
        bytes4[5] memory s = new CrosschainBalanceFuseSelectorHarness().selectors();
        assertEq(s[0], CcipExecutorTransferLib.ChainBlocked.selector, "CCIP ChainBlocked");
        assertEq(s[0], CrosschainErrors.ChainBlocked.selector, "Stargate ChainBlocked");
        assertEq(s[1], CcipExecutorTransferLib.ObservationStale.selector, "ObservationStale");
        assertEq(s[2], CcipExecutorTransferLib.TransferStale.selector, "TransferStale");
        assertEq(s[3], CrosschainErrors.NavSettledStale.selector, "NavSettledStale");
        assertEq(s[4], CrosschainErrors.NavTransferStale.selector, "NavTransferStale");
    }
}
