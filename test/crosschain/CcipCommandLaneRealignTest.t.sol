// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {BusinessAction, CcipChainRescue, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

contract RealignToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipCommandLaneRealignTest
/// @notice IL-7970, CCIP half, end to end against a REAL dispatcher: adoption of a late `COMMAND_ACK`,
///         consumption of its state version even when it resolves nothing, and the timelocked
///         `REALIGN_COMMAND_LANE` chain rescue.
/// @dev The finding was that `commandConfigEpoch` / `nextCommandSequence` can desync between the dispatcher (the owner
///      of both counters) and the executor's mirrors, with no repair path. On `HEAD` the epoch half
///      self-heals through a NACK-and-cancel round (pinned here by
///      `testShouldHealAnEpochOnlyDesyncThroughTheCancelRound`), but the sequence half did not: an
///      executor BEHIND the dispatcher needed one sacrificial command plus one timelocked
///      `ABANDON_COMMAND(consumed = true)` per unit of lag, and an executor AHEAD of it had no exit at
///      all, because every writer of the mirror added one.
///
///      Window note. `MockCcipRouter` delivers synchronously, so a receipt cannot simply be "held in
///      flight" here. It does not need to be: the DISPATCHER queues every response in its own FIFO and
///      only tries to send the head (`_queueResponse` -> `try dispatchResponseSelf`), so
///      `setFailSend(dispatcher, true)` reproduces exactly the production shape this ticket is about — an
///      ACK sitting undeliverable in the queue while the operator, seeing no receipt, abandons the
///      command. `flushResponse` (permissionless) then delivers it late. The pure branch table of
///      `_adoptLateReceipt` / `realign` is covered at library level in `CcipExecutorCommandLibTest`.
contract CcipCommandLaneRealignTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    address internal constant ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    RealignToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    /// @dev Mirrors the executor's private command nonce. `activeCommand` cannot be read back after a
    ///      send whose receipt was delivered inside the same call (the mock router is synchronous), so
    ///      command ids are recomputed the way `CcipExecutorCommandLib.build` derives them.
    uint256 internal commandNonce;

    function setUp() public {
        router = new MockCcipRouter();
        token = new RealignToken();
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

    /// @dev Make every dispatcher -> executor response undeliverable. The dispatcher catches the send
    ///      failure and leaves the response at the head of its FIFO queue, which is how a fee ceiling or
    ///      a receiver failure looks in production.
    function _holdResponses() internal {
        router.setFailSend(address(dispatcher), true);
    }

    /// @dev Repair delivery and drain the queue through the permissionless `flushResponse`.
    function _releaseResponses() internal {
        router.setFailSend(address(dispatcher), false);
        while (dispatcher.responseQueueHead() != 0) {
            dispatcher.flushResponse();
        }
    }

    function _abandonArg(bool consumed_) internal pure returns (uint256) {
        return consumed_ ? 1 : 0;
    }

    function _abandon(bool consumed_) internal {
        vm.prank(ADMIN);
        uint256 rescueId =
            executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, _abandonArg(consumed_));
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, _abandonArg(consumed_));
    }

    /// @dev Bind the rescue to explicit expected mirrors (IL-8586): the pair it is armed against.
    function _realignArgFrom(uint64 expectedEpoch_, uint64 expectedSequence_, uint64 epoch_, uint64 sequence_)
        internal
        pure
        returns (uint256)
    {
        return (uint256(expectedEpoch_) << 192) | (uint256(expectedSequence_) << 128) | (uint256(epoch_) << 64)
            | uint256(sequence_);
    }

    /// @dev Armed against the executor's CURRENT mirrors.
    function _realignArg(uint64 epoch_, uint64 sequence_) internal view returns (uint256) {
        return _realignArgFrom(
            executor.commandConfigEpoch(REMOTE_CHAIN), executor.nextCommandSequence(REMOTE_CHAIN), epoch_, sequence_
        );
    }

    function _realign(uint64 epoch_, uint64 sequence_) internal {
        uint256 arg = _realignArg(epoch_, sequence_);
        vm.prank(ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
    }

    /// @dev Free the slot and realign it in ONE delay window. The free-slot requirement is checked at
    ///      EXECUTE time only, which is precisely what lets these two be scheduled in the same block.
    function _abandonThenRealign(bool consumed_, uint64 epoch_, uint64 sequence_) internal {
        uint256 abandonArg = _abandonArg(consumed_);
        // Expected pair = the state AFTER the abandon runs: a consumed declaration advances the sequence by one.
        uint256 realignArg = _realignArgFrom(
            executor.commandConfigEpoch(REMOTE_CHAIN),
            executor.nextCommandSequence(REMOTE_CHAIN) + (consumed_ ? 1 : 0),
            epoch_,
            sequence_
        );
        vm.startPrank(ADMIN);
        uint256 abandonId = executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, abandonArg);
        uint256 realignId =
            executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, realignArg);
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(ADMIN);
        executor.executeChainRescue(abandonId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, abandonArg);
        executor.executeChainRescue(realignId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, realignArg);
        vm.stopPrank();
    }

    /// @dev Drop the head of the dispatcher's response queue for good (the finding's trigger #1).
    function _skipHead() internal {
        uint64 head = dispatcher.responseQueueHead();
        vm.prank(ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(head);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, head);
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
        // `sendAssetToDispatcher` derives its operation id from the SAME private nonce counter that
        // command ids use, so the mirror has to follow it.
        ++commandNonce;
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
        _attestBalance(dispatcher.accountedBalance());
    }

    /// @dev The id `CcipExecutorCommandLib.build` will stamp on the next command this executor builds in
    ///      this block (the high 64 bits carry the command's deadline, IL-8255).
    function _nextCommandId() internal returns (bytes32) {
        return CrosschainMessages.stampCommandId(
            keccak256(abi.encode(address(executor), REMOTE_CHAIN, "CCIP_COMMAND", ++commandNonce))
        );
    }

    function _deployAndAllowVault() internal returns (MockRemoteVault vault) {
        vault = new MockRemoteVault(token, "Remote", "rUSDC");
        _allowVault(address(vault));
    }

    function _allowVault(address vault_) internal returns (bytes32 commandId) {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        commandId = _nextCommandId();
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
    }

    function _sendDeposit(MockRemoteVault vault_, uint256 amount_) internal returns (bytes32 commandId) {
        commandId = _nextCommandId();
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

    function _sendRedeemAll(MockRemoteVault vault_) internal returns (bytes32 commandId) {
        commandId = _nextCommandId();
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRedeemAction(
                    address(vault_), vault_.balanceOf(address(dispatcher)), 0
                )
            }),
            0,
            address(0),
            2_000_000
        );
    }

    function _assertMirrorsMatchDispatcher(string memory label_) internal view {
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), dispatcher.nextCommandSequence(), label_);
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), label_);
    }

    // ---------------------------------------------------------------------
    // C1-C3 — the late receipt
    // ---------------------------------------------------------------------

    /// @notice The honest race the ticket is about: the dispatcher ran the command and queued its ACK,
    ///         the ACK could not be delivered, and the operator — who cannot see the queue's contents
    ///         from this chain — abandoned the command as UNUSED. The ACK is authenticated proof that the
    ///         dispatcher consumed that sequence, so when it finally lands the mirrors must follow it
    ///         instead of leaving the lane one behind forever.
    function testShouldAdoptALateReceiptAfterAnUnusedAbandon() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        _holdResponses();
        bytes32 commandId = _sendDeposit(vault, 50e18);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "dispatcher ran it");
        assertTrue(dispatcher.responseQueueHead() != 0, "its ACK is stuck in the response queue");
        assertEq(executor.activeCommand(REMOTE_CHAIN), commandId, "executor still waiting on the receipt");

        _abandon(false); // the wrong declaration, made against no observation
        assertEq(
            executor.nextCommandSequence(REMOTE_CHAIN) + 1,
            dispatcher.nextCommandSequence(),
            "executor is now one BEHIND the dispatcher"
        );

        _releaseResponses();

        assertEq(
            executor.nextCommandSequence(REMOTE_CHAIN),
            dispatcher.nextCommandSequence(),
            "the late receipt realigned the sequence mirror"
        );
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), "and the epoch mirror");
        assertEq(
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            dispatcher.stateVersion(),
            "the receipt carries no version bump (IL-8257): the frontier still equals the dispatcher version"
        );
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot free");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "resolution recorded");

        // The point of the repair: capital inside the remote position is mobile again, with no rescue.
        assertGt(vault.balanceOf(address(dispatcher)), 0, "position exists");
        bytes32 redeemId = _sendRedeemAll(vault);
        assertEq(uint8(dispatcher.commandStatus(redeemId)), uint8(CommandStatus.SUCCEEDED), "REDEEM accepted");
        assertEq(vault.balanceOf(address(dispatcher)), 0, "position drained through the protocol");
    }

    /// @notice A replacement command issued after the abandon is doomed the moment the late receipt shows
    ///         the dispatcher already consumed its sequence: strict-equality sequencing on a monotonic
    ///         counter means its COMMAND, RETRY and CANCEL all revert forever. The adoption retires it
    ///         rather than leaving the operator a second timelocked abandon to run.
    function testShouldSupersedeADoomedReplacementWhenTheLateReceiptLands() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        _holdResponses();
        bytes32 c1 = _sendDeposit(vault, 50e18);
        _abandon(false);

        // A replacement occupies the freed slot at the same sequence. Its COMMAND message is dropped on
        // the floor, which models one still in flight when the ACK for `c1` arrives.
        router.setAutoDeliver(false);
        bytes32 c2 = _sendDeposit(vault, 10e18);
        router.setAutoDeliver(true);
        assertEq(executor.activeCommand(REMOTE_CHAIN), c2, "replacement owns the slot");

        router.setFailSend(address(dispatcher), false);
        vm.expectEmit(true, false, false, true, address(executor));
        emit CcipExecutorCommandLib.CommandReceiptAdopted(
            REMOTE_CHAIN, c1, executor.nextCommandSequence(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), c2
        );
        dispatcher.flushResponse();

        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "the doomed replacement was retired");
        assertEq(uint8(executor.commandStatus(c2)), uint8(CommandStatus.CANCELLED), "and marked terminal");
        _assertMirrorsMatchDispatcher("mirrors realigned by the receipt");

        bytes32 fresh = _sendDeposit(vault, 10e18);
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "lane works again");
    }

    /// @notice A receipt that resolves nothing on this side must leave the frontier exactly where it was.
    ///         It used to be the only carrier of a state version, so ignoring it before consuming that version
    ///         left a permanent frontier gap (IL-7970). Since IL-8257 a command receipt carries the current
    ///         version as evidence only and never bumps or moves it, so an ignored (stale) receipt can neither
    ///         gap the chain nor advance it, and the next VALUE-MOVING response is still contiguous.
    function testShouldKeepTheFrontierAlignedAfterAStaleReceipt() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        _holdResponses();
        _sendDeposit(vault, 50e18);
        _abandon(true); // the CORRECT declaration: the receipt is stale for the counters
        _releaseResponses();

        assertEq(
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            dispatcher.stateVersion(),
            "the ignored receipt left the frontier on the dispatcher version"
        );
        _assertMirrorsMatchDispatcher("counters were already correct");

        // Proof that it matters: the next value-moving response is contiguous and must not gap.
        vm.warp(block.timestamp + 1 hours);
        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        _fundRemoteIdle(10e18);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier + 1, "the next settle is contiguous");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "no gap block");
        executor.getBalanceByChain(REMOTE_CHAIN);
    }

    // ---------------------------------------------------------------------
    // C4-C5 — the realign rescue on the two desynced directions
    // ---------------------------------------------------------------------

    /// @notice The terminal sub-state: a CONSUMED declaration for a command the dispatcher never received
    ///         puts the mirror AHEAD, and every other writer of it only adds one, so before this fix there
    ///         was no exit at all on a non-upgradeable pair.
    /// @dev The brick is asserted through a try/catch because `MockCcipRouter` delivers synchronously:
    ///      here the dispatcher's `InvalidSequence` revert propagates back into the executor's `send`, so
    ///      the executor's state is rolled back and the slot stays free. In production the send succeeds,
    ///      the message is left manually executable on CCIP, and the slot stays occupied — which is why
    ///      the realign requires a free slot and an `ABANDON_COMMAND` may be needed first.
    function testShouldRealignAnExecutorThatRanAhead() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        bytes32 deposited = _sendDeposit(vault, 50e18);
        assertEq(uint8(dispatcher.commandStatus(deposited)), uint8(CommandStatus.SUCCEEDED), "position opened");

        // A command that never reaches the dispatcher, declared CONSUMED anyway.
        router.setAutoDeliver(false);
        _sendDeposit(vault, 10e18);
        router.setAutoDeliver(true);
        _abandon(true);
        assertEq(
            executor.nextCommandSequence(REMOTE_CHAIN),
            dispatcher.nextCommandSequence() + 1,
            "executor is one AHEAD of the dispatcher"
        );

        uint256 settledBefore = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint64 versionBefore = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        // The lane is dead: every command the executor can stamp is rejected by the dispatcher.
        bool sent = true;
        try executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 1e18, 0)
            }),
            0,
            address(0),
            2_000_000
        ) {} catch {
            sent = false;
        }
        assertFalse(sent, "the dispatcher refuses every sequence this executor can stamp");

        _realign(dispatcher.commandConfigEpoch(), dispatcher.nextCommandSequence());

        _assertMirrorsMatchDispatcher("realigned downwards onto the dispatcher's counters");
        assertEq(
            executor.settledRemoteBalance(REMOTE_CHAIN),
            settledBefore,
            "settled untouched: the branch did not fall through to forceSetSettled"
        );
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore, "frontier untouched");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "no NAV block raised");

        bytes32 redeemId = _sendRedeemAll(vault);
        assertEq(uint8(dispatcher.commandStatus(redeemId)), uint8(CommandStatus.SUCCEEDED), "lane alive again");
        assertEq(vault.balanceOf(address(dispatcher)), 0, "position drained through the protocol");
    }

    /// @notice The finding's trigger #1: `executeSkipStuckResponse` drops a queued `COMMAND_ACK` for good.
    ///         Before this fix the executor-behind state it leaves cost one sacrificial command plus one
    ///         timelocked `ABANDON_COMMAND(consumed = true)` per unit of lag — `MIN_RESCUE_DELAY` is a
    ///         24 h floor, and this fixture is configured at 3 days. The abandon and the realign are
    ///         scheduled in the SAME block here and executed back to back, which is what the execute-time
    ///         (not schedule-time) free-slot check buys.
    function testShouldRealignAnExecutorThatFellBehindWithoutASacrificialCommand() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        _holdResponses();
        _sendDeposit(vault, 50e18);
        _skipHead(); // the ACK is gone for good; it carried no state version, so the frontier is intact
        _releaseResponses();

        _abandonThenRealign(false, dispatcher.commandConfigEpoch(), dispatcher.nextCommandSequence());

        _assertMirrorsMatchDispatcher("realigned upwards with no sacrificial command");
        bytes32 fresh = _sendDeposit(vault, 10e18);
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "lane alive again");

        // Skipping an ACK used to cost a frontier repair: the version it carried was gone, so the NEXT response
        // arrived ahead of the frontier and failed on the gap (IL-8496). Since IL-8257 a command ACK carries no
        // version bump, so nothing is lost: the fresh ACK applies at once, with no repair.
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the chain is not blocked");
        assertEq(dispatcher.responseQueueHead(), 0, "the fresh ACK left the queue");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "fresh command acknowledged");
        assertEq(
            executor.lastRemoteStateVersion(REMOTE_CHAIN), dispatcher.stateVersion(), "frontier never fell behind"
        );
    }

    // ---------------------------------------------------------------------
    // C6-C8 — the fences on the realign
    // ---------------------------------------------------------------------

    /// @notice A realign while a command is outstanding would leave that command stamped with a sequence
    ///         the mirror no longer stands behind. Scheduling is still allowed — that is what lets an
    ///         abandon and a realign be armed together — so the refusal lands at execute time.
    function testShouldRejectRealignWhileACommandIsActive() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        _holdResponses();
        bytes32 commandId = _sendDeposit(vault, 50e18);

        uint256 arg = _realignArg(9, 9);
        vm.prank(ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);

        uint64 sequenceBefore = executor.nextCommandSequence(REMOTE_CHAIN);
        uint64 epochBefore = executor.commandConfigEpoch(REMOTE_CHAIN);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorCommandLib.ActiveCommandExists.selector, REMOTE_CHAIN, commandId)
        );
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);

        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), sequenceBefore, "sequence mirror untouched");
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore, "epoch mirror untouched");
    }

    /// @notice The realign is the only writer that can lower a counter, so it carries the full rescue
    ///         envelope: admin-only, timelocked, cancellable and guardian-vetoable — and the mirrors must
    ///         be untouched after every refusal.
    function testShouldTimelockAndGuardianVetoRealign() public {
        uint256 arg = _realignArg(4, 7);
        uint64 sequenceBefore = executor.nextCommandSequence(REMOTE_CHAIN);
        uint64 epochBefore = executor.commandConfigEpoch(REMOTE_CHAIN);

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, address(this)));
        executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);

        vm.prank(ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTimelockNotElapsed.selector,
                rescueId,
                block.timestamp,
                block.timestamp + RESCUE_DELAY
            )
        );
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);

        vm.prank(GUARDIAN);
        executor.cancelRescue(rescueId);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueNotScheduled.selector, rescueId));
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);

        vm.prank(ADMIN);
        uint256 vetoedId = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
        vm.prank(GUARDIAN);
        executor.vetoAllPendingRescues();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueVetoed.selector, vetoedId));
        executor.executeChainRescue(vetoedId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);

        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), sequenceBefore, "sequence mirror untouched so far");
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore, "epoch mirror untouched so far");

        _realign(4, 7);
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), 7, "a clean round applies");
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), 4, "a clean round applies");
    }

    // ---------------------------------------------------------------------
    // C9 — the blast radius of the new writer
    // ---------------------------------------------------------------------

    /// @notice The realign is a lever on exactly two storage slots. Running it repeatedly, including to
    ///         nonsense values, must move nothing else: no settled balance, no idle ledger, no in-flight
    ///         bucket, no version frontier, no NAV block, no dispatcher state.
    /// @dev GUARD, not regression evidence: it asserts what the new writer must NOT do, so it passes both
    ///      with the realign body present and with it stubbed out. It is here to bound the blast radius of
    ///      a writer that can lower a counter, not to prove the fix works.
    function testShouldNotLetRepeatedRealignsTouchAnythingButTheMirrors() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        uint256 settled = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 idle = executor.idleLedger();
        uint256 inFlight = executor.outboundInFlight(REMOTE_CHAIN);
        uint64 version = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        bool blocked = executor.chainBlocked(REMOTE_CHAIN);
        bool repairPending = executor.frontierRepairPending(REMOTE_CHAIN);
        uint256 navByChain = executor.getBalanceByChain(REMOTE_CHAIN);
        uint64 dispatcherSequence = dispatcher.nextCommandSequence();
        uint64 dispatcherEpoch = dispatcher.commandConfigEpoch();
        uint256 dispatcherIdle = dispatcher.trackedIdle();
        uint256 dispatcherAccounted = dispatcher.accountedBalance();

        // Three realigns in ONE delay window, so nothing here is explained by elapsed time.
        uint256[3] memory args = [
            _realignArg(7, 99),
            _realignArgFrom(7, 99, 2, 3),
            _realignArgFrom(2, 3, dispatcherEpoch, dispatcherSequence)
        ];
        uint256[3] memory ids;
        vm.startPrank(ADMIN);
        for (uint256 i; i < 3; ++i) {
            ids[i] = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, args[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);
        for (uint256 i; i < 3; ++i) {
            vm.prank(ADMIN);
            executor.executeChainRescue(ids[i], CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, args[i]);
            assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settled, "settled untouched");
            assertEq(executor.idleLedger(), idle, "idle untouched");
            assertEq(executor.outboundInFlight(REMOTE_CHAIN), inFlight, "in-flight untouched");
            assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), version, "frontier untouched");
            assertEq(executor.chainBlocked(REMOTE_CHAIN), blocked, "block flag untouched");
            assertEq(executor.frontierRepairPending(REMOTE_CHAIN), repairPending, "repair latch untouched");
            assertEq(executor.getBalanceByChain(REMOTE_CHAIN), navByChain, "NAV component untouched");
            assertEq(dispatcher.nextCommandSequence(), dispatcherSequence, "dispatcher sequence untouched");
            assertEq(dispatcher.commandConfigEpoch(), dispatcherEpoch, "dispatcher epoch untouched");
            assertEq(dispatcher.trackedIdle(), dispatcherIdle, "dispatcher idle untouched");
            assertEq(dispatcher.accountedBalance(), dispatcherAccounted, "dispatcher accounting untouched");
        }

        bytes32 fresh = _sendDeposit(vault, 10e18);
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "lane works at the end");
    }

    // ---------------------------------------------------------------------
    // C10 — control
    // ---------------------------------------------------------------------

    /// @notice CONTROL, passes before and after this fix: it is not regression evidence, it pins the
    ///         assessment's claim that the EPOCH half of the desync already self-heals. `InvalidConfigEpoch`
    ///         is raised inside the dispatcher's self-call, so it NACKs rather than reverting, and the
    ///         cancel that resolves the NACKed command carries the dispatcher's epoch, which the mirror
    ///         adopts unconditionally. No rescue, no timelock — one wasted command and one cancel.
    function testShouldHealAnEpochOnlyDesyncThroughTheCancelRound() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        // A config update whose ACK is dropped for good: the dispatcher's epoch moved, the mirror's did
        // not, and the abandon (correctly CONSUMED) leaves only the epoch out of step.
        _holdResponses();
        MockRemoteVault second = new MockRemoteVault(token, "Second", "sUSDC");
        _allowVault(address(second));
        _skipHead();
        router.setFailSend(address(dispatcher), false);
        _abandon(true);

        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), dispatcher.nextCommandSequence(), "sequence aligned");
        assertTrue(executor.commandConfigEpoch(REMOTE_CHAIN) != dispatcher.commandConfigEpoch(), "epoch behind");

        bytes32 doomed = _sendDeposit(vault, 10e18);
        assertEq(uint8(executor.commandStatus(doomed)), uint8(CommandStatus.FAILED), "NACKed, not reverted");
        assertEq(uint8(dispatcher.commandStatus(doomed)), uint8(CommandStatus.FAILED), "and stored as FAILED");

        // The dropped ACK carried no state version (IL-8257), so the cancel ACK is contiguous with the frontier
        // and heals the epoch at once: no frontier repair is needed.
        vm.expectEmit(true, false, false, true, address(executor));
        emit CcipExecutorCommandLib.ConfigEpochResynced(
            REMOTE_CHAIN, executor.commandConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch()
        );
        executor.cancelCommand(REMOTE_CHAIN, doomed, 0, address(0), 2_000_000);
        assertEq(dispatcher.responseQueueHead(), 0, "the cancel ACK was delivered");

        assertEq(
            executor.commandConfigEpoch(REMOTE_CHAIN),
            dispatcher.commandConfigEpoch(),
            "epoch healed by the cancel ACK"
        );
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot free");
    }
}
