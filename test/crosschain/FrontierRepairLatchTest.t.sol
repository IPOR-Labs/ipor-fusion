// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipChainRescue, ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title StargateFrontierRepairLatchTest
/// @notice Regression cover for `stale_frontier_repair_flag_lifts_unrelated_fail_closed_chain_block`.
///
///         `frontierRepairPending[chainId]` is a one-shot latch: `applyForceResolve(ADVANCE_STATE_FRONTIER)`
///         arms it together with a NAV block, and `approve` consumes it to lift that block once a fresh
///         dual-role attestation lands. It had no other lifecycle. So resolving the repair the OTHER
///         legitimate way — the timelocked `executeForceSetSettledBalance`, used when no fresh attestation
///         can be produced — cleared `chainBlocked` and left the latch armed forever. From then on every
///         ordinary `approve` silently lifted whatever block happened to be standing, including one raised
///         later for a completely unrelated reason, bypassing the timelocked unblock that block is
///         documented to require.
///
///         The fix makes the latch belong to the block that armed it: it is consumed when that block is
///         cleared by any route, and discarded whenever a NEW block is raised.
///
///         The executor exposes `frontierRepairPending(chainId)` (IL-8468), so the latch is asserted directly
///         as well as through its observable effect — whether an ordinary approval can lift a block.
contract StargateFrontierRepairLatchTest is CrosschainTestBase {
    event ChainUnblockedByApproval(uint256 chainId, uint256 proposalId);

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

    /// @dev The observation is built BEFORE the prank: `_obs` reads state and an external call there would
    ///      consume the prank (repo gotcha).
    function _propose(uint256 settled_) private returns (uint256 proposalId) {
        BalanceObservation memory o = _obs(settled_);
        vm.prank(proposer);
        executor.proposeBalance(o);
        proposalId = executor.activeProposalId(REMOTE_CHAIN);
    }

    function _approve(uint256 settled_) private {
        uint256 proposalId = _propose(settled_);
        vm.prank(approver);
        executor.approveBalance(proposalId);
    }

    function _rejectAndBlock(uint256 settled_) private {
        uint256 proposalId = _propose(settled_);
        vm.prank(approver);
        executor.rejectAndBlockProposal(proposalId);
    }

    /// @dev Arm a frontier repair: advances the acknowledged state version, blocks the chain and sets the
    ///      repair latch. `transferId_` packs `(chainId << 64) | newVersion`.
    function _armFrontierRepair() private {
        uint64 newVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN) + 1;
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(newVersion));
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "frontier repair blocks the chain");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "frontier repair arms the latch");
    }

    function _forceSetSettled(uint256 newSettledLD_) private {
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, newSettledLD_, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, newSettledLD_, observedVersion, fsObs, false);
    }

    /// @notice The headline exploit. A frontier repair resolved through the timelocked force-set left the
    ///         latch armed; an unrelated `rejectAndBlockProposal` later was then liftable by the very role
    ///         that tripped it, with one more propose/approve round — no RESCUE_DELAY, no guardian veto.
    function testStaleLatchShouldNotLiftAnUnrelatedBlock() public {
        _readyDispatcher();
        _settle100();

        _armFrontierRepair();
        // The other legitimate resolution: authoritative overwrite instead of a fresh attestation.
        _forceSetSettled(100e6);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "rescue resolved the repair");

        // Much later, an unrelated fail-closed block.
        vm.warp(block.timestamp + 1 days);
        _rejectAndBlock(95e6);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "breaker tripped");

        vm.warp(block.timestamp + 1 hours);
        _approve(98e6);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "a consumed repair latch grants no free unblock");
        // NAV stays fail-closed. Asserted through `getBalance()` (i.e. `computeNavSD`), not
        // `getBalanceByChain`, which deliberately carries none of the fail-closed checks.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice Defence in depth for the same rule, with the latch genuinely (not stalely) armed: raising a
    ///         NEW block must discard a pending repair, or the reject is liftable by its own author.
    function testRaisingABlockShouldDiscardAPendingRepair() public {
        _readyDispatcher();
        _settle100();

        _armFrontierRepair();

        // The repair is still pending when an unrelated reject raises its own block.
        vm.warp(block.timestamp + 1 hours);
        _rejectAndBlock(95e6);

        vm.warp(block.timestamp + 1 hours);
        _approve(98e6);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "reject stands until the timelocked unblock");
    }

    /// @notice The latch's own purpose must be untouched: a repair resolved the intended way — a fresh
    ///         dual-role attestation — still lifts the block it armed.
    function testFrontierRepairIsStillLiftedByAFreshAttestation() public {
        _readyDispatcher();
        _settle100();

        _armFrontierRepair();

        vm.warp(block.timestamp + 1 hours);
        _approve(98e6);

        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the repair's intended exit still works");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 98e6, "attested value written");
    }

    /// @notice A rescue overwrite with no repair pending must not become an unblock-for-free either: it
    ///         clears its own block, and a later reject still stands.
    function testForceSetSettledWithoutARepairLeavesLaterBlocksIntact() public {
        _readyDispatcher();
        _settle100();

        _forceSetSettled(100e6);

        vm.warp(block.timestamp + 1 hours);
        _rejectAndBlock(95e6);
        vm.warp(block.timestamp + 1 hours);
        _approve(98e6);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "no latch was ever armed, none can be consumed");
    }

    /// @notice IL-8468: the approval that consumes the latch lifts the block and says so.
    function testShouldEmitChainUnblockedByApprovalWhenLatchLiftsBlock() public {
        _readyDispatcher();
        _settle100();
        _armFrontierRepair();

        vm.warp(block.timestamp + 1 hours);
        uint256 proposalId = _propose(98e6);
        vm.expectEmit(address(executor));
        emit ChainUnblockedByApproval(REMOTE_CHAIN, proposalId);
        vm.prank(approver);
        executor.approveBalance(proposalId);

        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "latch consumed");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted");
    }

    /// @notice IL-8468: an ordinary approval with no latch armed emits no `ChainUnblockedByApproval`.
    function testShouldNotEmitChainUnblockedByApprovalWithoutLatch() public {
        _readyDispatcher();
        _settle100();
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "no latch");

        vm.warp(block.timestamp + 1 hours);
        uint256 proposalId = _propose(98e6);
        vm.recordLogs();
        vm.prank(approver);
        executor.approveBalance(proposalId);

        assertEq(_countUnblockedLogs(address(executor)), 0, "no unblock event without the latch");
    }

    /// @dev IL-8620: advance the frontier by one without asserting who owns the resulting block.
    function _advanceFrontierOnce() private {
        uint64 newVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN) + 1;
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(newVersion));
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
    }

    /// @notice IL-8620: a repair run while a FOREIGN block stands must not arm the latch, or one ordinary approval
    ///         would lift that older block.
    function testRepairOverForeignBlockShouldNotArmLatch() public {
        _readyDispatcher();
        _settle100();
        _rejectAndBlock(95e6);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "foreign block");

        _advanceFrontierOnce();
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "latch not armed over a foreign block");

        vm.warp(block.timestamp + 1 hours);
        _approve(98e6);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "foreign block needs the timelocked force-set");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice IL-8620: a second repair over an earlier repair's own block keeps the latch armed.
    function testSecondRepairOverEarlierRepairKeepsLatch() public {
        _readyDispatcher();
        _settle100();
        _armFrontierRepair();
        _advanceFrontierOnce();
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "latch stays armed");

        vm.warp(block.timestamp + 1 hours);
        _approve(98e6);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "repair's own block lifted by approval");
    }

    function _countUnblockedLogs(address emitter_) private returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter_ && logs[i].topics[0] == ChainUnblockedByApproval.selector) ++n;
        }
    }
}

contract LatchToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipFrontierRepairLatchTest
/// @notice The finding was filed against Stargate. CCIP already clears the latch in
///         `CcipExecutorAttestationLib.forceSetSettled` (shipped with R-05), so the stale-latch path is
///         closed there — but `rejectBalanceAndBlock` had the other half of the same hole: a GENUINELY
///         pending repair made the reject liftable by its own author. Same rule, both transports.
///
///         IL-8051 made `CcipExecutorCommandLib.acceptRemoteStateVersion`'s gap branch discard the latch when
///         it raised a gap block. Since IL-8496 the gap branch raises no block and writes nothing: it reverts
///         `StateVersionGap` so the response is re-executed later (CCIP 2.0 does not order the lane), and the
///         version binding on proposals is what keeps an attestation from pricing over an open gap.
///
///         The CCIP executor exposes `frontierRepairPending` as a public getter
///         (`CcipCrosschainExecutor.sol:101`), so these tests assert it directly with the getter rather
///         than inferring it from the block's liftability, unlike the Stargate half above.
///
///         The gap is produced end to end through the production dispatcher queue plus its timelocked skip
///         valve — `router.setFailSend` + `scheduleSkipStuckResponse`/`executeSkipStuckResponse` — exactly
///         as `CcipStateVersionGapTest._burnOneRemoteStateVersion` does; `MockCcipRouter.ccipSend` delivers
///         synchronously, so an in-flight response is otherwise unreachable, and no library-level harness
///         is needed. `_burnOneRemoteStateVersion` is adapted from `CcipStateVersionGapTest.t.sol`.
///
///         Only value-moving responses carry a state version (IL-8257), so a version is produced by an
///         authenticated `OUTBOUND_TRANSFER` that the dispatcher settles (the router plays an inbound
///         transfer the executor never recorded, which also works while the chain is blocked); the executor
///         handles its `TRANSFER_SETTLED` as an unknown transfer after consuming the version.
contract CcipFrontierRepairLatchTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    event ChainUnblockedByApproval(uint256 chainId, uint256 proposalId);

    MockCcipRouter internal router;
    LatchToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new LatchToken();
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
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
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

    function _approve(uint256 balance_) private {
        uint256 proposalId = _propose(balance_);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    function _bridge(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    function _armFrontierRepair() private {
        uint64 newVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN) + 5;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair armed");
    }

    /// @dev Same rescue as `_armFrontierRepair`, but to an explicit target version so a test can repair
    ///      exactly to a version it knows was lost, rather than an arbitrary +5.
    function _advanceFrontier(uint64 newVersion_) private {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair armed");
    }

    uint256 private _forgedNonce;

    /// @dev Play an authenticated `OUTBOUND_TRANSFER` into the dispatcher: it settles the transfer, bumps its
    ///      state version and answers with a `TRANSFER_SETTLED` (delivered, held or failing, depending on the
    ///      router's mode). The executor never recorded the transfer.
    function _forgedOutboundSettle() private {
        CcipClient.EVMTokenAmount[] memory amounts = new CcipClient.EVMTokenAmount[](1);
        amounts[0] = CcipClient.EVMTokenAmount({token: address(token), amount: 1e18});
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("forged-outbound", ++_forgedNonce)),
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(address(executor)),
                data: CcipMessages.encode(
                    CcipMsgType.OUTBOUND_TRANSFER, abi.encode(keccak256(abi.encode("forged-op", _forgedNonce)))
                ),
                destTokenAmounts: amounts
            })
        );
    }

    /// @dev Burn exactly one remote state version without the executor ever seeing it, using only
    ///      production paths: the dispatcher settles an inbound transfer (consuming a version), delivery of
    ///      the `TRANSFER_SETTLED` fails, and the timelocked head-of-queue skip valve drops it for good.
    function _burnOneRemoteStateVersion() private {
        router.setFailSend(address(dispatcher), true);
        _forgedOutboundSettle();
        uint64 stuck = dispatcher.responseQueueHead();
        assertTrue(stuck != 0, "a response should be stuck in the queue");

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, stuck);

        router.setFailSend(address(dispatcher), false);
    }

    /// @notice A pending repair must not make an unrelated `rejectBalanceAndBlock` self-liftable.
    function testRaisingABlockShouldDiscardAPendingRepair() public {
        _bridge(100e18);
        _armFrontierRepair();

        vm.warp(block.timestamp + 2 hours);
        uint256 rejected = _propose(95e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(rejected);
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "raising a block discards the latch");

        vm.warp(block.timestamp + 2 hours);
        _approve(98e18);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "reject stands until the timelocked unblock");
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice IL-8620: a repair run while a FOREIGN block stands must not arm the latch.
    function testRepairOverForeignBlockShouldNotArmLatch() public {
        _bridge(100e18);
        vm.warp(block.timestamp + 2 hours);
        uint256 rejected = _propose(95e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(rejected);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "foreign block");

        uint64 newVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN) + 5;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "latch not armed over a foreign block");

        vm.warp(block.timestamp + 2 hours);
        _approve(98e18);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "foreign block needs the timelocked force-set");
    }

    /// @notice IL-8620: a second repair over an earlier repair's own block keeps the latch armed.
    function testSecondRepairOverEarlierRepairKeepsLatch() public {
        _bridge(100e18);
        _armFrontierRepair();
        _advanceFrontier(executor.lastRemoteStateVersion(REMOTE_CHAIN) + 5);
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "latch stays armed");

        vm.warp(block.timestamp + 2 hours);
        _approve(98e18);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "repair's own block lifted by approval");
    }

    /// @notice IL-8468: the approval that consumes the latch lifts the block and says so.
    function testShouldEmitChainUnblockedByApprovalWhenLatchLiftsBlock() public {
        _bridge(100e18);
        _armFrontierRepair();

        vm.warp(block.timestamp + 2 hours);
        uint256 proposalId = _propose(98e18);
        vm.expectEmit(address(executor));
        emit ChainUnblockedByApproval(REMOTE_CHAIN, proposalId);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);

        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "latch consumed");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted");
    }

    /// @notice IL-8468: an ordinary approval with no latch armed emits no `ChainUnblockedByApproval`.
    function testShouldNotEmitChainUnblockedByApprovalWithoutLatch() public {
        _bridge(100e18);
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "no latch");

        vm.warp(block.timestamp + 2 hours);
        uint256 proposalId = _propose(98e18);
        vm.recordLogs();
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].emitter != address(executor) || logs[i].topics[0] != ChainUnblockedByApproval.selector,
                "no unblock event without the latch"
            );
        }
    }

    /// @notice The latch's own purpose is untouched.
    function testFrontierRepairIsStillLiftedByAFreshAttestation() public {
        _bridge(100e18);
        _armFrontierRepair();

        vm.warp(block.timestamp + 2 hours);
        _approve(98e18);

        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the repair's intended exit still works");
        assertEq(executor.getBalance(), 98e18, "NAV readable again");
    }

    /// @notice IL-8051, revisited for IL-8496. A version lost again while a frontier repair is pending no
    ///         longer raises a new block: the later response fails on the gap (`StateVersionGap`) and changes
    ///         nothing, so the repair's own block and latch stand as they were. What keeps an ordinary
    ///         attestation from lifting the repair over the new gap is the version binding: an honest proposal
    ///         carries the dispatcher's real `stateVersion`, which is ahead of the executor frontier.
    function testGapDuringAPendingRepairFailsTheResponseAndKeepsTheRepairBlock() public {
        _bridge(100e18);
        _approve(100e18);

        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        // A version is lost, discovered as f+1 was never delivered.
        _burnOneRemoteStateVersion();
        // The rescue admin repairs to the version it believes was lost — a correct, timelocked repair.
        _advanceFrontier(f + 1);
        // A SECOND loss inside the repair window, before the attester ever consumes the pending latch.
        _burnOneRemoteStateVersion();
        // The dispatcher's next settle carries f+3 against an executor frontier of f+1 -> it fails on the gap.
        router.setAutoDeliver(false);
        _forgedOutboundSettle();
        uint256 report = router.heldCount() - 1;
        router.setAutoDeliver(true);
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.StateVersionGap.selector, REMOTE_CHAIN, f + 2, f + 3)
        );
        router.deliverHeld(report);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "the repair's block stands");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "the failed response does not touch the latch");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), f + 1, "frontier unadvanced by the gap");

        // An honest attestation (the dispatcher's real version) cannot be proposed over the open gap.
        vm.warp(block.timestamp + 2 hours);
        uint64 observed = dispatcher.stateVersion();
        bytes32 positionSetHash = dispatcher.trackedPositionSetHash();
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalVersionMismatch.selector, f + 1, observed)
        );
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        executor.proposeBalance(
            REMOTE_CHAIN,
            98e18,
            observed,
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            positionSetHash
        );
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice Control for the stale exit (`stateVersion_ <= current`): reached through a healthy input —
    ///         a repair that advances the frontier ahead of the dispatcher's next report, so the next
    ///         report is a stale replay by construction, not a crafted edge case. The stale exit must
    ///         leave a pending repair's latch untouched, or every repair would become unliftable by
    ///         attestation whenever the dispatcher's queue drains before the attester acts.
    function testStaleResponsesDuringAPendingRepairMustNotDisturbTheLatch() public {
        _bridge(100e18);
        _approve(100e18);

        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        _armFrontierRepair(); // advances the frontier to f + 5 with nothing lost
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));

        // The dispatcher's own counter is still at f, so its next settle (f + 1) is <= the new frontier
        // (f + 5) -> the stale exit, by construction of the repair just performed.
        vm.expectEmit(true, false, false, true, address(executor));
        emit CcipExecutorCommandLib.StaleRemoteBalanceIgnored(REMOTE_CHAIN, f + 5, f + 1);
        _forgedOutboundSettle();

        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "a stale replay must not discard the latch");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "a stale replay must not touch the block");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), f + 5, "frontier untouched by a stale replay");

        // The latch's real purpose still works after the stale replay.
        vm.warp(block.timestamp + 2 hours);
        _approve(98e18);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the repair's intended exit still works");
        assertEq(executor.getBalance(), 98e18, "NAV readable again");
    }

    /// @notice Control for the contiguous exit (`stateVersion_ == current + 1`): it neither raises nor
    ///         lifts a block, so a pending repair's latch must be left exactly as it was.
    function testContiguousAdvanceDuringAPendingRepairMustNotDisturbTheLatch() public {
        _bridge(100e18);
        _approve(100e18);

        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        _burnOneRemoteStateVersion(); // f + 1 lost
        _advanceFrontier(f + 1); // correct, timelocked repair

        // The dispatcher's next settle is f + 2 -> exactly current + 1 -> the contiguous exit. Its reported
        // balance is the 100e18 bridged plus the two forged 1e18 inbound transfers (the burned one and this one).
        vm.expectEmit(true, false, false, true, address(executor));
        emit CcipExecutorCommandLib.RemoteBalanceUpdated(REMOTE_CHAIN, 102e18, f + 2);
        _forgedOutboundSettle();

        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "a contiguous advance must not discard the latch");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "a contiguous advance raises no block and lifts none");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), f + 2, "frontier advances by one, contiguously");

        // The still-pending repair is lifted by the next ordinary approval, exactly as intended.
        vm.warp(block.timestamp + 2 hours);
        _approve(98e18);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the repair's intended exit still works");
    }
}
