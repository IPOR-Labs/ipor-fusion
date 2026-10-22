// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipAppBase} from "../../contracts/crosschain/ccip/base/CcipAppBase.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipExecutorCommandLib, ReceiptIgnoreReason} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {
    BusinessAction,
    CcipChainRescue,
    CommandResolution,
    CommandStatus,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

contract ExpiryToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipExpiredCancelTest
/// @notice IL-8594 (Ackee TP-M-16): a CANCEL_COMMAND that outlives its command's deadline closes the command on the
///         real CCIP dispatcher WITHOUT consuming its sequence, so it cannot consume a sequence the executor re-used
///         for a replacement. The dispatcher answers with an authenticated `EXPIRED` receipt: the executor frees the
///         slot only for the FAILED command that still owns it, so the manager's post-TTL cancel ends a stall without
///         the admin, and the same receipt is ignored when the slot holds a replacement.
/// @dev Fixtures are those of `CcipCommandExpiryTest`; `MockCcipRouter.deliverHeld` models a message retained
///      (FAILED) on the OffRamp and executed later.
contract CcipExpiredCancelTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    address internal constant ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    ExpiryToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    event CommandFailed(bytes32 commandId, uint64 sequence);

    function setUp() public {
        router = new MockCcipRouter();
        token = new ExpiryToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router), factory, address(this), address(token), keccak256("USDC"), 18, _safety()
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
            ADMIN,
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
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: ADMIN,
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

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _abandon(bool consumed_) internal {
        uint256 arg = consumed_ ? 1 : 0;
        vm.prank(ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, arg);
    }

    function _realign(uint64 epoch_, uint64 sequence_) internal {
        uint256 arg = (uint256(executor.commandConfigEpoch(REMOTE_CHAIN)) << 192)
            | (uint256(executor.nextCommandSequence(REMOTE_CHAIN)) << 128) | (uint256(epoch_) << 64) | uint256(sequence_);
        vm.prank(ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
    }

    function _attestBalance(uint256 balance_) internal {
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    function _fundRemoteIdle(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
        _attestBalance(dispatcher.accountedBalance());
    }

    function _allowVaults(address[] memory vaults_) internal returns (bytes32 commandId) {
        executor.updateVaults(REMOTE_CHAIN, vaults_, true, true, 0, address(0), 2_000_000);
        commandId = executor.activeCommand(REMOTE_CHAIN);
    }

    function _oneVault(address vault_) internal pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = vault_;
    }

    /// @dev Send a DEPOSIT whose message is held rather than delivered. Returns its id and held index.
    function _holdDeposit(MockRemoteVault vault_, uint256 amount_) internal returns (bytes32 commandId, uint256 held) {
        router.setAutoDeliver(false);
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
        router.setAutoDeliver(true);
        commandId = executor.activeCommand(REMOTE_CHAIN);
        held = router.heldCount() - 1;
    }

    function _deployAndAllowVault() internal returns (MockRemoteVault vault) {
        vault = new MockRemoteVault(token, "Remote", "rUSDC");
        _allowVaults(_oneVault(address(vault)));
    }

    function _assertMirrorsMatchDispatcher(string memory label_) internal view {
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), dispatcher.nextCommandSequence(), label_);
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), label_);
    }

    // ---------------------------------------------------------------------
    // Scenario
    // ---------------------------------------------------------------------

    /// @dev D1 NACKs (delivered late), the operator's CANCEL is retained, the executor abandons D1 after the
    ///      deadline plus margin and sends a replacement D2 (held) at the SAME sequence.
    function _staleCancelScenario(MockRemoteVault vault_)
        internal
        returns (bytes32 d1, bytes32 d2, uint256 cancelHeld, uint256 replacementHeld)
    {
        uint256 d1Held;
        (d1, d1Held) = _holdDeposit(vault_, 10e18);
        vm.warp(CrosschainMessages.commandDeadline(d1) + 1);
        router.deliverHeld(d1Held);
        assertEq(uint8(dispatcher.commandStatus(d1)), uint8(CommandStatus.FAILED), "D1 NACKed");

        router.setAutoDeliver(false);
        executor.cancelCommand(REMOTE_CHAIN, d1, 0, address(0), 2_000_000);
        router.setAutoDeliver(true);
        cancelHeld = router.heldCount() - 1;

        _abandon(false);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "D1 abandoned");
        (d2, replacementHeld) = _holdDeposit(vault_, 5e18);
        assertEq(executor.activeCommand(REMOTE_CHAIN), d2, "replacement owns the slot");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), dispatcher.nextCommandSequence(), "same sequence");
    }

    /// @dev Rewritten for the EXPIRED receipt (was "no ACK sent"): the expired cancel still closes the command and
    ///      leaves the sequence alone, but it now answers with an `EXPIRED` receipt, which the executor ignores
    ///      because the slot holds the replacement. The replacement then runs at the same sequence.
    function testShouldIgnoreExpiredCancelWithoutConsumingSequence() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        (bytes32 d1, bytes32 d2, uint256 cancelHeld, uint256 replacementHeld) = _staleCancelScenario(vault);
        uint64 sequence = dispatcher.nextCommandSequence();
        uint256 idleBefore = dispatcher.trackedIdle();

        // The receipt the cancel produces is held here so its content can be checked before it reaches the executor.
        router.setAutoDeliver(false);
        uint256 heldBefore = router.heldCount();
        vm.recordLogs();
        router.deliverHeld(cancelHeld);
        _assertExpiredIgnoredEmitted(d1, sequence);
        assertEq(router.heldCount(), heldBefore + 1, "one EXPIRED receipt sent");
        (bytes32 ackId, uint64 ackSequence,,,,, uint8 resolution) = abi.decode(
            _heldAckPayload(router.heldCount() - 1), (bytes32, uint64, int256, uint256, uint64, uint64, uint8)
        );
        assertEq(ackId, d1, "receipt names the expired command");
        assertEq(ackSequence, sequence, "at its unconsumed sequence");
        assertEq(resolution, uint8(CommandResolution.EXPIRED), "resolution EXPIRED");

        assertEq(dispatcher.nextCommandSequence(), sequence, "sequence not consumed");
        assertEq(uint8(dispatcher.commandStatus(d1)), uint8(CommandStatus.CANCELLED), "expired command closed");

        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipCrosschainExecutor.CommandReceiptIgnored(
            REMOTE_CHAIN, d1, uint8(CcipMsgType.COMMAND_ACK), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED)
        );
        router.deliverHeld(router.heldCount() - 1);
        router.setAutoDeliver(true);
        assertEq(executor.activeCommand(REMOTE_CHAIN), d2, "replacement still active");
        assertEq(uint8(executor.commandStatus(d2)), uint8(CommandStatus.PENDING), "and still PENDING");

        router.deliverHeld(replacementHeld);
        assertEq(uint8(dispatcher.commandStatus(d2)), uint8(CommandStatus.SUCCEEDED), "replacement executed");
        assertEq(dispatcher.trackedIdle(), idleBefore - 5e18, "its deposit ran");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "resolved by its own receipt");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    function testShouldStillCancelBeforeDeadline() public {
        _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        // A command that NACKs inside its window (its vault is not allowlisted).
        bytes32 bad = _nackedWithinWindow(new MockRemoteVault(token, "Other", "oUSDC"));
        uint64 sequence = dispatcher.nextCommandSequence();
        assertLe(block.timestamp, CrosschainMessages.commandDeadline(bad), "inside the window");

        executor.cancelCommand(REMOTE_CHAIN, bad, 0, address(0), 2_000_000);

        assertEq(uint8(dispatcher.commandStatus(bad)), uint8(CommandStatus.CANCELLED), "cancelled");
        assertEq(dispatcher.nextCommandSequence(), sequence + 1, "sequence consumed");
        assertEq(uint8(executor.commandStatus(bad)), uint8(CommandStatus.CANCELLED), "CANCELLED ACK applied");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    function testShouldNotReexecuteIgnoredCancel() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        (bytes32 d1,, uint256 cancelHeld,) = _staleCancelScenario(vault);
        uint64 sequence = dispatcher.nextCommandSequence();

        router.deliverHeld(cancelHeld);
        assertEq(uint8(dispatcher.commandStatus(d1)), uint8(CommandStatus.CANCELLED), "closed by the no-op");

        // The base replay guard refuses the same CCIP message a second time.
        try router.deliverHeld(cancelHeld) {
            fail("second delivery must not execute");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CcipAppBase.CcipMessageAlreadyProcessed.selector, "replay refused");
        }
        assertEq(dispatcher.nextCommandSequence(), sequence, "sequence still untouched");
    }

    /// @dev An expired cancel no longer produces a CANCELLED receipt, but a CANCELLED ACK from a cancel that ran
    ///      inside the window and arrived after the abandon can still retire a replacement legitimately. This
    ///      test drives the same adopt branch with a late SUCCEEDED ACK instead.
    function testShouldAlertWhenLateReceiptRetiresPendingReplacement() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        router.setFailSend(address(dispatcher), true);
        bytes32 c1 = _holdDepositDelivered(vault, 50e18);
        _abandon(false);
        router.setAutoDeliver(false);
        bytes32 c2 = _holdDepositDelivered(vault, 10e18);
        router.setAutoDeliver(true);
        assertEq(executor.activeCommand(REMOTE_CHAIN), c2, "replacement PENDING in the slot");

        router.setFailSend(address(dispatcher), false);
        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipExecutorCommandLib.LateReceiptRetiredPendingReplacement(
            REMOTE_CHAIN, executor.nextCommandSequence(REMOTE_CHAIN), c2
        );
        dispatcher.flushResponse();

        assertEq(uint8(executor.commandStatus(c1)), uint8(CommandStatus.SUCCEEDED), "late receipt adopted");
        assertEq(uint8(executor.commandStatus(c2)), uint8(CommandStatus.CANCELLED), "replacement retired");
    }

    function _assertExpiredIgnoredEmitted(bytes32 commandId_, uint64 sequence_) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory expected = abi.encode(
            block.chainid, commandId_, sequence_, uint64(CrosschainMessages.commandDeadline(commandId_))
        );
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(dispatcher)
                    && logs[i].topics[0] == CcipCrosschainDispatcher.CancelCommandExpiredIgnored.selector
            ) {
                assertEq(logs[i].data, expected, "event payload");
                return;
            }
        }
        fail("CancelCommandExpiredIgnored not emitted");
    }

    /// @dev A deposit into a vault that is not allowlisted reverts on the dispatcher, i.e. NACKs inside its window.
    function _nackedWithinWindow(MockRemoteVault vault_) internal returns (bytes32 commandId) {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault_), 10e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        commandId = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACKed");
    }

    /// @dev Sends a deposit with auto-delivery as currently configured and returns its id.
    function _holdDepositDelivered(MockRemoteVault vault_, uint256 amount_) internal returns (bytes32 commandId) {
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
        commandId = executor.activeCommand(REMOTE_CHAIN);
    }

    // ---------------------------------------------------------------------
    // IL-8594 follow-up: the authenticated EXPIRED receipt
    // ---------------------------------------------------------------------

    function _prepared() internal returns (MockRemoteVault vault) {
        vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
    }

    /// @dev The inner payload of a held dispatcher -> executor CCIP message.
    function _heldAckPayload(uint256 index_) internal view returns (bytes memory data) {
        (, data) = CcipMessages.decode(router.heldData(index_));
    }

    function _countLogs(Vm.Log[] memory logs_, address emitter_, bytes32 topic0_) internal pure returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length != 0 && logs_[i].topics[0] == topic0_) ++n;
        }
    }

    /// @dev Hold the manager's CANCEL for `id_` instead of delivering it.
    function _holdCancel(bytes32 id_) internal returns (uint256 held) {
        router.setAutoDeliver(false);
        executor.cancelCommand(REMOTE_CHAIN, id_, 0, address(0), 2_000_000);
        router.setAutoDeliver(true);
        held = router.heldCount() - 1;
    }

    /// @dev Arm ABANDON_COMMAND now. It can execute once `RESCUE_DELAY` and deadline + margin have both passed.
    function _armAbandon(bool consumed_) internal returns (uint256 rescueId) {
        vm.prank(ADMIN);
        rescueId = executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, consumed_ ? 1 : 0);
    }

    /// @dev Execute the armed abandon at the earliest second it is allowed (executor clock) and return that second.
    function _executeAbandonAtEarliest(uint256 rescueId_, bool consumed_, bytes32 id_, uint256 armedAt_)
        internal
        returns (uint256 executorNow)
    {
        executorNow = CrosschainMessages.commandDeadline(id_) + CrosschainConstants.COMMAND_EXPIRY_MARGIN + 1;
        if (executorNow < armedAt_ + RESCUE_DELAY) executorNow = armedAt_ + RESCUE_DELAY;
        vm.warp(executorNow);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId_, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, consumed_ ? 1 : 0);
    }

    /// @dev C1: a DEPOSIT into a vault that is NOT allowlisted reverts `VaultNotAllowed` (decodable), so the
    ///      dispatcher records FAILED and NACKs INSIDE the command's window, exactly the Ackee precondition.
    function _c1NackedInWindow() internal returns (bytes32 c1, uint64 s) {
        c1 = _nackedWithinWindow(new MockRemoteVault(token, "Other", "oUSDC"));
        s = dispatcher.nextCommandSequence();
        assertEq(uint8(executor.commandStatus(c1)), uint8(CommandStatus.FAILED), "C1 NACK applied");
        assertLe(block.timestamp, CrosschainMessages.commandDeadline(c1), "inside the window");
    }

    /// @dev Forge an authenticated dispatcher -> executor `COMMAND_ACK` with the given resolution, as the router
    ///      would deliver it. Used for states the real flows cannot reach (a receipt for a PENDING command).
    function _deliverForgedAck(bytes32 id_, uint64 sequence_, CommandResolution resolution_, uint256 nonce_) internal {
        bytes memory payload = abi.encode(id_, sequence_, int256(0), uint256(0), uint64(0), uint64(0), uint8(resolution_));
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("forged-ack", nonce_)),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(CcipMsgType.COMMAND_ACK, payload),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    /// @notice Ackee TP-M-16 step by step: C1 NACKs in its window, the manager's CANCEL is sent IN the window and
    ///         retained, the admin abandons with consumed = false after deadline + margin, the replacement R is built
    ///         at the same sequence, then the retained CANCEL is executed before R. The cancel closes C1 without
    ///         consuming the sequence and answers EXPIRED; the executor ignores that receipt because R owns the slot
    ///         (reason ALREADY_RESOLVED), and R runs.
    function testShouldRunTheReplacementWhenTheStaleCancelOfTheAckeeTimelineLandsFirst() public {
        MockRemoteVault vault = _prepared();
        (bytes32 c1, uint64 s) = _c1NackedInWindow();
        uint256 cancelHeld = _holdCancel(c1); // sent at T0, inside the window, retained
        uint256 armedAt = block.timestamp;
        uint256 rescueId = _armAbandon(false);
        _executeAbandonAtEarliest(rescueId, false, c1, armedAt);
        (bytes32 r, uint256 rHeld) = _holdDeposit(vault, 40e18);
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), s, "R stamped with the same sequence");

        vm.recordLogs();
        router.deliverHeld(cancelHeld); // the EXPIRED receipt is auto-delivered to the executor
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countLogs(logs, address(dispatcher), CcipCrosschainDispatcher.CancelCommandExpiredIgnored.selector),
            1,
            "CancelCommandExpiredIgnored"
        );
        assertEq(
            _countLogs(logs, address(executor), CcipCrosschainExecutor.CommandReceiptIgnored.selector),
            1,
            "EXPIRED receipt ignored by the executor"
        );
        assertEq(
            _countLogs(logs, address(executor), CcipExecutorCommandLib.CommandExpiryReleased.selector),
            0,
            "no release"
        );
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED), "C1 closed");
        assertEq(dispatcher.nextCommandSequence(), s, "sequence NOT consumed");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), s, "mirror untouched");
        assertEq(executor.activeCommand(REMOTE_CHAIN), r, "R still owns the slot");
        assertEq(uint8(executor.commandStatus(r)), uint8(CommandStatus.PENDING), "and is still PENDING");

        uint256 idleBefore = dispatcher.trackedIdle();
        router.deliverHeld(rHeld);
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R executed");
        assertEq(dispatcher.trackedIdle(), idleBefore - 40e18, "R's deposit ran");
        assertEq(vault.balanceOf(address(dispatcher)), 40e18, "shares received");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "R resolved by its own receipt");
        assertEq(uint8(executor.commandStatus(r)), uint8(CommandStatus.SUCCEEDED));
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    /// @notice Other order: R lands first, the stale cancel afterwards. Before the IL-8594 fence this reverted
    ///         `InvalidSequence` and stayed executable forever; now it closes C1 and its EXPIRED receipt reaches an
    ///         executor whose slot is free, where it is ignored.
    function testShouldCloseAStaleCancelThatLandsAfterTheReplacementRan() public {
        MockRemoteVault vault = _prepared();
        (bytes32 c1, uint64 s) = _c1NackedInWindow();
        uint256 cancelHeld = _holdCancel(c1);
        uint256 armedAt = block.timestamp;
        uint256 rescueId = _armAbandon(false);
        _executeAbandonAtEarliest(rescueId, false, c1, armedAt);
        (bytes32 r, uint256 rHeld) = _holdDeposit(vault, 40e18);
        router.deliverHeld(rHeld);
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R executed");
        assertEq(dispatcher.nextCommandSequence(), s + 1);

        uint64 tailBefore = dispatcher.responseQueueTail();
        vm.recordLogs();
        router.deliverHeld(cancelHeld);
        assertEq(
            _countLogs(
                vm.getRecordedLogs(), address(dispatcher), CcipCrosschainDispatcher.CancelCommandExpiredIgnored.selector
            ),
            1,
            "closed and reported"
        );
        assertEq(dispatcher.responseQueueTail(), tailBefore, "the lane already passed the sequence: no receipt queued");
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED), "closed, not reverted");
        assertEq(dispatcher.nextCommandSequence(), s + 1, "untouched");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), s + 1, "lane in lockstep");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot still free");
    }

    /// @notice Boundary on the dispatcher: a cancel AT the deadline is a normal cancel (consumes the sequence,
    ///         CANCELLED receipt), one second later it is EXPIRED (nothing consumed, slot released).
    function testShouldTreatACancelAtTheDeadlineAsNormalAndOneSecondLaterAsExpired() public {
        _prepared();
        // Command 1: cancel exactly AT the deadline.
        (bytes32 c1, uint64 s) = _c1NackedInWindow();
        uint256 held1 = _holdCancel(c1);
        vm.warp(CrosschainMessages.commandDeadline(c1));
        router.deliverHeld(held1);
        assertEq(dispatcher.nextCommandSequence(), s + 1, "at the deadline: sequence consumed");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "CANCELLED receipt freed the slot");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), s + 1, "mirror advanced");

        // Command 2: cancel ONE SECOND past the deadline.
        (bytes32 c2, uint64 s2) = _c1NackedInWindow();
        uint256 held2 = _holdCancel(c2);
        vm.warp(CrosschainMessages.commandDeadline(c2) + 1);
        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipExecutorCommandLib.CommandExpiryReleased(REMOTE_CHAIN, c2, s2);
        router.deliverHeld(held2);
        assertEq(dispatcher.nextCommandSequence(), s2, "past the deadline: sequence NOT consumed");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "EXPIRED receipt freed the slot");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), s2, "mirror unchanged");
    }

    // ----- clock-lag boundary of the admin path (IL-8591 residual) -----

    /// @dev Abandon at the earliest allowed second (executor clock), R built in the same second, then the stale cancel
    ///      runs on a dispatcher whose clock is `lag_` behind. The cancel is fenced iff the dispatcher's time is
    ///      still past the deadline: `lag_ < gap`, where `gap = executorNow - deadline` (at least the margin + 1).
    function _lagScenario(uint256 lag_)
        internal
        returns (bytes32 c1, bytes32 r, uint256 rHeld, uint64 s, uint256 gap)
    {
        MockRemoteVault vault = _prepared();
        (c1, s) = _c1NackedInWindow();
        uint256 cancelHeld = _holdCancel(c1);
        uint256 armedAt = block.timestamp;
        uint256 rescueId = _armAbandon(false);
        uint256 executorNow = _executeAbandonAtEarliest(rescueId, false, c1, armedAt);
        gap = executorNow - CrosschainMessages.commandDeadline(c1);
        (r, rHeld) = _holdDeposit(vault, 40e18);
        vm.warp(executorNow - lag_); // dispatcher clock
        router.deliverHeld(cancelHeld);
        vm.warp(executorNow);
    }

    function testShouldStayFencedWhenTheDispatcherClockIsInSyncWithTheExecutor() public {
        (bytes32 c1, bytes32 r, uint256 rHeld, uint64 s, uint256 gap) = _lagScenario(0);
        assertGe(gap, CrosschainConstants.COMMAND_EXPIRY_MARGIN + 1, "abandon waited at least the margin");
        assertEq(dispatcher.nextCommandSequence(), s, "fenced");
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED));
        router.deliverHeld(rHeld);
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R executed");
    }

    function testShouldStayFencedWhenTheDispatcherClockLagsExactlyOneSecondShortOfTheGap() public {
        uint256 gap = _gapOfTheAckeeScenario();
        (bytes32 c1, bytes32 r, uint256 rHeld, uint64 s,) = _lagScenario(gap - 1);
        assertEq(dispatcher.nextCommandSequence(), s, "fenced at lag == gap - 1");
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED));
        router.deliverHeld(rHeld);
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R executed");
    }

    /// @notice KNOWN LIMITATION (accepted IL-8591 residual, runbook rule in contracts/crosschain/ccip/README.md): if the
    ///         dispatcher chain's clock is at or before the command deadline at the moment the stale cancel runs,
    ///         the fence does not hold and the original defect reappears: the cancel consumes R's sequence, its
    ///         CANCELLED receipt retires the still-PENDING R and R's deposit never runs. Operators avoid it by
    ///         executing ABANDON(consumed = false) only after the dispatcher chain's safe block is past the deadline.
    function testKnownLimitationDispatcherClockAtOrBeforeTheDeadlineReopensTheDefectOnTheAdminAbandonPath() public {
        uint256 gap = _gapOfTheAckeeScenario();
        vm.recordLogs();
        (bytes32 c1, bytes32 r, uint256 rHeld, uint64 s,) = _lagScenario(gap);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(dispatcher.nextCommandSequence(), s + 1, "stale cancel consumed R's sequence");
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED));
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "R retired by the late CANCELLED receipt");
        assertEq(uint8(executor.commandStatus(r)), uint8(CommandStatus.CANCELLED));
        assertEq(
            _countLogs(logs, address(executor), CcipExecutorCommandLib.LateReceiptRetiredPendingReplacement.selector),
            1,
            "alert fired"
        );
        uint256 idleBefore = dispatcher.trackedIdle();
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.InvalidSequence.selector, s + 1, s));
        router.deliverHeld(rHeld);
        assertEq(dispatcher.trackedIdle(), idleBefore, "R's deposit never ran");
    }

    /// @dev The distance between the command deadline and the earliest abandon second in the Ackee scenario. It is
    ///      deterministic (it depends on `RESCUE_DELAY` and the TTL only), so it is measured on a snapshot.
    function _gapOfTheAckeeScenario() internal returns (uint256 gap) {
        uint256 snapshot = vm.snapshotState();
        (,,,, gap) = _lagScenario(0);
        vm.revertToState(snapshot);
    }

    // ----- the in-window cancel whose receipt is retained (what remains of the IL-7970 adoption) -----

    /// @notice What remains of "a late receipt retires a PENDING replacement" after the fix: the cancel runs INSIDE
    ///         the window (consumes s), its ACK is retained, and an abandon armed earlier with consumed = false (true
    ///         when armed) executes. R at s is dead on arrival (dispatcher already at s + 1) and the late ACK retires
    ///         it. No executable action is lost; the event is the signal.
    function testShouldStillRetireADeadReplacementWhenAnInWindowCancelReceiptIsRetained() public {
        MockRemoteVault vault = _prepared();
        (bytes32 c1, uint64 s) = _c1NackedInWindow();
        uint256 armedAt = block.timestamp;
        uint256 rescueId = _armAbandon(false);

        router.setFailSend(address(dispatcher), true); // the dispatcher's ACK stays in its response queue
        executor.cancelCommand(REMOTE_CHAIN, c1, 0, address(0), 2_000_000); // delivered at once, inside the window
        assertEq(dispatcher.nextCommandSequence(), s + 1, "cancel consumed s in the window");
        assertEq(executor.activeCommand(REMOTE_CHAIN), c1, "ACK not delivered");

        _executeAbandonAtEarliest(rescueId, false, c1, armedAt); // the armed declaration is now false
        (bytes32 r, uint256 rHeld) = _holdDeposit(vault, 40e18);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.InvalidSequence.selector, s + 1, s));
        router.deliverHeld(rHeld);

        router.setFailSend(address(dispatcher), false);
        vm.recordLogs();
        dispatcher.flushResponse();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(
            _countLogs(logs, address(executor), CcipExecutorCommandLib.LateReceiptRetiredPendingReplacement.selector),
            1,
            "alert fired"
        );
        assertEq(uint8(executor.commandStatus(r)), uint8(CommandStatus.CANCELLED), "dead R retired");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), s + 1, "mirror repaired by the receipt");
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.NONE), "R never ran");
    }

    // ----- the EXPIRED receipt is durable: a re-sent cancel is idempotent, the queued receipt still frees the slot -----

    /// @notice Replaces "a re-sent cancel after the no-op changes nothing, only ABANDON frees": the expired cancel
    ///         closes the command and QUEUES an `EXPIRED` receipt. If that receipt is not delivered at once, a cancel
    ///         re-sent past the IL-8579 cooldown is idempotent on the dispatcher (no second receipt), and the
    ///         queued receipt still frees the slot as soon as it flushes. No admin is involved.
    function testShouldFreeTheSlotFromTheQueuedExpiredReceiptEvenAfterAResentCancel() public {
        _prepared();
        (bytes32 c1, uint64 s) = _c1NackedInWindow();
        uint256 cancelHeld = _holdCancel(c1);
        vm.warp(CrosschainMessages.commandDeadline(c1) + 1);

        router.setFailSend(address(dispatcher), true); // the receipt stays in the dispatcher's response queue
        router.deliverHeld(cancelHeld);
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED), "expired cancel closed C1");
        assertEq(dispatcher.nextCommandSequence(), s, "sequence not consumed");
        assertEq(executor.activeCommand(REMOTE_CHAIN), c1, "slot still held: the receipt is queued");
        uint64 tail = dispatcher.responseQueueTail();
        assertGt(tail, 0, "EXPIRED receipt queued");

        vm.warp(block.timestamp + CrosschainConstants.CANCEL_COMMAND_COOLDOWN);
        executor.cancelCommand(REMOTE_CHAIN, c1, 0, address(0), 2_000_000); // re-sent, delivered at once
        assertEq(dispatcher.responseQueueTail(), tail, "a re-sent cancel queues no second receipt");
        assertEq(executor.activeCommand(REMOTE_CHAIN), c1, "slot still held");
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.CancelInFlight.selector, REMOTE_CHAIN, c1));
        executor.retryCommand(REMOTE_CHAIN, c1, 0, address(0), 2_000_000);

        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse();
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "queued EXPIRED receipt freed the slot");
        assertEq(uint8(executor.commandStatus(c1)), uint8(CommandStatus.CANCELLED));
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ----- the other stale messages of the abandoned command -----

    /// @notice A retained RETRY of the abandoned command, executed before R: NACK `CommandExpired` (IL-8255), no
    ///         sequence consumed, the NACK is ignored by the executor and R runs.
    function testShouldNackAndIgnoreAStaleRetryOfAnAbandonedCommand() public {
        MockRemoteVault vault = _prepared();
        (bytes32 c1, uint64 s) = _c1NackedInWindow();
        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, c1, 0, address(0), 2_000_000);
        router.setAutoDeliver(true);
        uint256 retryHeld = router.heldCount() - 1;
        uint256 armedAt = block.timestamp;
        uint256 rescueId = _armAbandon(false);
        _executeAbandonAtEarliest(rescueId, false, c1, armedAt);
        (bytes32 r, uint256 rHeld) = _holdDeposit(vault, 40e18);

        router.deliverHeld(retryHeld);
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.FAILED), "expired retry NACKed");
        assertEq(dispatcher.nextCommandSequence(), s, "sequence not consumed");
        assertEq(executor.activeCommand(REMOTE_CHAIN), r, "NACK ignored, R keeps the slot");
        router.deliverHeld(rHeld);
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R executed");
    }

    /// @notice C1's own first delivery retained and executed only after the abandon and R: NACK `CommandExpired`,
    ///         ignored by the executor, R runs.
    function testShouldNackAndIgnoreTheStaleFirstDeliveryOfAnAbandonedCommand() public {
        MockRemoteVault vault = _prepared();
        (bytes32 c1, uint256 c1Held) = _holdDeposit(vault, 10e18);
        uint64 s = dispatcher.nextCommandSequence();
        uint256 armedAt = block.timestamp;
        uint256 rescueId = _armAbandon(false);
        _executeAbandonAtEarliest(rescueId, false, c1, armedAt);
        (bytes32 r, uint256 rHeld) = _holdDeposit(vault, 40e18);

        router.deliverHeld(c1Held);
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.FAILED), "expired first delivery NACKed");
        assertEq(dispatcher.nextCommandSequence(), s, "sequence not consumed");
        assertEq(executor.activeCommand(REMOTE_CHAIN), r, "NACK ignored");
        router.deliverHeld(rHeld);
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R executed");
        assertEq(vault.balanceOf(address(dispatcher)), 40e18, "only R's deposit ran");
    }

    // ----- executor-side guards of the EXPIRED receipt -----

    /// @notice An EXPIRED receipt frees the slot only for the FAILED command that owns it. Forged here for a
    ///         command that is PENDING (a state a real dispatcher cannot produce): ignored, nothing moves.
    function testShouldIgnoreAnExpiredReceiptWhenTheCommandIsNotFailed() public {
        MockRemoteVault vault = _prepared();
        (bytes32 c, uint256 cHeld) = _holdDeposit(vault, 10e18); // PENDING on the executor, undelivered
        uint64 s = executor.nextCommandSequence(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(c)), uint8(CommandStatus.PENDING));

        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipCrosschainExecutor.CommandReceiptIgnored(
            REMOTE_CHAIN, c, uint8(CcipMsgType.COMMAND_ACK), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED)
        );
        _deliverForgedAck(c, s, CommandResolution.EXPIRED, 1);
        assertEq(executor.activeCommand(REMOTE_CHAIN), c, "slot kept");
        assertEq(uint8(executor.commandStatus(c)), uint8(CommandStatus.PENDING), "status kept");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), s, "mirror kept");

        router.deliverHeld(cHeld); // the command itself still runs normally
        assertEq(uint8(executor.commandStatus(c)), uint8(CommandStatus.SUCCEEDED));
    }

    /// @notice The slot holds a replacement R (PENDING, same sequence): an EXPIRED receipt naming the abandoned C1 is
    ///         ignored, R keeps the slot. Forged so that it does not depend on the order of deliveries.
    function testShouldIgnoreAnExpiredReceiptWhenTheSlotHoldsAReplacement() public {
        MockRemoteVault vault = _prepared();
        (bytes32 c1, uint64 s) = _c1NackedInWindow();
        uint256 armedAt = block.timestamp;
        uint256 rescueId = _armAbandon(false);
        _executeAbandonAtEarliest(rescueId, false, c1, armedAt);
        (bytes32 r,) = _holdDeposit(vault, 40e18);

        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipCrosschainExecutor.CommandReceiptIgnored(
            REMOTE_CHAIN, c1, uint8(CcipMsgType.COMMAND_ACK), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED)
        );
        _deliverForgedAck(c1, s, CommandResolution.EXPIRED, 2);
        assertEq(executor.activeCommand(REMOTE_CHAIN), r, "R keeps the slot");
        assertEq(uint8(executor.commandStatus(r)), uint8(CommandStatus.PENDING), "R untouched");
        assertEq(uint8(executor.commandStatus(c1)), uint8(CommandStatus.CANCELLED), "C1 stays abandoned");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), s, "mirror kept");
    }

    // ----- empty-revert business failures (IL-8625 gas budget x IL-8594 x IL-8591) -----

    /// @dev REQUEST_SHARES aimed at a tracked plain ERC-4626 (no `UniversalReader.read`): the revert data is EMPTY. At
    ///      the command's budget that is a business failure like any other (IL-8625): FAILED + NACK.
    function _holdRequestSharesOnPlainVault(MockRemoteVault vault_) internal returns (bytes32 id, uint256 held) {
        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REQUEST_SHARES),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRequestSharesAction(
                    address(0xBEEF), address(vault_), 10e18, type(uint256).max
                )
            }),
            0,
            address(0),
            2_000_000
        );
        router.setAutoDeliver(true);
        id = executor.activeCommand(REMOTE_CHAIN);
        held = router.heldCount() - 1;
    }

    function _deliverWithGas(uint256 held_, uint256 gas_) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(router).call{gas: gas_}(abi.encodeCall(MockCcipRouter.deliverHeld, (held_)));
    }

    /// @notice An empty-revert business failure is NACKed at once (no 24 h freeze any more) and the manager frees the
    ///         lane in the same block; the cancel inside the window consumes the sequence.
    function testShouldNackAnEmptyRevertCommandAtOnceAndLetTheManagerCancelInTheSameBlock() public {
        MockRemoteVault vault = _prepared();
        uint256 t0 = block.timestamp;
        (bytes32 id, uint256 held) = _holdRequestSharesOnPlainVault(vault);
        uint64 seq = dispatcher.nextCommandSequence();

        (bool ok,) = _deliverWithGas(held, 2_000_000);
        assertTrue(ok, "an empty-revert business failure is a clean execution at the budget");
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "NACK applied on the executor");

        executor.cancelCommand(REMOTE_CHAIN, id, 0, address(0), 2_000_000);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot freed by the manager, no admin");
        assertEq(dispatcher.nextCommandSequence(), seq + 1, "inside the window the cancel consumes the sequence");
        assertEq(block.timestamp, t0, "no waiting");

        (bytes32 next, uint256 nextHeld) = _holdDeposit(vault, 10e18);
        router.deliverHeld(nextHeld);
        assertEq(uint8(dispatcher.commandStatus(next)), uint8(CommandStatus.SUCCEEDED), "the lane is alive");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    /// @notice Recalls of idle keep working while a command sits FAILED on the lane.
    function testShouldKeepRecallsOfIdleWorkingWhileTheCommandLaneHoldsAFailedCommand() public {
        MockRemoteVault vault = _prepared();
        (bytes32 id, uint256 held) = _holdRequestSharesOnPlainVault(vault);
        (bool ok,) = _deliverWithGas(held, 5_000_000);
        assertTrue(ok);
        assertEq(executor.activeCommand(REMOTE_CHAIN), id, "lane holds the FAILED command");

        uint256 idleBefore = executor.idleLedger();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 0, 0, address(0), 2_000_000);
        assertEq(executor.idleLedger(), idleBefore + 10e18, "recall of remote idle unaffected");
    }

    /// @notice Contrast: the same action with a DECODABLE error is NACKed at once and the manager frees the lane at
    ///         once, with the normal CANCELLED receipt (sequence consumed).
    function testShouldFreeADecodableBusinessFailureInTheSameBlock() public {
        _prepared();
        uint256 t0 = block.timestamp;
        uint64 seq = dispatcher.nextCommandSequence();
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REQUEST_SHARES),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRequestSharesAction(
                    address(0xBEEF), address(0xDEAD), 10e18, type(uint256).max
                )
            }),
            0,
            address(0),
            2_000_000
        );
        bytes32 id = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "NACKed at once");
        executor.cancelCommand(REMOTE_CHAIN, id, 0, address(0), 2_000_000);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "freed by the manager");
        assertEq(dispatcher.nextCommandSequence(), seq + 1, "inside the window the cancel consumes the sequence");
        assertEq(block.timestamp, t0, "no waiting");
    }

    /// @notice An UPDATE_VAULTS that FAILED on the dispatcher is released through the EXPIRED receipt: neither the
    ///         dispatcher's nor the executor's config epoch moves (the update was never applied), and the next
    ///         UPDATE_VAULTS at the same sequence succeeds and advances both.
    function testShouldReleaseAFailedUpdateVaultsThroughExpiredWithBothEpochsUnchanged() public {
        MockRemoteVault vault = _prepared();
        MockRemoteVault wrongAsset = new MockRemoteVault(IERC20(address(vault)), "Wrong", "wUSDC");
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore, "epochs in lockstep");
        uint64 s = dispatcher.nextCommandSequence();

        bytes32 id = _allowVaults(_oneVault(address(wrongAsset)));
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.FAILED), "UPDATE_VAULTS NACKed");
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "NACK applied");

        vm.warp(CrosschainMessages.commandDeadline(id) + 1);
        executor.cancelCommand(REMOTE_CHAIN, id, 0, address(0), 2_000_000);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot released by EXPIRED");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "dispatcher epoch unchanged");
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore, "executor epoch unchanged");
        assertEq(dispatcher.nextCommandSequence(), s, "sequence unconsumed");
        _assertMirrorsMatchDispatcher("lane in lockstep");

        MockRemoteVault another = new MockRemoteVault(token, "Another", "aUSDC");
        _allowVaults(_oneVault(address(another)));
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "next UPDATE_VAULTS resolved");
        assertEq(dispatcher.nextCommandSequence(), s + 1, "at the reused sequence");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "dispatcher epoch advanced");
        _assertMirrorsMatchDispatcher("and the executor followed");
    }
}
