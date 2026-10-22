// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

contract GapToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipStateVersionGapTest
/// @notice State-version gaps on the dispatcher -> executor lane (IL-8496, superseding the fail-closed-on-gap
///         fix for `state_version_gap_detected_but_not_fail_closed`).
///
///         CCIP 2.0 does not keep that lane in order (`allowOutOfOrderExecution = false` is ignored and
///         `OffRamp.execute` is permissionless), so a gap is normally a reordering, not a loss. The executor
///         used to BLOCK the chain on a gap and consume the message, which left the frontier one version
///         behind for good once the earlier response landed. `CcipExecutorCommandLib.acceptRemoteStateVersion`
///         now reverts `StateVersionGap`, as the Stargate executor does: the OffRamp keeps the message as
///         FAILURE with its effects rolled back, and it is re-executed once the missing version has landed.
///         `MockCcipRouter.deliverHeld` plays that re-execution (a receiver revert bubbles and the message
///         stays executable).
///
///         Only value-moving responses carry a version bump (IL-8257), so the vehicle for every version here is
///         an outbound transfer whose `TRANSFER_SETTLED` is held or dropped; a `BALANCE_REPORT` no longer
///         bumps the version and is covered by `CcipValueNeutralVersionTest`.
///
///         A version that is really lost is produced through the production path: a real dispatcher settles
///         an outbound transfer, its `TRANSFER_SETTLED` cannot be sent, and the timelocked
///         `executeSkipStuckResponse` valve drops it, permanently consuming that state version. The later responses then keep failing
///         until the timelocked `ADVANCE_FRONTIER` repair. While the gap is open an honest attestation, which
///         carries the dispatcher's real `stateVersion`, is refused, and NAV fails closed on attestation
///         staleness. Both sides are real contracts throughout.
contract CcipStateVersionGapTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    GapToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new GapToken();
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
            GUARDIAN,
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
            rescueGuardian: GUARDIAN,
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

    /// @dev Bridges value across, which drives the dispatcher's `_receiveOutbound`: it bumps the remote
    ///      state version and answers with a `TRANSFER_SETTLED` the executor consumes. Leaves the executor
    ///      with a settled remote balance and a contiguous frontier.
    function _bridge(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    function _requestBalanceReport() private {
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 500_000);
    }

    /// @dev Burn exactly one remote state version without the executor ever seeing it, using only
    ///      production paths: the dispatcher answers a recall (consuming a version with its
    ///      `RETURN_TRANSFER`), delivery of that answer fails, and the timelocked head-of-queue skip valve
    ///      drops it for good (the tokens go back to the dispatcher's idle). The executor's recall record is
    ///      then cancelled, as the skip valve's NatSpec prescribes, so no pending record outlives the drop.
    function _burnOneRemoteStateVersion() private {
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 500_000);
        uint64 stuck = dispatcher.responseQueueHead();
        assertTrue(stuck != 0, "a response should be stuck in the queue");

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, stuck);

        router.setFailSend(address(dispatcher), false);
        executor.cancelPendingReturn(REMOTE_CHAIN);
    }

    /// @dev Bridge `amount_` with delivery held in both directions, let the dispatcher settle it, and
    ///      return the router index of its (undelivered) `TRANSFER_SETTLED`.
    function _heldSettle(uint256 amount_) private returns (uint256 settleIndex) {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
        router.deliverHeld(router.heldCount() - 1);
        settleIndex = router.heldCount() - 1;
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);
    }

    function _expectGap(uint64 expected_, uint64 got_) private {
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.StateVersionGap.selector, REMOTE_CHAIN, expected_, got_)
        );
    }

    /// @notice IL-8496 headline: two responses executed in reverse order. The later one fails on the gap and
    ///         changes nothing; once the earlier one lands, re-executing the later one applies it. The frontier
    ///         ends contiguous and the chain is never blocked.
    /// @dev FAILS WITHOUT THE FIX: the later response is consumed on the gap and blocks the chain, and the
    ///      frontier stays one version short after the earlier one lands.
    function testReversedResponsesApplyOnceTheEarlierOneLands() public {
        _bridge(100e18);
        _approve(100e18);
        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        uint256 first = _heldSettle(10e18);
        uint256 second = _heldSettle(20e18);

        _expectGap(f + 1, f + 2);
        router.deliverHeld(second);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), f, "a response ahead of the frontier changes nothing");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "a reordering must not block the chain");
        assertEq(executor.getBalance(), 130e18, "NAV stays live while the earlier response is in flight");

        router.deliverHeld(first);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), f + 1);
        router.deliverHeld(second); // the re-execution
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), f + 2, "frontier contiguous after the re-execution");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN));
        assertEq(executor.getBalance(), 130e18, "both credits applied exactly once");
    }

    /// @notice A version that is really lost keeps every later response failing, without blocking the chain.
    ///         An honest attestation carries the dispatcher's real `stateVersion` and is refused while the gap
    ///         is open, so NAV cannot be re-priced over it and fails closed once the last attestation is stale.
    function testLostVersionFailsLaterResponsesAndRefusesAnHonestAttestation() public {
        _bridge(100e18);
        _approve(100e18);
        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        _burnOneRemoteStateVersion();
        uint256 settleCreatedAt = block.timestamp;
        uint256 report = _heldSettle(10e18);

        _expectGap(f + 1, f + 2);
        router.deliverHeld(report);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), f, "frontier unadvanced");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the gap itself does not block");
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN));

        vm.warp(block.timestamp + 2 hours);
        uint64 observed = dispatcher.stateVersion();
        assertEq(observed, f + 2, "the dispatcher is ahead of the executor");
        bytes32 positionSetHash = dispatcher.trackedPositionSetHash();
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalVersionMismatch.selector, f, observed)
        );
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        executor.proposeBalance(
            REMOTE_CHAIN,
            140e18,
            observed,
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            positionSetHash
        );

        vm.warp(block.timestamp + 7 days);
        // The settle that cannot apply keeps its transfer pending (its credit is still in flight), so NAV
        // fails closed on the transfer-staleness gate, which fires before the attestation-staleness one.
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.TransferStale.selector, REMOTE_CHAIN, settleCreatedAt)
        );
        executor.getBalance();
    }

    /// @notice The documented way out of a lost version: the timelocked `ADVANCE_FRONTIER` past it, then the
    ///         failed response is re-executed and a fresh dual-role attestation lifts the repair block.
    function testTimelockedFrontierRepairThenReexecutionRecoversTheChain() public {
        _bridge(100e18);
        _approve(100e18);
        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        _burnOneRemoteStateVersion();
        uint256 report = _heldSettle(10e18);
        _expectGap(f + 1, f + 2);
        router.deliverHeld(report);

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, f + 1);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, f + 1);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "the repair blocks until a fresh attestation");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair armed by the timelocked rescue");
        // IL-8590: the dropped return can never land (the dispatcher never sends a reject for it), so the
        // repair clears the cancelled recall's clock.
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "ADVANCE_FRONTIER cleared the cancelled count");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "ADVANCE_FRONTIER cleared the cancelled clock");

        router.deliverHeld(report); // re-execute the response that failed on the gap
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), f + 2, "the failed response applies after the repair");
        assertEq(dispatcher.stateVersion(), f + 2, "executor and dispatcher agree again");

        vm.warp(block.timestamp + 2 hours);
        _approve(98e18);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the repair's intended exit still works");
        assertEq(executor.getBalance(), 98e18, "NAV readable again after the repair");
    }

    /// @notice Contiguous versions must be entirely unaffected — the guard must not fire on the happy path.
    function testContiguousVersionsNeverBlockTheChain() public {
        _bridge(100e18);
        _approve(100e18);

        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        _bridge(1e18);
        _bridge(1e18);
        _bridge(1e18);

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier + 3, "frontier advances one per settle");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "contiguous reports must never block");
        assertEq(executor.getBalance(), 103e18, "NAV stays live on the happy path");
    }

    /// @notice A duplicate (already-consumed) version is benign and must not block: it is a replay of a
    ///         transition already applied, not evidence of a lost one.
    function testDuplicateVersionMustNotBlockTheChain() public {
        _bridge(100e18);
        _approve(100e18);

        _requestBalanceReport();
        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        // Re-deliver an already-consumed version. The dispatcher's counter cannot be rewound through its
        // API, so the payload is rebuilt here — the branch under test is pure frontier arithmetic and the
        // message is byte-identical in shape to what the dispatcher emits for a BALANCE_REPORT.
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("duplicate"),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(CcipMsgType.BALANCE_REPORT, abi.encode(uint256(100e18), frontier)),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier, "frontier unchanged by a duplicate");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "a duplicate must not block");
        assertEq(executor.getBalance(), 100e18, "NAV stays live");
    }

    /// @notice `UPDATE_VAULTS_ACK` is a reserved wire value that nothing sends (IL-8483 / B-29). An
    ///         authenticated message of that type must be ignored as an unknown type and must NOT be processed
    ///         as a `BALANCE_REPORT`: it consumes no state version and moves neither the frontier nor the block flag.
    function testReservedUpdateVaultsAckIsIgnoredAndConsumesNoStateVersion() public {
        _bridge(100e18);
        _approve(100e18);
        _requestBalanceReport();
        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        vm.expectEmit(address(executor));
        emit CcipCrosschainExecutor.InboundMessageIgnored(REMOTE_CHAIN, uint8(CcipMsgType.UPDATE_VAULTS_ACK), "type");
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("reserved-type-12"),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(CcipMsgType.UPDATE_VAULTS_ACK, abi.encode(uint256(100e18), frontier + 1)),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );

        assertEq(uint8(CcipMsgType.UPDATE_VAULTS_ACK), 12, "the reserved member keeps its wire value");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier, "no state version consumed");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "an ignored message must not block");
    }
}
