// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipObservation} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";

contract ValueNeutralToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipValueNeutralVersionTest
/// @notice IL-8257 (R-07): the dispatcher `stateVersion` counts value-moving transitions only.
///
///         `TRANSFER_SETTLED` and `RETURN_TRANSFER` bump it and move the executor frontier one version at a
///         time. `BALANCE_REPORT` and `COMMAND_ACK` carry the CURRENT version as evidence without bumping it,
///         and the executor records them (`RemoteBalanceUpdated`) without ever reading or writing the
///         frontier. So (1) a response queue stalled behind value-neutral responses no longer makes the
///         frontier lag, (2) CCIP 2.0 reordering cannot let a value-neutral response overtake and discard a
///         still in-transit `TRANSFER_SETTLED`, and (3) a `COMMAND_ACK` ahead of a pending value response
///         applies instead of failing on the gap. Both sides are real contracts throughout.
contract CcipValueNeutralVersionTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    ValueNeutralToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new ValueNeutralToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
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
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        vm.warp(1_700_000_000);
        vm.roll(1_000);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    // ------------------------------------------------------------------ helpers

    function _frontier() private view returns (uint64) {
        return executor.lastRemoteStateVersion(REMOTE_CHAIN);
    }

    function _propose(uint256 balance_, uint64 version_) private returns (uint256) {
        CcipObservation memory obs = dispatcher.observation();
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        return
            executor.proposeBalance(
                REMOTE_CHAIN,
                balance_,
                version_,
                uint64(block.number),
                uint64(block.timestamp),
                uint64(block.timestamp + 1 days),
                obs.trackedPositionSetHash
            );
    }

    function _attest(uint256 balance_, uint64 version_) private {
        uint256 id = _propose(balance_, version_);
        vm.prank(APPROVER);
        executor.approveBalance(id);
    }

    function _bridge(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
    }

    /// @dev 100e18 bridged and settled (dispatcher version 1 == frontier 1), then attested once.
    function _baseline() private {
        _bridge(100e18);
        assertEq(_frontier(), 1, "frontier after the settle");
        assertEq(dispatcher.stateVersion(), 1, "dispatcher version after the settle");
        _attest(100e18, 1);
        assertEq(executor.getBalance(), 100e18, "NAV baseline");
        vm.warp(block.timestamp + 1 hours); // attestation cadence limiter
    }

    function _newVault() private returns (MockRemoteVault) {
        return new MockRemoteVault(token, "Remote", "rUSDC");
    }

    function _allowVault(MockRemoteVault vault_) private {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault_);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
    }

    function _sendDeposit(MockRemoteVault vault_, uint256 amount_) private {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault_), amount_, 0)
            }),
            0,
            address(0),
            2_000_000
        );
    }

    /// @dev The README "Attesting while the response queue is stalled" decoding step: how many responses are
    ///      queued, how many of them are value-moving (they alone carry a version bump) and the sum of the
    ///      `amount` of the queued `TRANSFER_SETTLED` ones.
    function _queue() private view returns (uint256 total, uint256 valueMoving, uint256 settledAmount) {
        uint64 head = dispatcher.responseQueueHead();
        if (head == 0) return (0, 0, 0);
        uint64 tail = dispatcher.responseQueueTail();
        for (uint64 id = head; id <= tail; ++id) {
            (bytes memory data, , ) = dispatcher.queuedResponse(id);
            (CcipMsgType t, bytes memory inner) = CcipMessages.decode(data);
            ++total;
            if (t == CcipMsgType.TRANSFER_SETTLED) {
                ++valueMoving;
                (, uint256 amount, , ) = abi.decode(inner, (bytes32, uint256, uint256, uint64));
                settledAmount += amount;
            } else if (t == CcipMsgType.RETURN_TRANSFER) {
                ++valueMoving;
            }
        }
    }

    /// @dev The README version-delta check: `observation().stateVersion - lastRemoteStateVersion` must equal
    ///      the number of queued value-moving responses.
    function _versionDeltaMatchesQueue() private view returns (bool) {
        (, uint256 valueMoving, ) = _queue();
        return uint256(dispatcher.observation().stateVersion) - _frontier() == valueMoving;
    }

    /// @dev Delivery of everything the dispatcher sends fails, so its responses stall in the queue.
    function _stallQueue() private {
        router.setFailSend(address(dispatcher), true);
    }

    function _drainQueue() private {
        router.setFailSend(address(dispatcher), false);
        while (dispatcher.responseQueueHead() != 0) dispatcher.flushResponse();
    }

    /// @dev Hold every message (token-bearing ones too) so a test can deliver them in any order.
    function _holdAll() private {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
    }

    function _releaseAll() private {
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);
    }

    /// @dev With delivery held: bridge `amount_`, deliver the outbound to the dispatcher, and return the router
    ///      index of the dispatcher's undelivered `TRANSFER_SETTLED`.
    function _heldSettle(uint256 amount_) private returns (uint256 settleIndex) {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
        router.deliverHeld(router.heldCount() - 1);
        settleIndex = router.heldCount() - 1;
    }

    /// @dev With delivery held: send a balance request, run it on the dispatcher, and return the router index
    ///      of the dispatcher's undelivered `BALANCE_REPORT`.
    function _heldBalanceReport() private returns (uint256 reportIndex) {
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000);
        router.deliverHeld(router.heldCount() - 1);
        reportIndex = router.heldCount() - 1;
    }

    // ------------------------------------------------------------------ (a) dispatcher semantics

    /// @notice A balance request, a successful command and a cancelled command leave the version unchanged;
    ///         a settle and a recall each bump it by exactly one.
    function testDispatcherVersionCountsOnlyValueMovingResponses() public {
        _bridge(100e18);
        assertEq(dispatcher.stateVersion(), 1, "settle bumps by one");

        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000);
        assertEq(dispatcher.stateVersion(), 1, "BALANCE_REQUEST leaves the version unchanged");

        MockRemoteVault vault = _newVault();
        _allowVault(vault); // a successful UPDATE_VAULTS command -> COMMAND_ACK
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "the command was acknowledged");
        assertEq(dispatcher.stateVersion(), 1, "a successful command leaves the version unchanged");

        // A command that fails on the dispatcher (vault not allowlisted) is NACKed, then cancelled: the cancel
        // ACK leaves the version unchanged too.
        MockRemoteVault notAllowed = _newVault();
        _sendDeposit(notAllowed, 1e18);
        bytes32 doomed = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(doomed)), uint8(CommandStatus.FAILED), "NACKed");
        assertEq(dispatcher.stateVersion(), 1, "a NACK leaves the version unchanged");
        executor.cancelCommand(REMOTE_CHAIN, doomed, 0, address(0), 2_000_000);
        assertEq(uint8(executor.commandStatus(doomed)), uint8(CommandStatus.CANCELLED), "cancel acknowledged");
        assertEq(dispatcher.stateVersion(), 1, "a command cancel leaves the version unchanged");

        // A recall (RETURN_TRANSFER) bumps it again by one, and the executor follows.
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 10e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.stateVersion(), 2, "a recall bumps by one");
        assertEq(_frontier(), 2, "the executor frontier follows both value-moving responses and nothing else");
    }

    // ------------------------------------------------------------------ (b) stalled queue, honest attestation

    /// @notice R-07 itself: the queue is stalled behind a BALANCE_REPORT and a COMMAND_ACK. Both are
    ///         value-neutral, so `observation().stateVersion` still equals the executor frontier and the honest
    ///         attestation with the observed version is accepted. NAV is exact before and after the queue
    ///         drains.
    function testHonestAttestationSucceedsWhileQueueIsStalledBehindValueNeutralResponses() public {
        _baseline();
        _stallQueue();
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000); // BALANCE_REPORT queued
        MockRemoteVault vault = _newVault();
        _allowVault(vault); // COMMAND_ACK queued behind it
        (uint256 total, uint256 valueMoving, ) = _queue();
        assertEq(total, 2, "BALANCE_REPORT + COMMAND_ACK queued");
        assertEq(valueMoving, 0, "none of them moves value");
        assertEq(executor.activeCommand(REMOTE_CHAIN) != bytes32(0), true, "the command awaits its (stuck) ACK");

        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.stateVersion, _frontier(), "observation version == frontier despite the stall");
        assertTrue(_versionDeltaMatchesQueue(), "README delta check: 0 == 0");

        _attest(obs.accountedBalance, obs.stateVersion);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
        assertEq(executor.getBalance(), 100e18, "NAV exact with the queue stalled");

        _drainQueue();
        assertEq(_frontier(), obs.stateVersion, "value-neutral responses never move the frontier");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "the ACK resolved the command");
        assertEq(executor.getBalance(), 100e18, "NAV exact after the queue drains");
    }

    /// @notice Dropping a stuck value-neutral response with the timelocked skip valve costs nothing: it carried
    ///         no version, so the honest attestation keeps working and no `ADVANCE_FRONTIER` rescue is needed.
    function testSkippingAStuckBalanceReportLeavesNoFrontierGap() public {
        _baseline();
        _stallQueue();
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000);
        uint64 stuck = dispatcher.responseQueueHead();
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, stuck);
        router.setFailSend(address(dispatcher), false);

        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.stateVersion, _frontier(), "no version was lost with the dropped report");
        assertTrue(_versionDeltaMatchesQueue());
        _attest(obs.accountedBalance, obs.stateVersion);
        assertEq(executor.getBalance(), 100e18, "NAV exact");
        // The next value-moving response is contiguous.
        _bridge(10e18);
        assertEq(_frontier(), obs.stateVersion + 1);
    }

    // ------------------------------------------------------------------ (c) the reorder trap

    /// @notice CCIP 2.0 delivers out of order (IL-8496). A BALANCE_REPORT carrying V+1 (because a
    ///         TRANSFER_SETTLED V+1 is still in transit) arrives first. It is evidence only: the frontier does
    ///         not move and the settle that follows applies and credits `settled` exactly once. If the report
    ///         advanced the frontier the settle would be dropped as stale and the credit lost.
    function testBalanceReportOvertakingATransferSettledNeverMovesTheFrontier() public {
        _baseline();
        _holdAll();
        uint256 settleIndex = _heldSettle(10e18);
        assertEq(dispatcher.stateVersion(), 2, "the settle bumped the dispatcher version");
        uint256 reportIndex = _heldBalanceReport();
        assertEq(dispatcher.stateVersion(), 2, "the report did not");
        uint256 reportedBalance = dispatcher.accountedBalance();

        // The report (version 2) overtakes the settle (version 2).
        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipExecutorCommandLib.RemoteBalanceUpdated(REMOTE_CHAIN, reportedBalance, 2);
        router.deliverHeld(reportIndex);
        assertEq(_frontier(), 1, "the report is evidence only: frontier unchanged");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 10e18, "the transfer is still in flight");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
        assertEq(executor.getBalance(), 110e18, "NAV counts the in-flight transfer");

        // The settle then applies: contiguous (== frontier + 1), credited exactly once.
        router.deliverHeld(settleIndex);
        assertEq(_frontier(), 2);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e18, "credited exactly once");
        assertEq(executor.getBalance(), 110e18);
        _releaseAll();
    }

    // ------------------------------------------------------------------ (d) command lane liveness

    /// @notice A COMMAND_ACK carrying V+1 arrives while the TRANSFER_SETTLED V+1 is still in transit. It
    ///         applies (no `StateVersionGap`), resolves the command and leaves the frontier alone; the settle
    ///         still applies afterwards.
    function testCommandAckAheadOfAPendingValueResponseApplies() public {
        _baseline();
        _holdAll();
        uint256 settleIndex = _heldSettle(10e18);
        assertEq(dispatcher.stateVersion(), 2);

        MockRemoteVault vault = _newVault();
        _allowVault(vault); // the command is held
        bytes32 commandId = executor.activeCommand(REMOTE_CHAIN);
        router.deliverHeld(router.heldCount() - 1); // the dispatcher runs it; its ACK is held
        uint256 ackIndex = router.heldCount() - 1;
        assertEq(dispatcher.stateVersion(), 2, "the command did not bump the version");

        router.deliverHeld(ackIndex); // must not revert with StateVersionGap
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "command resolved");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "ACK applied");
        assertEq(_frontier(), 1, "the ACK did not move the frontier");

        router.deliverHeld(settleIndex);
        assertEq(_frontier(), 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e18, "the settle credited exactly once");
        _releaseAll();
    }

    // ------------------------------------------------------------------ (e) T5: return off the queue, signal preserved

    /// @notice The recall's RETURN_TRANSFER left the queue but has not executed on the executor (in transit or
    ///         FAILED on the OffRamp); a BALANCE_REPORT stalls the queue. The dispatcher version is ahead of the
    ///         frontier by the version of the return on the wire, so the honest proposal with
    ///         `observation().stateVersion` reverts `ProposalVersionMismatch` (the safety signal is preserved)
    ///         and the README version-delta check detects the surplus. Once the return is delivered the check
    ///         passes and the attestation is exact.
    function testReturnOffTheQueueKeepsTheVersionSignalAndTheDeltaCheckDetectsIt() public {
        _baseline();

        _stallQueue();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 15e18, 15e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.stateVersion(), 2, "the recall bumped the version");

        // The RETURN_TRANSFER leaves the queue but is held on the wire.
        router.setFailSend(address(dispatcher), false);
        _holdAll();
        dispatcher.flushResponse();
        uint256 heldReturn = router.heldCount() - 1;
        assertEq(dispatcher.responseQueueHead(), 0, "queue empty: the return is on the wire");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "the executor debits only on delivery");

        // A harmless BALANCE_REPORT stalls the queue.
        _stallQueue();
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000); // held
        router.deliverHeld(router.heldCount() - 1);
        (uint256 total, uint256 valueMoving, ) = _queue();
        assertEq(total, 1, "exactly one queued response");
        assertEq(valueMoving, 0, "and it moves no value");

        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.stateVersion, 2, "the report did not bump the version");
        assertEq(_frontier(), 1);

        // The signal: an honest proposal with the observed version is refused...
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalVersionMismatch.selector, uint64(1), uint64(2))
        );
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        executor.proposeBalance(
            REMOTE_CHAIN,
            obs.accountedBalance,
            obs.stateVersion,
            uint64(block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            obs.trackedPositionSetHash
        );
        // ...and the README delta check reports the surplus (delta 1 against 0 queued value responses).
        assertFalse(_versionDeltaMatchesQueue(), "surplus: a value response is on the wire, do not attest");

        // Deliver the return first, as the README prescribes: the check now passes.
        router.deliverHeld(heldReturn);
        assertEq(_frontier(), 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 85e18, "the return debited the recall once");
        assertTrue(_versionDeltaMatchesQueue(), "delta 0 == 0");
        vm.warp(block.timestamp + 1 hours);
        obs = dispatcher.observation();
        _attest(obs.accountedBalance, obs.stateVersion);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 85e18, "settled == remote balance");
        assertEq(executor.idleLedger(), 15e18, "the recalled tokens are home");
        assertEq(executor.getBalance(), 100e18, "NAV exact: 85 remote + 15 home, nothing debited twice");
        _releaseAll();
    }

    // ------------------------------------------------------- (f) T4: reconciled attestation over a queued settle

    /// @notice The queue holds a TRANSFER_SETTLED (and a BALANCE_REPORT behind it). The version delta equals the
    ///         number of queued value-moving responses, so the README applies: attest at the frontier version
    ///         with `accountedBalance - queued settled amount`. NAV stays exact before and after the queue drains.
    function testReconciledAttestationOverAQueuedTransferSettledKeepsNavExact() public {
        _baseline();
        _stallQueue();
        _bridge(15e18); // the dispatcher counts it; its TRANSFER_SETTLED is stuck in the queue
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000); // a value-neutral response behind it
        (uint256 total, uint256 valueMoving, uint256 settledAmount) = _queue();
        assertEq(total, 2);
        assertEq(valueMoving, 1);
        assertEq(settledAmount, 15e18);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 15e18, "the executor still holds it in flight");

        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.stateVersion, 2);
        assertEq(_frontier(), 1);
        assertEq(obs.accountedBalance, 115e18, "the dispatcher already counts the delivery");
        assertTrue(_versionDeltaMatchesQueue(), "delta 1 == 1 queued value response");

        _attest(obs.accountedBalance - settledAmount, uint64(_frontier()));
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
        assertEq(executor.getBalance(), 115e18, "NAV exact: settled 100 + in flight 15");

        _drainQueue();
        assertEq(_frontier(), 2, "only the settle moved the frontier");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 115e18);
        assertEq(executor.getBalance(), 115e18, "NAV exact after the queue drains");
    }

    /// @notice Without the reconciliation the observed balance double counts the queued settle; this is why the
    ///         README subtracts it. The next honest attestation (delta 0) corrects it.
    function testAttestingTheObservedBalanceOverAQueuedTransferSettledDoubleCountsUntilCorrected() public {
        _baseline();
        _stallQueue();
        _bridge(15e18);
        CcipObservation memory obs = dispatcher.observation();
        _attest(obs.accountedBalance, uint64(_frontier())); // 115e18 at the frontier version
        assertEq(executor.getBalance(), 130e18, "double counted: settled 115 + in flight 15");
        _drainQueue();
        vm.warp(block.timestamp + 1 hours);
        obs = dispatcher.observation();
        assertEq(obs.stateVersion, _frontier());
        _attest(obs.accountedBalance, obs.stateVersion);
        assertEq(executor.getBalance(), 115e18, "corrected by the next honest attestation");
    }
}
