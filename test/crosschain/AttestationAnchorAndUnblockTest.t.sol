// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

contract AnchorToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipAttestationAnchorAndUnblockTest
/// @notice Regression cover for two audit findings on the CCIP transport:
///
///         `no_cumulative_bound_on_attested_balance_ratchet` — the big-change limiter is RELATIVE, so it
///         constrained nothing while `settledRemoteBalance` was zero and one propose/approve round could
///         write an arbitrary NAV. The window is not only the pre-first-attestation state: a full recall
///         debits the bucket back to zero and re-opens it.
///
///         `missing_unblock_counterpart_permanent_fail_closed_nav` — `rejectBalanceAndBlock` set
///         `chainBlocked` and nothing but a frontier repair could clear it, so a blocked chain froze
///         `getBalance()` (and therefore the whole vault's `totalAssets()`) forever.
///
///         The two fixes are deliberately coupled: refusing an unanchored attestation is only safe
///         because the timelocked settled-overwrite rescue exists as the escalation path.
contract CcipAttestationAnchorAndUnblockTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    AnchorToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new AnchorToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router), factory, address(this), address(token), keccak256("USDC"), 18, _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            RESCUE_ADMIN,
            address(0xB22),
            RESCUE_DELAY
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: RESCUE_ADMIN,
            rescueGuardian: address(0xB22),
            balanceProposer: address(this),
            balanceApprover: APPROVER,
            rescueDelay: RESCUE_DELAY,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }

    function _propose(uint256 balance_) private returns (uint256 proposalId) {
        proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    function _attest(uint256 balance_) private {
        uint256 proposalId = _propose(balance_);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    /// @dev Bridge and settle `amount_`, which credits `settledRemoteBalance` through an AUTHENTICATED
    ///      TRANSFER_SETTLED — the legitimate way off a zero baseline.
    function _bridge(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    function _forceSetSettled(uint256 newSettledLD_) private {
        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        uint256 arg = _fssArg(newSettledLD_);
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }

    /// @dev `FORCE_SET_SETTLED` argument observed at the executor's current frontier (IL-8294).
    function _fssArg(uint256 newSettledLD_) private view returns (uint256) {
        return (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) |
            (block.timestamp << 128) | newSettledLD_;
    }

    // ---------------------------------------------------------------------
    // no_cumulative_bound_on_attested_balance_ratchet
    // ---------------------------------------------------------------------

    /// @notice The headline exploit: with nothing ever bridged, one propose/approve wrote arbitrary NAV.
    function testShouldRejectArbitraryNavAtZeroBaseline() public {
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "precondition: zero baseline");

        uint256 proposalId = _propose(1_000_000e18);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.UnanchoredAttestation.selector, REMOTE_CHAIN, 1_000_000e18
            )
        );
        executor.approveBalance(proposalId);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "no phantom NAV was written");
        assertEq(executor.getBalance(), 0, "share price untouched");
    }

    /// @notice The window the finding calls out as recurring: a full recall drains the bucket to zero, and
    ///         attestation must not be able to refill it out of thin air afterwards.
    function testShouldRejectArbitraryNavAfterFullRecallDrainsSettled() public {
        _bridge(100e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "settled via authenticated settlement");

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 100e18, 100e18, 0, address(0), 500_000);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "full recall drained the bucket");

        vm.warp(block.timestamp + 2 hours);
        uint256 proposalId = _propose(500_000e18);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.UnanchoredAttestation.selector, REMOTE_CHAIN, 500_000e18)
        );
        executor.approveBalance(proposalId);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "bucket stays drained");
    }

    /// @notice Happy path must be untouched: once an authenticated settlement anchors the bucket, ordinary
    ///         attestation still works and the relative limiter is the only bound that applies.
    function testShouldStillAttestYieldOnceAnchored() public {
        _bridge(100e18);
        vm.warp(block.timestamp + 2 hours);

        _attest(110e18);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e18, "yield recognised");
        assertEq(executor.getBalance(), 110e18);
    }

    /// @notice A zero-to-zero approval carries no value and stays allowed — it only refreshes freshness.
    function testShouldAllowZeroToZeroAttestation() public {
        _attest(0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), uint64(block.timestamp), "freshness refreshed");
    }

    /// @notice The escalation path the fix relies on: what attestation may no longer do, the timelocked
    ///         rescue still can.
    function testShouldLeaveZeroBaselineThroughTimelockedRescue() public {
        _forceSetSettled(250e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 250e18, "rescue is the anchored exit");
        assertEq(executor.getBalance(), 250e18);
    }

    // ---------------------------------------------------------------------
    // missing_unblock_counterpart_permanent_fail_closed_nav
    // ---------------------------------------------------------------------

    /// @notice The headline exploit: the circuit breaker froze NAV — and therefore the whole vault's
    ///         `totalAssets()` — with no way back.
    function testShouldLiftNavBlockThroughTimelockedRescue() public {
        _bridge(100e18);
        vm.warp(block.timestamp + 2 hours);

        uint256 proposalId = _propose(90e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(proposalId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "breaker tripped");

        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();

        _forceSetSettled(90e18);

        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted");
        assertEq(executor.getBalance(), 90e18, "NAV readable again");
    }

    /// @notice The block must NOT be liftable by the role that tripped it. Stargate behaves the same way;
    ///         what was missing on CCIP is the rescue above, not this.
    function testApprovalAloneShouldNotLiftNavBlock() public {
        _bridge(100e18);
        vm.warp(block.timestamp + 2 hours);

        uint256 rejected = _propose(90e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(rejected);

        vm.warp(block.timestamp + 2 hours);
        _attest(95e18);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "approver cannot self-clear the breaker");
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice The rescue must not race a credit that is still on the wire.
    function testForceSetSettledShouldRejectWhileAReturnIsOutstanding() public {
        _bridge(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 500_000);

        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        uint256 arg = _fssArg(10e18);
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.PendingTransfersExist.selector, REMOTE_CHAIN, 1)
        );
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }

    /// @notice IL-8292: the rescue above refuses to run while a recall is active, so the manager must not be
    ///         able to open one on a blocked chain — re-opening it before every execute held the NAV block
    ///         in place indefinitely.
    function testShouldRefuseRecallOnBlockedChainSoRescueCannotBeHeldShut() public {
        _bridge(100e18);
        vm.warp(block.timestamp + 2 hours);
        uint256 proposalId = _propose(90e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(proposalId);

        uint256 arg = _fssArg(90e18);
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 0, 0, address(0), 500_000);
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "no recall slot opened");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted");
        assertEq(executor.getBalance(), 90e18, "NAV readable again");

        // Once the block is lifted the recall lane is open again.
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 0, 0, address(0), 500_000);
        assertTrue(executor.activeReturn(REMOTE_CHAIN) != bytes32(0), "recall allowed after the rescue");
    }

    /// @notice A recall opened BEFORE the block is not manager-renewable: the permissionless stale cancel
    ///         frees the slot and the queued rescue then runs.
    function testRecallOpenedBeforeBlockShouldNotHoldRescueShut() public {
        _bridge(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 0, 0, address(0), 500_000);

        vm.warp(block.timestamp + 2 hours);
        uint256 proposalId = _propose(90e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(proposalId);

        uint256 arg = _fssArg(90e18);
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.PendingTransfersExist.selector, REMOTE_CHAIN, 1)
        );
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        vm.prank(address(0xCAFE));
        executor.cancelStalePendingReturn(REMOTE_CHAIN);

        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted");
    }

    /// @notice The rescue clears `frontierRepairPending` too, so a later ordinary approval cannot lift a
    ///         future, unrelated block for free.
    function testForceSetSettledShouldDisarmAPendingFrontierRepair() public {
        _bridge(100e18);
        uint64 newVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN) + 5;

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair armed");

        _forceSetSettled(100e18);
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "repair disarmed by the overwrite");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN));

        // A fresh block now stays blocked despite an ordinary approval.
        vm.warp(block.timestamp + 2 hours);
        uint256 rejected = _propose(95e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(rejected);
        vm.warp(block.timestamp + 2 hours);
        _attest(98e18);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "stale repair flag did not grant a free unblock");
    }

    // ---------------------------------------------------------------------
    // guard_bypass_permits_double_debit_of_settled_balance (IL-8294)

    /// @dev Bridge 100, then recall 60 and hold the dispatcher's `RETURN_TRANSFER` on the lane: the dispatcher
    ///      has debited the recall, bumped its state version and sent the tokens, so its `accountedBalance()`
    ///      already reads 40 while the executor has not seen the return yet. The recall is then cancelled
    ///      permissionlessly, which clears `activeReturn` — the in-flight guard the settled overwrite relied on.
    function _recallInTransitAndCancel() private {
        _bridge(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 500_000);
        router.setFailSend(address(dispatcher), false);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        dispatcher.flushResponse();
        assertEq(dispatcher.accountedBalance(), 40e18, "recall left the dispatcher");
        assertEq(dispatcher.stateVersion(), executor.lastRemoteStateVersion(REMOTE_CHAIN) + 1, "return on the wire");
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(address(0xCAFE));
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "in-flight guard cleared");
    }

    /// @notice A force-set of the balance read from the dispatcher after its recall left (version above the
    ///         frontier) is refused at schedule: the late `RETURN_TRANSFER` would debit settled a second time.
    ///         Once the return lands the frontier catches up and a fresh observation at it is accepted.
    function testForceSetSettledShouldRefuseObservationAboveFrontierAfterCancel() public {
        _recallInTransitAndCancel();
        uint64 acknowledged = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        uint64 observed = dispatcher.stateVersion();
        uint256 arg = (uint256(observed) << 192) | (block.timestamp << 128) | dispatcher.accountedBalance();

        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainExecutor.ForceSetStateVersionMismatch.selector, REMOTE_CHAIN, acknowledged, observed
            )
        );
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        router.deliverHeld(0);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), observed, "frontier caught up");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "late return debited once");
        assertEq(executor.idleLedger(), 60e18, "recalled tokens credited once");

        // The correct flow: observe the dispatcher at the new frontier and force-set to what it reports.
        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        uint256 fresh = _fssArg(dispatcher.accountedBalance());
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, fresh);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, fresh);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "overwrite matches the remote");
        assertEq(executor.idleLedger(), 60e18, "recalled tokens credited once");
        assertEq(executor.getBalance(), 100e18, "NAV conserved");
    }

    /// @notice The version is the admin's statement of when the balance was read: claiming the stale frontier
    ///         for a post-recall balance is not caught here. Observing at the frontier is what must hold.
    ///         This pins the one shape the binding lets through, so a later change to it is deliberate.
    function testForceSetSettledObservedAtFrontierRunsWhileReturnInTransit() public {
        _recallInTransitAndCancel();
        uint256 arg = _fssArg(100e18);

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        // A balance read at the frontier (before the recall left) still counts the recalled amount, so the
        // late return's debit is the one that removes it.
        router.deliverHeld(0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "later return debited");
        assertEq(executor.idleLedger(), 60e18);
        assertEq(executor.getBalance(), 100e18, "NAV conserved");
    }

    /// @notice While the return is still in the dispatcher's queue its amount is counted in
    ///         `accountedBalance()`, yet the version has already moved. An observation at that version is above
    ///         the frontier and is refused at schedule: executing the 100e18 observation after the flush would
    ///         have double-counted the return. After the flush the frontier equals that version, and a fresh
    ///         observation at it is accepted.
    function testForceSetSettledShouldRefuseObservationAboveFrontierWhileReturnQueued() public {
        _bridge(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 500_000);
        assertEq(dispatcher.accountedBalance(), 100e18, "queued return still counted remotely");
        uint64 acknowledged = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        uint64 observed = dispatcher.stateVersion();
        uint256 arg = (uint256(observed) << 192) | (block.timestamp << 128) | 100e18;
        vm.warp(block.timestamp + 1 days + 1);
        executor.cancelStalePendingReturn(REMOTE_CHAIN);

        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainExecutor.ForceSetStateVersionMismatch.selector, REMOTE_CHAIN, acknowledged, observed
            )
        );
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse();
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "return debited once");
        assertEq(executor.idleLedger(), 60e18, "recalled tokens credited once");

        // The correct flow: the frontier is now `observed`; take a fresh observation at it.
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), observed, "frontier caught up");
        assertEq(dispatcher.accountedBalance(), 40e18, "fresh observation excludes the returned tokens");
        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        uint256 fresh = _fssArg(dispatcher.accountedBalance());
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, fresh);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, fresh);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "overwrite matches the remote");
        assertEq(executor.getBalance(), 100e18, "NAV conserved");
    }

    /// @notice An observation that is not the frontier (behind or ahead) is refused at schedule, before a
    ///         `RESCUE_DELAY` is spent. That includes an unpacked plain balance, which reads as version 0.
    function testScheduleForceSetSettledShouldRejectObservationBehindFrontier() public {
        _bridge(100e18);
        uint64 acknowledged = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        assertGt(acknowledged, 0, "precondition: the settlement moved the frontier");

        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainExecutor.ForceSetStateVersionMismatch.selector, REMOTE_CHAIN, acknowledged, 0
            )
        );
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, 100e18);

        uint256 stale = (uint256(acknowledged - 1) << 192) | (block.timestamp << 128) | 100e18;
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainExecutor.ForceSetStateVersionMismatch.selector,
                REMOTE_CHAIN,
                acknowledged,
                acknowledged - 1
            )
        );
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, stale);

        // At the frontier it schedules and runs.
        _forceSetSettled(100e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
    }
}

/// @title StargateAttestationAnchorTest
/// @notice The zero-baseline hole was filed against CCIP only; this transport had it in identical form
///         (`StargateExecutorAttestationLib.approve`). Same regression cover, Stargate side.
contract StargateAttestationAnchorTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
    }

    function _obs(uint256 settled_) private view returns (BalanceObservation memory) {
        return BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settled_,
            stateVersion: executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            remoteBlock: uint64(block.number == 0 ? 1 : block.number),
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 days),
            trackedPositionSetHash: bytes32(0)
        });
    }

    function _propose(uint256 settled_) private returns (uint256 proposalId) {
        // The observation is built BEFORE the prank: `_obs` reads `acknowledgedRemoteStateVersion` and an
        // external call there would consume the prank (repo gotcha).
        BalanceObservation memory o = _obs(settled_);
        vm.prank(proposer);
        executor.proposeBalance(o);
        proposalId = executor.activeProposalId(REMOTE_CHAIN);
    }

    function testShouldRejectArbitraryNavAtZeroBaseline() public {
        _readyDispatcher();
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "precondition: zero baseline");

        uint256 proposalId = _propose(1_000_000e6);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.UnanchoredAttestation.selector, REMOTE_CHAIN, 1_000_000e6)
        );
        executor.approveBalance(proposalId);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "no phantom NAV was written");
    }

    function testShouldStillAttestYieldOnceAnchored() public {
        _readyDispatcher();
        _settle100();
        vm.warp(block.timestamp + 2 hours);

        uint256 proposalId = _propose(110e6);
        vm.prank(approver);
        executor.approveBalance(proposalId);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e6, "yield recognised");
    }

    function testShouldAllowZeroToZeroAttestation() public {
        _readyDispatcher();
        uint256 proposalId = _propose(0);
        vm.prank(approver);
        executor.approveBalance(proposalId);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
    }

    /// @notice Stargate already had the anchored exit the CCIP transport was missing.
    function testShouldLeaveZeroBaselineThroughTimelockedRescue() public {
        _readyDispatcher();
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 250e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 250e6, observedVersion, fsObs, false);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 250e6, "rescue is the anchored exit");
    }

    /// @notice IL-8292, Stargate side: the force-set refuses to run while a recall is active, so the manager
    ///         must not be able to open one on a blocked chain and hold the NAV block in place.
    function testShouldRefuseRecallOnBlockedChainSoRescueCannotBeHeldShut() public {
        _readyDispatcher();
        _settle100();
        vm.warp(block.timestamp + 2 hours);
        uint256 proposalId = _propose(90e6);
        vm.prank(approver);
        executor.rejectAndBlockProposal(proposalId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "breaker tripped");

        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 90e6, observedVersion, _markFsObs(), false
        );

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e6, 0, "");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 90e6, observedVersion, fsObs, false);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e6);

        // Once the block is lifted the recall lane is open again.
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        assertTrue(requestId != bytes32(0), "recall allowed after the rescue");
    }
}
