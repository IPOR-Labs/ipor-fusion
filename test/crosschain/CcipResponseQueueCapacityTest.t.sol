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
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";

contract QueueCapToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipResponseQueueCapacityTest
/// @notice IL-8583: a full response queue must not revert value-moving or NACK traffic.
///
///         The dispatcher queue holds 64 live responses. `BALANCE_REPORT` and `COMMAND_ACK` (value-neutral) stop at
///         56; `TRANSFER_SETTLED`, `RETURN_TRANSFER`, `RETURN_REJECTED` and `COMMAND_NACK` use the reserved last 8.
///         A queued `BALANCE_REPORT` is rewritten by the next request instead of growing the queue, and
///         `flushResponse(maxCount)` drains in bulk. Messages are injected straight into the real dispatcher as the
///         router, so a stalled head (failed sends) keeps the queue filling.
contract CcipResponseQueueCapacityTest is Test {
    uint256 internal constant NEUTRAL_CAP = 56;
    uint256 internal constant HARD_CAP = 64;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;
    MockCcipRouter internal router;
    QueueCapToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new QueueCapToken();
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

    uint256 private _nonce;

    function _stall() private {
        router.setFailSend(address(dispatcher), true);
    }

    function _inject(bytes memory data_, uint256 tokenAmount_) private {
        CcipClient.EVMTokenAmount[] memory delivered = new CcipClient.EVMTokenAmount[](tokenAmount_ == 0 ? 0 : 1);
        if (tokenAmount_ != 0) {
            token.mint(address(dispatcher), tokenAmount_);
            delivered[0] = CcipClient.EVMTokenAmount({token: address(token), amount: tokenAmount_});
        }
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("queue-cap", ++_nonce)),
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(address(executor)),
                data: data_,
                destTokenAmounts: delivered
            })
        );
    }

    function _commandId() private returns (bytes32) {
        return bytes32((block.timestamp + 1 days) << 192 | ++_nonce);
    }

    function _command(CcipMsgType type_, uint8 action_, bytes memory actionData_, bytes memory extra_)
        private
        returns (bytes memory)
    {
        return
            CcipMessages.encode(
                type_,
                abi.encode(
                    type_,
                    Command({
                        commandId: _commandId(),
                        sequence: dispatcher.nextCommandSequence(),
                        commandConfigEpoch: dispatcher.commandConfigEpoch(),
                        action: action_,
                        minExecutionGas: 0,
                        actionData: actionData_
                    }),
                    extra_
                )
            );
    }

    /// @dev A successful empty `UPDATE_VAULTS` command: queues one `COMMAND_ACK`.
    function _injectAck() private {
        _inject(_command(CcipMsgType.UPDATE_VAULTS, 0, "", abi.encode(new address[](0), true, false)), 0);
    }

    /// @dev A deposit into a vault that is not allowlisted: the command fails and queues a `COMMAND_NACK`.
    function _failingCommand() private returns (bytes memory) {
        return
            _command(
                CcipMsgType.COMMAND,
                uint8(BusinessAction.DEPOSIT),
                CrosschainMessages.encodeDepositAction(address(0xDEAD), 1e18, 0),
                ""
            );
    }

    function _injectBalanceRequest() private {
        _inject(CcipMessages.encode(CcipMsgType.BALANCE_REQUEST, ""), 0);
    }

    function _injectOutbound(uint256 amount_) private {
        _inject(CcipMessages.encode(CcipMsgType.OUTBOUND_TRANSFER, abi.encode(keccak256(abi.encode(++_nonce)))), amount_);
    }

    function _injectRecall(uint256 amount_) private {
        _inject(
            CcipMessages.encode(
                CcipMsgType.RETURN_REQUEST,
                abi.encode(keccak256(abi.encode(++_nonce)), amount_, type(uint128).max, uint256(1), type(uint256).max)
            ),
            0
        );
    }

    function _live() private view returns (uint256) {
        uint64 head = dispatcher.responseQueueHead();
        return head == 0 ? 0 : uint256(dispatcher.responseQueueTail() - head) + 1;
    }

    function _fillNeutral() private {
        _stall();
        for (uint256 i; i < NEUTRAL_CAP; ++i) _injectAck();
        assertEq(_live(), NEUTRAL_CAP, "56 neutral responses queued");
        // Proves the soft cap is active, so a reserved type landing afterwards is the reservation at work.
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainDispatcher.ResponseQueueNeutralCapReached.selector, NEUTRAL_CAP, NEUTRAL_CAP)
        );
        this.injectAckExternal();
    }

    function _typeAt(uint64 id_) private view returns (CcipMsgType t) {
        (bytes memory data, , ) = dispatcher.queuedResponse(id_);
        (t, ) = CcipMessages.decode(data);
    }

    // ------------------------------------------------------------------ soft cap

    function testShouldRejectNeutralResponseAtSoftCap() public {
        _fillNeutral();
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainDispatcher.ResponseQueueNeutralCapReached.selector, NEUTRAL_CAP, NEUTRAL_CAP)
        );
        this.injectAckExternal();
        // No BALANCE_REPORT is queued yet, so a request has nothing to coalesce into and hits the cap too.
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainDispatcher.ResponseQueueNeutralCapReached.selector, NEUTRAL_CAP, NEUTRAL_CAP)
        );
        this.injectBalanceRequestExternal();
        assertEq(_live(), NEUTRAL_CAP, "nothing was appended");
    }

    function injectAckExternal() external {
        _injectAck();
    }

    function injectBalanceRequestExternal() external {
        _injectBalanceRequest();
    }

    function testShouldStillDeliverTokensWhenNeutralCapIsReached() public {
        _fillNeutral();
        uint256 idleBefore = dispatcher.trackedIdle();
        _injectOutbound(100e18);
        assertEq(dispatcher.trackedIdle(), idleBefore + 100e18, "tokens credited");
        assertEq(_live(), NEUTRAL_CAP + 1, "TRANSFER_SETTLED got a reserved slot");
        assertEq(uint8(_typeAt(dispatcher.responseQueueTail())), uint8(CcipMsgType.TRANSFER_SETTLED));
        assertEq(dispatcher.stateVersion(), 1, "version bumped");
    }

    function testShouldStillNackFailedCommandWhenNeutralCapIsReached() public {
        _fillNeutral();
        bytes memory failing = _failingCommand();
        _inject(failing, 0);
        assertEq(_live(), NEUTRAL_CAP + 1, "COMMAND_NACK got a reserved slot");
        assertEq(uint8(_typeAt(dispatcher.responseQueueTail())), uint8(CcipMsgType.COMMAND_NACK));
        assertEq(dispatcher.nextCommandSequence(), NEUTRAL_CAP, "the failed command did not advance the sequence");
        (, bytes memory inner) = CcipMessages.decode(failing);
        (, Command memory failedCommand,) = abi.decode(inner, (CcipMsgType, Command, bytes));
        assertEq(
            uint8(dispatcher.commandStatus(failedCommand.commandId)),
            uint8(CommandStatus.FAILED),
            "command recorded as FAILED"
        );
    }

    function testShouldStillAnswerRecallWhenNeutralCapIsReached() public {
        _injectOutbound(100e18);
        _fillNeutral();
        _injectRecall(40e18);
        assertEq(_live(), NEUTRAL_CAP + 1, "RETURN_TRANSFER fits above the neutral cap");
        assertEq(uint8(_typeAt(dispatcher.responseQueueTail())), uint8(CcipMsgType.RETURN_TRANSFER));
    }

    function testShouldStillAnswerRejectedRecallAtSoftCap() public {
        _fillNeutral();
        _injectRecall(40e18); // no tracked idle: RETURN_REJECTED(NO_TRACKED_IDLE)
        assertEq(_live(), NEUTRAL_CAP + 1, "RETURN_REJECTED fits above the neutral cap");
        assertEq(uint8(_typeAt(dispatcher.responseQueueTail())), uint8(CcipMsgType.RETURN_REJECTED));
    }

    function testShouldRollBackSucceededCommandRefusedAtSoftCap() public {
        _fillNeutral();
        uint256 epochBefore = dispatcher.commandConfigEpoch();
        uint64 seqBefore = dispatcher.nextCommandSequence();
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainDispatcher.ResponseQueueNeutralCapReached.selector, NEUTRAL_CAP, NEUTRAL_CAP)
        );
        this.injectAckExternal();
        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "epoch unchanged");
        assertEq(dispatcher.nextCommandSequence(), seqBefore, "sequence unchanged");
        assertEq(_live(), NEUTRAL_CAP, "nothing appended");
    }

    function testShouldCoalesceBalanceRequestAtSoftAndHardCap() public {
        _stall();
        _injectBalanceRequest(); // id 1, the queued report
        for (uint256 i; i < NEUTRAL_CAP - 1; ++i) _injectAck();
        assertEq(_live(), NEUTRAL_CAP);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.ResponseCoalesced(1);
        _injectBalanceRequest();
        assertEq(_live(), NEUTRAL_CAP, "coalesced at the soft cap");
        for (uint256 i; i < HARD_CAP - NEUTRAL_CAP; ++i) _injectOutbound(1e18);
        assertEq(_live(), HARD_CAP);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.ResponseCoalesced(1);
        _injectBalanceRequest();
        assertEq(_live(), HARD_CAP, "coalesced at the hard cap");
    }

    function testShouldAppendNewReportAfterSkipDroppedTheQueuedOne() public {
        _stall();
        _injectBalanceRequest(); // id 1, the queued report and the head
        _injectAck(); // id 2
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(1);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, 1);
        assertEq(dispatcher.responseQueueHead(), 2, "report dropped");
        _injectBalanceRequest();
        assertEq(dispatcher.responseQueueTail(), 3, "a fresh report entry was appended");
        assertEq(uint8(_typeAt(3)), uint8(CcipMsgType.BALANCE_REPORT));
        assertEq(_live(), 2);
    }

    // ------------------------------------------------------------------ hard cap

    function testShouldRevertEverythingOnlyAtHardCap() public {
        _fillNeutral();
        for (uint256 i; i < HARD_CAP - NEUTRAL_CAP; ++i) _injectOutbound(1e18);
        assertEq(_live(), HARD_CAP, "64 live responses");
        bytes4 full = CcipCrosschainDispatcher.ResponseQueueFull.selector;
        vm.expectRevert(abi.encodeWithSelector(full, HARD_CAP));
        this.injectOutboundExternal();
        vm.expectRevert(abi.encodeWithSelector(full, HARD_CAP));
        this.injectAckExternal();
        assertEq(_live(), HARD_CAP, "unchanged");
    }

    function injectOutboundExternal() external {
        _injectOutbound(1e18);
    }

    // ------------------------------------------------------------------ coalescing

    function testShouldCoalesceQueuedBalanceReports() public {
        _stall();
        _injectBalanceRequest();
        assertEq(_live(), 1, "one report queued");
        (bytes memory first, , ) = dispatcher.queuedResponse(1);

        _injectOutbound(100e18); // TRANSFER_SETTLED queued behind it, balance now 100e18
        assertEq(_live(), 2);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.ResponseCoalesced(1);
        _injectBalanceRequest();
        _injectBalanceRequest();

        assertEq(_live(), 2, "requests coalesced, the queue did not grow");
        assertEq(dispatcher.responseQueueTail(), 2, "no id consumed");
        (bytes memory refreshed, , ) = dispatcher.queuedResponse(1);
        assertTrue(keccak256(refreshed) != keccak256(first), "payload rewritten");
        (, bytes memory inner) = CcipMessages.decode(refreshed);
        (uint256 balance, uint64 version) = abi.decode(inner, (uint256, uint64));
        assertEq(balance, 100e18, "fresh balance");
        assertEq(version, 1, "current stateVersion");

        // Once the report is sent, the next request queues a new one.
        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse(10);
        assertEq(dispatcher.responseQueueHead(), 0);
        _injectBalanceRequest();
        assertEq(dispatcher.responseQueueTail(), 3, "a new report is appended after the old one left");
    }

    // ------------------------------------------------------------------ flush

    function testShouldFlushManyResponses() public {
        _stall();
        for (uint256 i; i < 5; ++i) _injectAck();
        router.setFailSend(address(dispatcher), false);
        assertEq(dispatcher.flushResponse(0), 0, "zero count sends nothing");
        assertEq(dispatcher.flushResponse(3), 3, "bounded by maxCount");
        assertEq(dispatcher.responseQueueHead(), 4);
        assertEq(dispatcher.flushResponse(10), 2, "bounded by the queue");
        assertEq(dispatcher.responseQueueHead(), 0);
        vm.expectRevert(CcipCrosschainDispatcher.NoQueuedResponse.selector);
        dispatcher.flushResponse(1);
        _stall();
        _injectAck();
        router.setFailSend(address(dispatcher), false);
        assertTrue(dispatcher.flushResponse() != bytes32(0), "single flush still works");
    }

    function testShouldStopFlushAtFirstUndeliverable() public {
        _stall();
        _injectOutbound(100e18); // TRANSFER_SETTLED
        _injectAck();
        _injectAck();
        _injectRecall(40e18); // RETURN_TRANSFER, token-bearing
        _injectAck();
        assertEq(_live(), 5);
        router.setFailSend(address(dispatcher), false);
        router.setFailSendWith(address(dispatcher), hex"deadbeef"); // only token-bearing sends fail
        assertEq(dispatcher.flushResponse(10), 3, "stopped before the token-bearing head");
        assertEq(dispatcher.responseQueueHead(), 4);
        vm.expectRevert(bytes(hex"deadbeef"));
        dispatcher.flushResponse(10); // first send failing reverts like flushResponse()
        router.setFailSendWith(address(dispatcher), "");
        assertEq(dispatcher.flushResponse(10), 2, "repaired: drains the rest");
        vm.expectRevert(CcipCrosschainDispatcher.NoQueuedResponse.selector);
        dispatcher.flushResponse(10);
    }
}
