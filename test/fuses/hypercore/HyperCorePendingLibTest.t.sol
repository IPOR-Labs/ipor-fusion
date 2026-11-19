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
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {VestingData} from "../../../contracts/interfaces/IRewardsClaimManager.sol";
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
    /// @dev Ordinary slot 0, independent of the namespaced pending slot.
    address public asset;

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

    function bindRewardsEffect(
        address rewardsManager_,
        uint256 rawSum_,
        uint256 vestedSum_,
        VestingData memory vesting_
    ) external {
        HyperCorePendingLib.bindRewardsEffect(rewardsManager_, rawSum_, vestedSum_, vesting_);
    }

    /// @dev Vault-side rewards manager address (`PlasmaVaultLib`), read by the gate to detect a manager change.
    function setRewardsClaimManager(address rewardsManager_) external {
        PlasmaVaultLib.setRewardsClaimManagerAddress(rewardsManager_);
    }

    /// @dev Stands in for `IERC4626.asset()` of the vault (read for an unbound record while a manager is set).
    function setAsset(address asset_) external {
        asset = asset_;
    }

    function rewardsVesting()
        external
        view
        returns (uint32 updateBalanceTimestamp, uint128 transferredTokens, uint128 lastUpdateBalance)
    {
        HyperCorePendingLib.PendingAction storage p = HyperCorePendingLib.get();
        return (
            p.effectRewardsUpdateBalanceTimestamp,
            p.effectRewardsTransferredTokens,
            p.effectRewardsLastUpdateBalance
        );
    }

    function recordTimingOrder() external {
        HyperCorePendingLib.recordTimingOrder();
    }

    function lastOrderL1Block() external view returns (uint64) {
        return HyperCorePendingLib.get().lastOrderL1Block;
    }

    function rewardsFields() external view returns (address manager, uint256 rawSum, uint256 vestedSum) {
        HyperCorePendingLib.PendingAction storage p = HyperCorePendingLib.get();
        return (p.effectRewardsManager, p.expectedRewardsRawSum, p.expectedRewardsVestedSum);
    }
}

/// @dev Rewards manager stand-in: only the views the pending lib reads (`balanceOf()`, `getVestingData()`), each of
///      which can be made to revert. Its raw token balance is set with `deal`.
contract HyperCorePendingLibMockRewardsManager {
    error HyperCorePendingLibMockRewardsManagerReverted();

    uint256 public vested;
    VestingData private _vesting;
    bool public revertBalanceOf;
    bool public revertVestingData;

    function setVested(uint256 vested_) external {
        vested = vested_;
    }

    function setVestingData(VestingData memory vesting_) external {
        _vesting = vesting_;
    }

    function setReverts(bool balanceOf_, bool vestingData_) external {
        revertBalanceOf = balanceOf_;
        revertVestingData = vestingData_;
    }

    function balanceOf() external view returns (uint256) {
        if (revertBalanceOf) revert HyperCorePendingLibMockRewardsManagerReverted();
        return vested;
    }

    function getVestingData() external view returns (VestingData memory) {
        if (revertVestingData) revert HyperCorePendingLibMockRewardsManagerReverted();
        return _vesting;
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

/// @notice IL-9529: the rewards-manager binding of an `EFFECT_EVM_BALANCE` record (push counter, anchor, manager, the two
///         D-004 sums) and the reset of the binding.
/// @dev Scenario numbers: vault holds 1000, the manager holds 500 raw / 400 vested, the bridge credits A = 100, so the
///      thresholds are expectedBalance 1100, rawSum 1000 + 500 + 100 = 1600, vestedSum 1000 + 400 + 100 = 1500. The
///      manager's vesting data at send: anchor 77, transferredTokens 30, lastUpdateBalance 600 (`_vesting0`). The
///      harness stands in for the vault: its `PlasmaVaultLib` rewards manager is `_rcm` and its `asset()` is `_usdc`.
contract HyperCorePendingLibRewardsTest is Test {
    uint256 private constant V0 = 1000;
    uint256 private constant MANAGER_RAW = 500;
    uint256 private constant MANAGER_VESTED = 400;
    uint256 private constant A = 100;
    uint32 private constant ANCHOR = 77;
    uint128 private constant TRANSFERRED0 = 30;
    uint128 private constant LAST_UPDATE_BALANCE = 600;
    uint256 private constant PENDING_BASE_SLOT =
        uint256(0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200);

    HyperCoreMockState private _core;
    HyperCorePendingEffectHarness private _h;
    HyperCoreMockUsdc private _usdc;
    HyperCorePendingLibMockRewardsManager private _rcm;

    function setUp() public {
        _core = HyperCoreTestHelper.etchPrecompiles(vm);
        _core.setL1BlockNumber(100);
        _h = new HyperCorePendingEffectHarness();
        _usdc = new HyperCoreMockUsdc();
        _rcm = new HyperCorePendingLibMockRewardsManager();
        _h.setRewardsClaimManager(address(_rcm));
        _h.setAsset(address(_usdc));
        _setBalances(V0, MANAGER_RAW, MANAGER_VESTED);
        _rcm.setVestingData(_vesting0());
    }

    function _vesting0() private pure returns (VestingData memory) {
        return
            VestingData({
                vestingTime: 1000,
                updateBalanceTimestamp: ANCHOR,
                transferredTokens: TRANSFERRED0,
                lastUpdateBalance: LAST_UPDATE_BALANCE
            });
    }

    /// @dev The manager's vesting data after `pushed_` more was pushed (no re-anchor).
    function _vestingAfterPush(uint128 pushed_) private pure returns (VestingData memory vesting_) {
        vesting_ = _vesting0();
        vesting_.transferredTokens = TRANSFERRED0 + pushed_;
    }

    function _setBalances(uint256 vault_, uint256 managerRaw_, uint256 managerVested_) private {
        deal(address(_usdc), address(_h), vault_);
        deal(address(_usdc), address(_rcm), managerRaw_);
        _rcm.setVested(managerVested_);
    }

    function _enqueueBound() private {
        _h.enqueueWithEffect(1e18, 20, 2, 0, address(_usdc), V0 + A, 600);
        _h.bindRewardsEffect(address(_rcm), V0 + MANAGER_RAW + A, V0 + MANAGER_VESTED + A, _vesting0());
    }

    function _openGate() private {
        vm.warp(block.timestamp + 20);
        _core.setL1BlockNumber(_core.getL1BlockNumber() + 1);
    }

    /// @dev Moves to `timeoutAt` with a later L1 block, so the timing gates hold and the effect is waived.
    function _reachTimeout() private {
        (, , , uint64 timeoutAt, ) = _h.effect();
        vm.warp(timeoutAt);
        _core.setL1BlockNumber(_core.getL1BlockNumber() + 1);
    }

    function _slot(uint256 index_) private view returns (bytes32) {
        return vm.load(address(_h), bytes32(PENDING_BASE_SLOT + index_));
    }

    function _assertBindingCleared(string memory where_) private view {
        (address manager, uint256 rawSum, uint256 vestedSum) = _h.rewardsFields();
        (uint32 anchor, uint128 transferred, uint128 last) = _h.rewardsVesting();
        assertEq(manager, address(0), where_);
        assertEq(rawSum, 0, where_);
        assertEq(vestedSum, 0, where_);
        assertEq(anchor, 0, where_);
        assertEq(transferred, 0, where_);
        assertEq(last, 0, where_);
        assertEq(_slot(9), bytes32(uint256(_h.lastOrderL1Block())), "slot 9 keeps only lastOrderL1Block");
        assertEq(_slot(10), bytes32(0), "slot 10 cleared");
        assertEq(_slot(11), bytes32(0), "slot 11 cleared");
        assertEq(_slot(12), bytes32(0), "slot 12 cleared");
    }

    function testBindStoresManagerSumsAndVestingSnapshotInSlots9To12() public {
        _h.recordTimingOrder();
        _enqueueBound();
        (address manager, uint256 rawSum, uint256 vestedSum) = _h.rewardsFields();
        assertEq(manager, address(_rcm));
        assertEq(rawSum, 1600);
        assertEq(vestedSum, 1500);
        (uint32 anchor, uint128 transferred, uint128 last) = _h.rewardsVesting();
        assertEq(anchor, ANCHOR);
        assertEq(transferred, TRANSFERRED0);
        assertEq(last, LAST_UPDATE_BALANCE);
        assertEq(
            _slot(9),
            bytes32((uint256(ANCHOR) << 224) | (uint256(uint160(address(_rcm))) << 64) | 100),
            "slot 9: lastOrderL1Block + manager + updateBalanceTimestamp"
        );
        assertEq(_slot(10), bytes32(uint256(1600)));
        assertEq(_slot(11), bytes32(uint256(1500)));
        assertEq(
            _slot(12),
            bytes32((uint256(LAST_UPDATE_BALANCE) << 128) | uint256(TRANSFERRED0)),
            "slot 12: transferredTokens + lastUpdateBalance"
        );
    }

    function testBindRevertsForNonEvmBalanceRecord() public {
        _h.enqueue(1e18, 20, keccak256("plain"));
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCorePendingEffectInvalid.selector, uint8(0)));
        _h.bindRewardsEffect(address(_rcm), 1, 1, _vesting0());

        _openGate();
        _h.clear();
        _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 1, 600);
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCorePendingEffectInvalid.selector, uint8(1)));
        _h.bindRewardsEffect(address(_rcm), 1, 1, _vesting0());
    }

    /// @dev The bridge credit raises only the vault balance: every condition holds.
    function testCreditSatisfiesBothSums() public {
        _enqueueBound();
        _openGate();
        assertTrue(_h.isActionPending(), "credit not landed");
        _setBalances(V0 + A, MANAGER_RAW, MANAGER_VESTED);
        assertTrue(_h.isEffectObserved());
        assertFalse(_h.isActionPending(), "settled");
    }

    /// @dev Codex B1 at unit level: a counted push p = 200 (`transferredTokens` 30 -> 230), an unvested inflow of
    ///      d = A to the manager and accrual of 300. Plain vault threshold 1200 >= 1100, raw sum
    ///      1200 + (500 - 200 + 100) = 1600 >= 1600, vested sum 1200 + (400 - 200 + 300) = 1700 >= 1500: all the D-004
    ///      checks hold. The vault balance net of the counted push is 1000 < 1100, so the record stays pending until
    ///      the credit lands (1300 >= 1100 + 200).
    function testCountedPushWithInflowAndAccrualStaysPendingUntilCredit() public {
        _enqueueBound();
        _openGate();
        _rcm.setVestingData(_vestingAfterPush(200));
        _setBalances(V0 + 200, MANAGER_RAW - 200 + A, MANAGER_VESTED - 200 + 300);
        assertGe(_usdc.balanceOf(address(_h)), V0 + A, "plain vault threshold is met");
        assertFalse(_h.isEffectObserved(), "counted push subtracted");
        assertTrue(_h.isActionPending());

        _setBalances(V0 + 200 + A, MANAGER_RAW - 200 + A, MANAGER_VESTED - 200 + 300);
        assertTrue(_h.isEffectObserved(), "credit after the counted push");
        assertFalse(_h.isActionPending());
    }

    /// @dev A counted push before the credit must not hold the gate after the credit (exact equality is enough).
    function testCountedPushThenCreditSettles() public {
        _enqueueBound();
        _openGate();
        _rcm.setVestingData(_vestingAfterPush(200));
        _setBalances(V0 + 200 + A, MANAGER_RAW - 200, MANAGER_VESTED - 200);
        assertTrue(_h.isEffectObserved());
        assertFalse(_h.isActionPending());
    }

    /// @dev A push the counter does not see (e.g. a non-standard manager): 200 of vested underlying meets the vault
    ///      threshold net of counted pushes (1200 >= 1100) but both sums stay flat, so the gate stays closed. The two
    ///      D-004 sums are the defence in depth here.
    function testPushMeetsThresholdButNotSums() public {
        _enqueueBound();
        _openGate();
        _setBalances(V0 + 200, MANAGER_RAW - 200, MANAGER_VESTED - 200);
        assertGe(_usdc.balanceOf(address(_h)), V0 + A, "plain vault threshold is met");
        assertFalse(_h.isEffectObserved());
        assertTrue(_h.isActionPending());
    }

    /// @dev Uncounted push plus an unvested inflow to the manager: only the raw sum rises.
    function testOnlyRawSumRisesStaysPending() public {
        _enqueueBound();
        _openGate();
        _setBalances(V0 + 200, MANAGER_RAW - 200 + 300, MANAGER_VESTED - 200);
        assertFalse(_h.isEffectObserved());
        assertTrue(_h.isActionPending());
    }

    /// @dev Uncounted push plus vesting accrual: only the vested sum rises.
    function testOnlyVestedSumRisesStaysPending() public {
        _enqueueBound();
        _openGate();
        _setBalances(V0 + 200, MANAGER_RAW - 200, MANAGER_VESTED - 200 + 300);
        assertFalse(_h.isEffectObserved());
        assertTrue(_h.isActionPending());
    }

    /// @dev D-034: a re-anchor of the vesting schedule inside the window (a new `updateBalanceTimestamp`, a new
    ///      `lastUpdateBalance`, or `transferredTokens` reset below the snapshot) waits for `timeoutAt`, even with the
    ///      credit landed and every balance condition met.
    function testReanchorWaitsForTimeoutEvenAfterCredit() public {
        _h.recordTimingOrder();
        _enqueueBound();
        _openGate();
        _setBalances(V0 + A, MANAGER_RAW, MANAGER_VESTED);
        assertTrue(_h.isEffectObserved(), "credit observed before any re-anchor");

        VestingData memory moved = _vesting0();
        moved.updateBalanceTimestamp = ANCHOR + 1;
        _rcm.setVestingData(moved);
        assertFalse(_h.isEffectObserved(), "new anchor timestamp");

        moved = _vesting0();
        moved.lastUpdateBalance = LAST_UPDATE_BALANCE + 1;
        _rcm.setVestingData(moved);
        assertFalse(_h.isEffectObserved(), "new lastUpdateBalance");

        moved = _vesting0();
        moved.transferredTokens = TRANSFERRED0 - 1;
        _rcm.setVestingData(moved);
        assertFalse(_h.isEffectObserved(), "push counter went down");
        assertTrue(_h.isActionPending(), "pending until timeoutAt");

        _reachTimeout();
        assertFalse(_h.isActionPending(), "timeoutAt opens the gate");
        assertTrue(_h.settleIfReady());
        _assertBindingCleared("cleared at the timeout");
    }

    /// @dev D-034: the vault's rewards manager replaced or removed inside the window waits for `timeoutAt`.
    function testRewardsManagerChangeWaitsForTimeout() public {
        _enqueueBound();
        _openGate();
        _setBalances(V0 + A, MANAGER_RAW, MANAGER_VESTED);
        assertTrue(_h.isEffectObserved(), "credit observed with the bound manager");

        _h.setRewardsClaimManager(makeAddr("replacementManager"));
        assertFalse(_h.isEffectObserved(), "manager replaced");
        _h.setRewardsClaimManager(address(0));
        assertFalse(_h.isEffectObserved(), "manager removed");
        assertTrue(_h.isActionPending());

        _reachTimeout();
        assertFalse(_h.isActionPending(), "timeoutAt opens the gate");
    }

    /// @dev Without a rewards manager the record is not bound and the effect is the plain vault-balance threshold, as
    ///      before IL-9529.
    function testUnboundRecordUsesPlainVaultThreshold() public {
        _h.setRewardsClaimManager(address(0));
        _h.enqueueWithEffect(1e18, 20, 2, 0, address(_usdc), V0 + A, 600);
        _openGate();
        _setBalances(V0 + 200, MANAGER_RAW - 200, MANAGER_VESTED - 200);
        assertTrue(_h.isEffectObserved());
        assertFalse(_h.isActionPending());
    }

    /// @dev D-034: an unbound record of the underlying (sent without a rewards manager) is not observed while a
    ///      manager is set, so a manager set inside the window waits for `timeoutAt`. A record of another token stays
    ///      the plain threshold whatever the manager.
    function testUnboundUnderlyingRecordWaitsWhileARewardsManagerIsSet() public {
        _h.setRewardsClaimManager(address(0));
        _h.enqueueWithEffect(1e18, 20, 2, 0, address(_usdc), V0 + A, 600);
        _openGate();
        _setBalances(V0 + A, MANAGER_RAW, MANAGER_VESTED);
        assertTrue(_h.isEffectObserved(), "no manager: plain threshold");
        _h.setRewardsClaimManager(address(_rcm));
        assertFalse(_h.isEffectObserved(), "manager set inside the window");
        assertTrue(_h.isActionPending());
        _reachTimeout();
        assertTrue(_h.settleIfReady(), "settles at timeoutAt");

        HyperCoreMockUsdc other = new HyperCoreMockUsdc();
        deal(address(other), address(_h), V0 + A);
        _h.enqueueWithEffect(1e18, 20, 2, 0, address(other), V0 + A, 600);
        _openGate();
        assertTrue(_h.isEffectObserved(), "another token: plain threshold with a manager set");
    }

    /// @dev A gap 3: the manager reads are not guarded. Before `timeoutAt` a reverting `getVestingData()` or
    ///      `balanceOf()` reverts the predicate; at `timeoutAt` the predicate is true without reading the manager and
    ///      `settleIfReady` clears every rewards field.
    function testRevertingManagerReadsRevertBeforeTimeoutAndAreSkippedAtTimeout() public {
        _h.recordTimingOrder();
        for (uint256 i; i < 2; ++i) {
            _setBalances(V0, MANAGER_RAW, MANAGER_VESTED);
            _enqueueBound();
            _openGate();
            _setBalances(V0 + A, MANAGER_RAW, MANAGER_VESTED);
            _rcm.setReverts(i == 1, i == 0);

            vm.expectRevert(
                HyperCorePendingLibMockRewardsManager.HyperCorePendingLibMockRewardsManagerReverted.selector
            );
            _h.isActionSettled();

            _reachTimeout();
            assertTrue(_h.isActionSettled(), "timeoutAt: no manager read");
            assertTrue(_h.settleIfReady());
            _assertBindingCleared("cleared at the timeout");
            _rcm.setReverts(false, false);
        }
    }

    /// @dev Codex #10: a bound record that satisfied its condition but was never cleared must not leak the binding
    ///      into the next record of any kind; `lastOrderL1Block` is not touched by the reset.
    function testNextEnqueueZeroesBindingOfSettledUnclearedRecord() public {
        _h.recordTimingOrder();
        for (uint256 kind; kind < 3; ++kind) {
            _setBalances(V0, MANAGER_RAW, MANAGER_VESTED);
            _enqueueBound();
            _openGate();
            _setBalances(V0 + A, MANAGER_RAW, MANAGER_VESTED);
            assertFalse(_h.isActionPending(), "bound record settled without clear");
            (address manager, , ) = _h.rewardsFields();
            assertEq(manager, address(_rcm), "binding still stored (no clear)");

            if (kind == 0) {
                _h.enqueueWithEffect(1e18, 20, 2, 0, address(_usdc), 1, 600); // EVM balance, no bind
            } else if (kind == 1) {
                _h.enqueueWithEffect(1e18, 20, 1, 0, address(0), 1, 600); // Core spot
            } else {
                _h.enqueue(1e18, 20, keccak256("timing")); // timing only
            }

            _assertBindingCleared("binding zeroed by the next enqueue");
            assertEq(_h.lastOrderL1Block(), 100, "lastOrderL1Block untouched");
            // move past the window and the effect timeout so the next iteration can enqueue
            vm.warp(block.timestamp + 1000);
            _core.setL1BlockNumber(_core.getL1BlockNumber() + 1);
            assertFalse(_h.isActionPending());
        }
    }

    function testClearDeletesBinding() public {
        _h.recordTimingOrder();
        _enqueueBound();
        _openGate();
        _setBalances(V0 + A, MANAGER_RAW, MANAGER_VESTED);
        assertTrue(_h.settleIfReady());
        _assertBindingCleared("cleared by settleIfReady");
    }
}
