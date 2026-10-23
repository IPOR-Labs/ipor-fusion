// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {
    HyperCorePendingActionPreHook
} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCorePendingActionPreHook.sol";
import {
    HyperCoreCapitalFlowPreHook
} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCoreCapitalFlowPreHook.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {HyperCoreMockState, MockHyperCorePrecompiles} from "./mocks/MockHyperCorePrecompiles.sol";
import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";

contract HyperCorePendingLibHarness {
    event HyperCoreActionSettled(uint256 nonce);
    event HyperCoreActionEnqueued(
        uint256 nonce, uint8 actionClass, uint8 settlementMode, uint64 pendingUntil,
        uint256 cachedValueWad, uint64 enqueuedL1Block, uint64 enqueuedEvmBlock,
        uint24 actionId, bytes32 payloadHash
    );
    function enqueue(uint256 value_, uint64 window_, uint24 actionId_, bytes32 payloadHash_) external {
        HyperCorePendingLib.enqueue(value_, window_, actionId_, payloadHash_);
    }

    /// @dev Writes a record the way a pre-IL-8543 build left it for a REPORTED order (deprecated fields set).
    function seedLegacyReportedOrderRecord(uint64 pendingUntil_) external {
        HyperCorePendingLib.PendingAction storage p = HyperCorePendingLib.get();
        p.pendingUntil = pendingUntil_;
        p.actionClass = uint8(HyperCorePendingLib.ActionClass.Order);
        p.deprecatedSettlementMode = 2;
        p.deprecatedReportedResult = 1;
        p.deprecatedResultL1Block = 7;
        p.deprecatedRefreshing = true;
        p.cachedValueWad = 5e18;
        p.actionNonce = 3;
    }

    function legacyFields() external view returns (uint8 mode, uint8 result, uint64 resultL1Block, bool refreshing) {
        HyperCorePendingLib.PendingAction storage p = HyperCorePendingLib.get();
        return (p.deprecatedSettlementMode, p.deprecatedReportedResult, p.deprecatedResultL1Block, p.deprecatedRefreshing);
    }

    function isActionPending() external view returns (bool) {
        return HyperCorePendingLib.isActionPending();
    }

    function isActionSettled() external view returns (bool) {
        return HyperCorePendingLib.isActionSettled();
    }

    function cachedValue() external view returns (uint256) {
        return HyperCorePendingLib.cachedValueWad();
    }

    function clear() external {
        HyperCorePendingLib.clear();
    }

    function settleIfReady() external returns (bool) {
        return HyperCorePendingLib.settleIfReady();
    }

    function nonce() external view returns (uint256) {
        return HyperCorePendingLib.get().actionNonce;
    }

    function recordTimingOrder() external {
        HyperCorePendingLib.recordTimingOrder();
    }

    function isOrderInFlight() external view returns (bool) {
        return HyperCorePendingLib.isOrderInFlight();
    }

    function requireNoOrderInFlight() external view {
        HyperCorePendingLib.requireNoOrderInFlight();
    }

    function requireOrderRateLimit() external view {
        HyperCorePendingLib.requireOrderRateLimit();
    }

    function lastOrderL1Block() external view returns (uint64) {
        return HyperCorePendingLib.get().lastOrderL1Block;
    }

    function runPreHook(address hook_, bytes4 selector_) external {
        (bool success, bytes memory returndata) =
            hook_.delegatecall(abi.encodeWithSelector(HyperCorePendingActionPreHook.run.selector, selector_));
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

contract HyperCoreCapitalFlowHookHarness {
    uint256 public refreshCalls;
    uint256 public lastMarketId;

    function runPreHook(address hook_, bytes4 selector_) external {
        (bool success, bytes memory returndata) =
            hook_.delegatecall(abi.encodeWithSelector(HyperCoreCapitalFlowPreHook.run.selector, selector_));
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

    function updateMarketsBalances(uint256[] calldata marketIds_) external returns (uint256) {
        refreshCalls++;
        lastMarketId = marketIds_[0];
        return 1;
    }

    function recordTimingOrder() external {
        HyperCorePendingLib.recordTimingOrder();
    }

    function enqueuePending() external {
        HyperCorePendingLib.enqueue(5, 100, 7, keccak256("pending transfer"));
    }
}

contract HyperCorePendingLibTest is Test {
    uint8 private constant TRANSFER = 1;

    HyperCoreMockState private _state;
    HyperCorePendingLibHarness private _harness;
    HyperCoreCapitalFlowHookHarness private _capitalFlowHarness;

    function setUp() public {
        _state = new HyperCoreMockState();
        MockHyperCorePrecompiles implementation = new MockHyperCorePrecompiles();
        bytes32 stateWord = bytes32(uint256(uint160(address(_state))));

        address l1BlockPrecompile = address(0x809);
        vm.etch(l1BlockPrecompile, address(implementation).code);
        vm.store(l1BlockPrecompile, bytes32(0), stateWord);

        // the capital-flow hook's IL-8534 band check reads coreUserExists (0x810): no Core account, no-op
        vm.mockCall(address(0x810), bytes(""), abi.encode(false));

        _state.setL1BlockNumber(100);
        _harness = new HyperCorePendingLibHarness();
        _capitalFlowHarness = new HyperCoreCapitalFlowHookHarness();
    }

    function testTimingActionRequiresWindowAndLaterL1Block() public {
        _harness.enqueue(123e18, 20, 0, bytes32(uint256(1)));
        assertTrue(_harness.isActionPending());
        assertFalse(_harness.isActionSettled());
        assertEq(_harness.cachedValue(), 123e18);

        vm.warp(block.timestamp + 20);
        assertFalse(_harness.isActionSettled(), "time alone must not settle");

        _state.setL1BlockNumber(101);
        assertTrue(_harness.isActionSettled());
        assertFalse(_harness.isActionPending());
        _harness.clear();
        assertFalse(_harness.isActionPending());
        assertEq(_harness.nonce(), 1);
    }

    // ------------------------------------------------------------------
    // settleIfReady (latch used by the pre-hooks)
    // ------------------------------------------------------------------
    function testSettleIfReadyReturnsFalseWhenNoRecord() public {
        assertFalse(_harness.settleIfReady());
        assertEq(_harness.nonce(), 0);
    }

    function testSettleIfReadyReturnsFalseWhileNotSettledAndKeepsRecord() public {
        _harness.enqueue(123e18, 20, 0, bytes32(uint256(1)));
        assertFalse(_harness.settleIfReady());
        vm.warp(block.timestamp + 20);
        assertFalse(_harness.settleIfReady(), "L1 block has not advanced");
        assertTrue(_harness.isActionPending());
        assertEq(_harness.cachedValue(), 123e18);
    }

    function testSettleIfReadyClearsSettledRecordEmitsOnceAndPreservesNonceAndOrderGate() public {
        _harness.recordTimingOrder();
        _harness.enqueue(123e18, 20, 0, bytes32(uint256(1)));
        vm.warp(block.timestamp + 20);
        _state.setL1BlockNumber(101);

        vm.expectEmit(false, false, false, true, address(_harness));
        emit HyperCorePendingLibHarness.HyperCoreActionSettled(1);
        assertTrue(_harness.settleIfReady());

        assertFalse(_harness.isActionPending());
        assertEq(_harness.cachedValue(), 0);
        assertEq(_harness.nonce(), 1);
        assertEq(_harness.lastOrderL1Block(), 100, "order gate preserved");

        vm.recordLogs();
        assertFalse(_harness.settleIfReady(), "second call is a no-op");
        assertEq(vm.getRecordedLogs().length, 0, "no second event");

        _harness.enqueue(1, 20, 0, bytes32(uint256(2)));
        assertEq(_harness.nonce(), 2);
    }

    function testEnqueueEventShapeIsUnchangedAndAlwaysTransferClassWithModeZero() public {
        bytes32 payloadHash = keccak256("identity");
        uint64 pendingUntil = uint64(block.timestamp + 20);
        vm.expectEmit(false, false, false, true, address(_harness));
        emit HyperCorePendingLibHarness.HyperCoreActionEnqueued(
            1, TRANSFER, 0, pendingUntil, 123e18, 100, uint64(block.number), 41, payloadHash
        );
        _harness.enqueue(123e18, 20, 41, payloadHash);
    }

    function testSecondActionRevertsWhilePending() public {
        _harness.enqueue(5, 100, 0, bytes32(uint256(1)));

        vm.expectRevert(
            abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, uint64(block.timestamp + 100))
        );
        _harness.enqueue(6, 100, 0, bytes32(uint256(2)));
    }

    /// @dev IL-8543: the pre-hook has no caller exception; execute and updateMarketsBalances revert for every
    ///      caller (including the address the removed reporter would have used) while a transfer is pending, and the
    ///      wrong-selector check (IL-8529) still applies.
    function testPendingActionHookBlocksEveryCallerWhilePending() public {
        HyperCorePendingActionPreHook hook = new HyperCorePendingActionPreHook();
        _harness.enqueue(5, 100, 1, keccak256("transfer"));
        bytes memory pendingErr =
            abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, uint64(block.timestamp + 100));

        address[3] memory callers = [address(this), makeAddr("alpha"), makeAddr("formerReporter")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(pendingErr);
            _harness.runPreHook(address(hook), PlasmaVault.execute.selector);

            vm.prank(callers[i]);
            vm.expectRevert(pendingErr);
            _harness.runPreHook(address(hook), PlasmaVault.updateMarketsBalances.selector);
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCorePendingActionPreHook.HyperCorePreHookWrongSelector.selector,
                PlasmaVault.deposit.selector
            )
        );
        _harness.runPreHook(address(hook), PlasmaVault.deposit.selector);

        // Once the transfer settles the hook latches it (settleIfReady) and lets the call through.
        vm.warp(block.timestamp + 100);
        _state.setL1BlockNumber(101);
        _harness.runPreHook(address(hook), PlasmaVault.execute.selector);
        assertFalse(_harness.isActionPending());
    }

    /// @dev Storage compatibility: a record left by a pre-IL-8543 build for a REPORTED order (deprecated fields set,
    ///      nonce 3) is no longer special. It settles by timing and `settleIfReady` wipes the deprecated fields.
    function testLegacyReportedOrderRecordSettlesByTimingAndClearsDeprecatedFields() public {
        uint64 until = uint64(block.timestamp + 20);
        _harness.seedLegacyReportedOrderRecord(until);
        assertTrue(_harness.isActionPending(), "legacy record is pending inside its window");

        vm.warp(until);
        _state.setL1BlockNumber(101);
        assertTrue(_harness.isActionSettled(), "no report is required any more");
        assertTrue(_harness.settleIfReady());
        (uint8 mode, uint8 result, uint64 resultL1Block, bool refreshing) = _harness.legacyFields();
        assertEq(mode, 0);
        assertEq(result, 0);
        assertEq(resultL1Block, 0);
        assertFalse(refreshing);
        assertEq(_harness.nonce(), 3, "nonce is preserved");
    }

    function testTimingOrderMiniGateLastsOneCoreBlock() public {
        assertFalse(_harness.isOrderInFlight(), "no order yet");
        _harness.requireNoOrderInFlight();
        _harness.requireOrderRateLimit();

        _harness.recordTimingOrder();
        assertEq(_harness.lastOrderL1Block(), 100);
        assertTrue(_harness.isOrderInFlight());
        assertFalse(_harness.isActionPending(), "mini-gate is separate from the record-based pending predicate");
        assertTrue(_harness.isActionSettled());

        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreOrderInFlight.selector, uint64(100)));
        _harness.requireNoOrderInFlight();
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreOrderRateLimited.selector, uint64(100)));
        _harness.requireOrderRateLimit();

        _state.setL1BlockNumber(101);
        assertFalse(_harness.isOrderInFlight());
        _harness.requireNoOrderInFlight();
        _harness.requireOrderRateLimit();
        assertEq(_harness.lastOrderL1Block(), 100, "value is kept until the next order");
    }

    function testLastOrderL1BlockPersistsAcrossEnqueueAndClear() public {
        _harness.recordTimingOrder();
        _state.setL1BlockNumber(101);

        _harness.enqueue(1, 1, 7, keccak256("t"));
        assertEq(_harness.lastOrderL1Block(), 100, "enqueue keeps it");
        vm.warp(block.timestamp + 1);
        _state.setL1BlockNumber(102);
        _harness.clear();
        assertEq(_harness.lastOrderL1Block(), 100, "clear keeps it");

        _harness.enqueue(1, 1, 1, keccak256("second"));
        assertEq(_harness.lastOrderL1Block(), 100, "second enqueue keeps it");
    }

    function testCapitalFlowHookBlocksWhileTimingOrderInFlight() public {
        HyperCoreCapitalFlowPreHook hook = new HyperCoreCapitalFlowPreHook();
        _capitalFlowHarness.recordTimingOrder();
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreOrderInFlight.selector, uint64(100)));
        _capitalFlowHarness.runPreHook(address(hook), PlasmaVault.deposit.selector);
        assertEq(_capitalFlowHarness.refreshCalls(), 0);

        _state.setL1BlockNumber(101);
        _capitalFlowHarness.runPreHook(address(hook), PlasmaVault.deposit.selector);
        assertEq(_capitalFlowHarness.refreshCalls(), 1);
    }

    function testPendingActionHookIgnoresMiniGate() public {
        HyperCorePendingActionPreHook hook = new HyperCorePendingActionPreHook();
        _harness.recordTimingOrder();
        _harness.runPreHook(address(hook), PlasmaVault.execute.selector);
    }

    function testCapitalFlowHookGuardsAndRefreshesOnlyHyperCoreMarket() public {
        HyperCoreCapitalFlowPreHook hook = new HyperCoreCapitalFlowPreHook();
        _capitalFlowHarness.runPreHook(address(hook), PlasmaVault.deposit.selector);
        assertEq(_capitalFlowHarness.refreshCalls(), 1);
        assertEq(_capitalFlowHarness.lastMarketId(), 55);

        _capitalFlowHarness.enqueuePending();
        vm.expectRevert(
            abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, uint64(block.timestamp + 100))
        );
        _capitalFlowHarness.runPreHook(address(hook), PlasmaVault.deposit.selector);
        assertEq(_capitalFlowHarness.refreshCalls(), 1, "pending guard runs before refresh");
    }
}

/// @dev Harness exposing the effect-bound enqueue entry point and the appended struct fields.
contract HyperCorePendingEffectHarness {
    function enqueue(uint256 value_, uint64 window_, bytes32 payloadHash_) external {
        HyperCorePendingLib.enqueue(value_, window_, 7, payloadHash_);
    }

    function enqueueWithEffect(
        uint256 value_,
        uint64 window_,
        uint8 effectKind_,
        uint64 tokenIndex_,
        address evmAsset_,
        uint256 expectedBalance_,
        uint64 timeout_
    ) external {
        HyperCorePendingLib.enqueueTransferWithEffect(
            value_, window_, 7, keccak256("effect"), effectKind_, tokenIndex_, evmAsset_, expectedBalance_, timeout_
        );
    }

    function isActionPending() external view returns (bool) {
        return HyperCorePendingLib.isActionPending();
    }

    function isActionSettled() external view returns (bool) {
        return HyperCorePendingLib.isActionSettled();
    }

    function isEffectObserved() external view returns (bool) {
        return HyperCorePendingLib.isEffectObserved();
    }

    function clear() external {
        HyperCorePendingLib.clear();
    }

    function settleIfReady() external returns (bool) {
        return HyperCorePendingLib.settleIfReady();
    }

    function runPreHook(address hook_, bytes4 selector_) external {
        (bool success, bytes memory returndata) = hook_.delegatecall(
            abi.encodeWithSelector(HyperCorePendingActionPreHook.run.selector, selector_)
        );
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

    function effect()
        external
        view
        returns (uint8 kind, uint64 tokenIndex, address evmAsset, uint64 timeoutAt, uint256 expectedBalance)
    {
        HyperCorePendingLib.PendingAction storage p = HyperCorePendingLib.get();
        return (p.effectKind, p.effectTokenIndex, p.effectEvmAsset, p.timeoutAt, p.expectedBalance);
    }

    function pendingUntil() external view returns (uint64) {
        return HyperCorePendingLib.get().pendingUntil;
    }
}

contract HyperCorePendingLibEffectTest is Test {
    HyperCoreMockState private _core;
    HyperCorePendingEffectHarness private _h;
    HyperCoreMockUsdc private _usdc;

    function setUp() public {
        _core = HyperCoreTestHelper.etchPrecompiles(vm);
        _core.setL1BlockNumber(100);
        _h = new HyperCorePendingEffectHarness();
        _usdc = new HyperCoreMockUsdc();
    }

    function _openGate() private {
        vm.warp(block.timestamp + 21);
        _core.setL1BlockNumber(_core.getL1BlockNumber() + 1);
    }

    function _setSpot(uint64 total_) private {
        _core.setCoreUserExists(address(_h), true);
        _core.setSpotBalance(address(_h), 0, HyperCoreMockState.SpotBalance({total: total_, hold: 0, entryNtl: 0}));
    }

    function testCoreSpotEffectMissingStaysPendingAfterWindowAndL1Block() public {
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 500e8, 600);
        vm.warp(block.timestamp + 20);
        _core.setL1BlockNumber(101);
        assertTrue(_h.isActionPending(), "window + L1 block alone must not settle");
        assertFalse(_h.isActionSettled());
        assertFalse(_h.isEffectObserved());
    }

    function testCoreSpotAccountMissingIsNotObservedEvenWithBalance() public {
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 500e8, 600);
        _core.setSpotBalance(address(_h), 0, HyperCoreMockState.SpotBalance({total: 900e8, hold: 0, entryNtl: 0}));
        vm.warp(block.timestamp + 20);
        _core.setL1BlockNumber(101);
        assertFalse(_h.isEffectObserved());
        assertTrue(_h.isActionPending());
    }

    function testCoreSpotEffectBelowExpectedStaysPendingThenLandsSettles() public {
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 500e8, 600);
        vm.warp(block.timestamp + 20);
        _core.setL1BlockNumber(101);
        _setSpot(500e8 - 1);
        assertTrue(_h.isActionPending(), "one wei short is still pending");
        _setSpot(500e8);
        assertFalse(_h.isActionPending(), "credit landed");
        assertTrue(_h.isActionSettled());
        _h.clear();
        (uint8 kind,,,,) = _h.effect();
        assertEq(kind, 0, "clear wipes the effect");
    }

    function testEffectLandedBeforeWindowStillWaitsForWindowAndL1Block() public {
        _setSpot(500e8);
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 500e8, 600);
        assertTrue(_h.isEffectObserved());
        assertTrue(_h.isActionPending(), "time + L1 gates still apply");
        vm.warp(block.timestamp + 20);
        assertTrue(_h.isActionPending(), "L1 gate still applies");
        _core.setL1BlockNumber(101);
        assertFalse(_h.isActionPending());
    }

    function testEvmBalanceEffect() public {
        _h.enqueueWithEffect(1e18, 20, 2, 0, address(_usdc), 100e6, 600);
        vm.warp(block.timestamp + 20);
        _core.setL1BlockNumber(101);
        assertTrue(_h.isActionPending());
        _usdc.mint(address(_h), 100e6 - 1);
        assertTrue(_h.isActionPending());
        _usdc.mint(address(_h), 1);
        assertFalse(_h.isActionPending());
    }

    function testTimeoutSettlesWithoutEffect() public {
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 500e8, 600);
        uint64 until = _h.pendingUntil();
        _core.setL1BlockNumber(101);
        vm.warp(until + 599);
        assertTrue(_h.isActionPending(), "one second before the timeout");
        vm.warp(until + 600);
        assertFalse(_h.isActionPending(), "timeout opens the gate");
        assertFalse(_h.isEffectObserved());
        _h.clear();
    }

    function _armRevertingEvmEffect() private returns (uint64 until_) {
        _h.enqueueWithEffect(1e18, 20, 2, 0, address(_usdc), 100e6, 600);
        until_ = _h.pendingUntil();
        _core.setL1BlockNumber(101);
        vm.mockCallRevert(
            address(_usdc),
            abi.encodeWithSelector(_usdc.balanceOf.selector, address(_h)),
            bytes("BALANCE_OF_REVERTS")
        );
    }

    function testEvmBalanceEffectWithRevertingTokenOpensAtTimeout() public {
        uint64 until = _armRevertingEvmEffect();

        vm.warp(until + 599);
        vm.expectRevert(bytes("BALANCE_OF_REVERTS"));
        _h.isActionSettled();

        vm.warp(until + 600);
        assertTrue(_h.isActionSettled(), "timeout opens the gate without reading the effect");
        assertFalse(_h.isActionPending());
        assertTrue(_h.settleIfReady());
        (uint8 kind, , , , ) = _h.effect();
        assertEq(kind, 0, "record cleared");
    }

    function testCoreSpotEffectWithFailingSpotPrecompileOpensAtTimeout() public {
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 500e8, 600);
        uint64 until = _h.pendingUntil();
        _setSpot(0);
        _core.setL1BlockNumber(101);
        // 0x801 returns empty data: HyperCoreLib._staticRead reverts with HyperCorePrecompileFailed(0x801)
        vm.etch(address(0x801), "");

        vm.warp(until + 599);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, address(0x801)));
        _h.isActionSettled();
        vm.expectRevert(abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, address(0x801)));
        _h.settleIfReady();

        vm.warp(until + 600);
        assertTrue(_h.isActionSettled(), "timeout opens the gate without reading the Core spot effect");
        assertTrue(_h.settleIfReady());
        (uint8 kind, , , , ) = _h.effect();
        assertEq(kind, 0, "record cleared");
    }

    function testPendingActionHookLatchesTimedOutBridgeWithRevertingEffectToken() public {
        uint64 until = _armRevertingEvmEffect();
        HyperCorePendingActionPreHook hook = new HyperCorePendingActionPreHook();

        vm.warp(until + 599);
        vm.expectRevert(bytes("BALANCE_OF_REVERTS"));
        _h.runPreHook(address(hook), PlasmaVault.execute.selector);

        vm.warp(until + 600);
        _h.runPreHook(address(hook), PlasmaVault.execute.selector);
        assertEq(_h.pendingUntil(), 0, "record cleared by the hook");
    }

    function testTimeoutStillRequiresL1BlockAdvance() public {
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 500e8, 600);
        vm.warp(_h.pendingUntil() + 10_000);
        assertTrue(_h.isActionPending(), "L1 block has not advanced");
    }

    function testEffectFieldsStoredAndTimeoutAtDerivedFromPendingUntil() public {
        _h.enqueueWithEffect(1e18, 20, 2, 3, address(_usdc), 77, 600);
        (uint8 kind, uint64 tokenIndex, address asset, uint64 timeoutAt, uint256 expected) = _h.effect();
        assertEq(kind, 2);
        assertEq(tokenIndex, 3);
        assertEq(asset, address(_usdc));
        assertEq(timeoutAt, _h.pendingUntil() + 600);
        assertEq(expected, 77);
    }

    function testPlainEnqueueResetsPreviousEffect() public {
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(_usdc), 500e8, 600);
        _setSpot(500e8);
        _openGate();
        _h.clear();
        _h.enqueue(1e18, 20, keccak256("plain"));
        (uint8 kind, uint64 tokenIndex, address asset, uint64 timeoutAt, uint256 expected) = _h.effect();
        assertEq(kind, 0);
        assertEq(tokenIndex, 0);
        assertEq(asset, address(0));
        assertEq(timeoutAt, 0);
        assertEq(expected, 0);
    }

    function testPlainEnqueueEnqueuedOverStaleEffectDoesNotInherit() public {
        // Effect record left behind (settled but not cleared) must not leak into the next plain action.
        _h.enqueueWithEffect(1e18, 20, 2, 0, address(_usdc), 1e6, 600);
        _usdc.mint(address(_h), 1e6);
        _openGate();
        assertFalse(_h.isActionPending());
        _h.enqueue(1e18, 20, keccak256("plain"));
        (uint8 kind,,,,) = _h.effect();
        assertEq(kind, 0);
        vm.warp(block.timestamp + 20);
        _core.setL1BlockNumber(_core.getL1BlockNumber() + 1);
        assertFalse(_h.isActionPending(), "plain transfer settles by time alone");
    }

    function testNonEffectTransferUnchanged() public {
        _h.enqueue(1e18, 20, keccak256("plain"));
        vm.warp(block.timestamp + 20);
        assertTrue(_h.isActionPending());
        _core.setL1BlockNumber(101);
        assertFalse(_h.isActionPending());
        assertFalse(_h.isEffectObserved());
    }

    function testTimeoutOverflowReverts() public {
        vm.expectRevert(HyperCorePendingLib.HyperCorePendingWindowOverflow.selector);
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 1, type(uint64).max);
    }

    function testInvalidEffectKindReverts() public {
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCorePendingEffectInvalid.selector, uint8(0)));
        _h.enqueueWithEffect(1e18, 20, 0, 0, address(0), 1, 600);
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCorePendingEffectInvalid.selector, uint8(3)));
        _h.enqueueWithEffect(1e18, 20, 3, 0, address(0), 1, 600);
    }
}
