// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipSendLib} from "../../contracts/crosschain/ccip/lib/CcipSendLib.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages, SweepFloor} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {MockRemotePlasmaVault} from "./mocks/MockRemoteVault.sol";

/// @title CcipDisabledRouteInboundTest
/// @notice IL-9701 (3sigma v2 #16): a disabled CCIP route must stop NEW work on the dispatcher. Sending already
///         checked the route flag; receiving did not, so a disabled route still executed commands while the
///         replies queued. The dispatcher now refuses COMMAND, UPDATE_VAULTS and RETRY_COMMAND from a disabled
///         route with `CcipUnknownChain` (the send path's error), and the refusal also undoes the processed-message
///         mark, so after re-enabling the same message can be executed again. Messages that settle or unwind
///         existing state (OUTBOUND_TRANSFER, RETURN_REQUEST, CANCEL_COMMAND, BALANCE_REQUEST) and everything
///         the executor receives (replies) keep arriving on a disabled route.
contract CcipDisabledRouteInboundTest is CcipExecutorFixture {
    bytes32 internal constant MESSAGE_ID = keccak256("ccip-disabled-route-message");
    bytes32 internal constant OPERATION_ID = keccak256("ccip-disabled-route-operation");
    address internal trackedVault;

    function setUp() public {
        _fixtureSetUp();
        trackedVault = address(new MockRemotePlasmaVault(IERC20(address(token)), "Remote", "rUSDC"));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _flags(bool enabled_) private pure returns (uint256) {
        return uint256(2_000_000) | (uint256(2_000_000) << 96) | (enabled_ ? uint256(1) << 192 : 0);
    }

    function _setDispatcherRoute(bool enabled_) private {
        vm.prank(factory);
        dispatcher.syncRoutePolicy(address(0), _flags(enabled_), 0);
        assertEq(dispatcher.ccipRoute(block.chainid).enabled, enabled_, "route flag");
    }

    function _setExecutorRoute(bool enabled_) private {
        vm.prank(factory);
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _flags(enabled_), 0);
        assertEq(executor.ccipRoute(REMOTE_CHAIN).enabled, enabled_, "executor route flag");
    }

    function _message(
        bytes32 messageId_,
        bytes memory envelope_,
        uint64 selector_,
        address sender_,
        CcipClient.EVMTokenAmount[] memory tokens_
    ) private pure returns (CcipClient.Any2EVMMessage memory) {
        return
            CcipClient.Any2EVMMessage({
                messageId: messageId_,
                sourceChainSelector: selector_,
                sender: abi.encode(sender_),
                data: envelope_,
                destTokenAmounts: tokens_
            });
    }

    function _toDispatcher(bytes32 messageId_, bytes memory envelope_) private {
        CcipClient.Any2EVMMessage memory message = _message(
            messageId_,
            envelope_,
            EXECUTOR_SELECTOR,
            address(executor),
            new CcipClient.EVMTokenAmount[](0)
        );
        vm.prank(address(router));
        dispatcher.ccipReceive(message);
    }

    function _toDispatcherExpectingUnknownChain(bytes32 messageId_, bytes memory envelope_) private {
        CcipClient.Any2EVMMessage memory message = _message(
            messageId_,
            envelope_,
            EXECUTOR_SELECTOR,
            address(executor),
            new CcipClient.EVMTokenAmount[](0)
        );
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(CcipSendLib.CcipUnknownChain.selector, block.chainid));
        dispatcher.ccipReceive(message);
        assertFalse(dispatcher.processedCcipMessage(messageId_), "refusal must not consume the message id");
    }

    /// @dev A command the dispatcher runs to a NACK (REDEEM on an untracked vault): it is delivered and stored, so
    ///      its status leaves NONE, which is what tells "executed" from "refused".
    function _failingCommand() private view returns (Command memory) {
        return
            Command({
                commandId: bytes32((block.timestamp + 1 days) << 192),
                sequence: dispatcher.nextCommandSequence(),
                commandConfigEpoch: dispatcher.commandConfigEpoch(),
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRedeemAction(trackedVault, 1e18, 0)
            });
    }

    function _commandEnvelope(
        CcipMsgType type_,
        Command memory command_,
        bytes memory extra_
    ) private pure returns (bytes memory) {
        return CcipMessages.encode(type_, abi.encode(type_, command_, extra_));
    }

    function _updateVaultsEnvelope(Command memory command_) private view returns (bytes memory) {
        address[] memory vaults = new address[](1);
        vaults[0] = trackedVault;
        return
            _commandEnvelope(CcipMsgType.UPDATE_VAULTS, command_, abi.encode(vaults, true, false, new SweepFloor[](0)));
    }

    // ---------------------------------------------------------------------
    // Dispatcher: new work is refused on a disabled route
    // ---------------------------------------------------------------------

    function testCommandIsRefusedOnDisabledRouteAndRunsAfterReEnable() public {
        Command memory command = _failingCommand();
        bytes memory envelope = _commandEnvelope(CcipMsgType.COMMAND, command, "");
        uint64 sequenceBefore = dispatcher.nextCommandSequence();

        _setDispatcherRoute(false);
        _toDispatcherExpectingUnknownChain(MESSAGE_ID, envelope);
        assertEq(uint8(dispatcher.commandStatus(command.commandId)), uint8(CommandStatus.NONE), "command not stored");
        assertEq(dispatcher.nextCommandSequence(), sequenceBefore, "lane untouched");

        _setDispatcherRoute(true);
        _toDispatcher(MESSAGE_ID, envelope);
        assertTrue(dispatcher.processedCcipMessage(MESSAGE_ID), "same message executes after re-enable");
        assertEq(uint8(dispatcher.commandStatus(command.commandId)), uint8(CommandStatus.FAILED), "command ran");
    }

    function testUpdateVaultsIsRefusedOnDisabledRouteAndRunsAfterReEnable() public {
        Command memory command = Command({
            commandId: bytes32((block.timestamp + 1 days) << 192),
            sequence: dispatcher.nextCommandSequence(),
            commandConfigEpoch: dispatcher.commandConfigEpoch(),
            action: uint8(BusinessAction.DEPOSIT),
            minExecutionGas: 0,
            actionData: ""
        });
        bytes memory envelope = _updateVaultsEnvelope(command);

        _setDispatcherRoute(false);
        _toDispatcherExpectingUnknownChain(MESSAGE_ID, envelope);
        assertFalse(dispatcher.isTrackedVault(trackedVault), "allowlist untouched");
        assertEq(dispatcher.commandConfigEpoch(), command.commandConfigEpoch, "epoch untouched");

        _setDispatcherRoute(true);
        _toDispatcher(MESSAGE_ID, envelope);
        assertTrue(dispatcher.processedCcipMessage(MESSAGE_ID), "same message executes after re-enable");
        assertTrue(dispatcher.isTrackedVault(trackedVault), "allowlist updated after re-enable");
    }

    function testRetryCommandIsRefusedOnDisabledRouteAndRunsAfterReEnable() public {
        Command memory command = _failingCommand();
        _toDispatcher(keccak256("first"), _commandEnvelope(CcipMsgType.COMMAND, command, ""));
        assertEq(uint8(dispatcher.commandStatus(command.commandId)), uint8(CommandStatus.FAILED), "precondition");
        bytes memory retry = CcipMessages.encode(CcipMsgType.RETRY_COMMAND, abi.encode(command.commandId));

        _setDispatcherRoute(false);
        _toDispatcherExpectingUnknownChain(MESSAGE_ID, retry);

        _setDispatcherRoute(true);
        _toDispatcher(MESSAGE_ID, retry);
        assertTrue(dispatcher.processedCcipMessage(MESSAGE_ID), "same retry is processed after re-enable");
    }

    // ---------------------------------------------------------------------
    // Dispatcher: messages that settle or unwind existing state still pass
    // ---------------------------------------------------------------------

    function testOutboundTransferStillSettlesOnDisabledRoute() public {
        _setDispatcherRoute(false);
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount(address(token), 5e18);
        CcipClient.Any2EVMMessage memory message = _message(
            MESSAGE_ID,
            CcipMessages.encode(CcipMsgType.OUTBOUND_TRANSFER, abi.encode(OPERATION_ID)),
            EXECUTOR_SELECTOR,
            address(executor),
            tokens
        );
        vm.prank(address(router));
        dispatcher.ccipReceive(message);
        assertTrue(dispatcher.processedCcipMessage(MESSAGE_ID), "outbound processed");
        assertEq(dispatcher.trackedIdle(), 5e18, "delivered funds credited");
    }

    function testReturnRequestStillPassesOnDisabledRoute() public {
        _setDispatcherRoute(false);
        _toDispatcher(
            MESSAGE_ID,
            CcipMessages.encode(
                CcipMsgType.RETURN_REQUEST,
                abi.encode(OPERATION_ID, uint256(1e18), uint256(1e18), uint256(0), block.timestamp + 1 days)
            )
        );
        assertTrue(dispatcher.processedCcipMessage(MESSAGE_ID), "recall processed");
        assertTrue(dispatcher.processedOperation(OPERATION_ID), "recall operation recorded");
    }

    function testCancelCommandStillPassesOnDisabledRoute() public {
        Command memory command = _failingCommand();
        _toDispatcher(keccak256("first"), _commandEnvelope(CcipMsgType.COMMAND, command, ""));
        assertEq(uint8(dispatcher.commandStatus(command.commandId)), uint8(CommandStatus.FAILED), "precondition");

        _setDispatcherRoute(false);
        _toDispatcher(MESSAGE_ID, CcipMessages.encode(CcipMsgType.CANCEL_COMMAND, abi.encode(command.commandId)));
        assertTrue(dispatcher.processedCcipMessage(MESSAGE_ID), "cancel processed");
        assertEq(uint8(dispatcher.commandStatus(command.commandId)), uint8(CommandStatus.CANCELLED), "cancelled");
    }

    function testBalanceRequestStillPassesOnDisabledRoute() public {
        _setDispatcherRoute(false);
        _toDispatcher(MESSAGE_ID, CcipMessages.encode(CcipMsgType.BALANCE_REQUEST, ""));
        assertTrue(dispatcher.processedCcipMessage(MESSAGE_ID), "balance request processed");
    }

    // ---------------------------------------------------------------------
    // Executor: replies keep arriving on a disabled route
    // ---------------------------------------------------------------------

    function testExecutorStillReceivesTransferSettledOnDisabledRoute() public {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        _bridge(7e18);
        assertEq(router.heldCount(), 1, "outbound held");
        router.deliverHeld(0); // dispatcher settles and queues TRANSFER_SETTLED (route enabled, held by the router)
        assertEq(router.heldCount(), 2, "settlement reply held");
        uint64 versionBefore = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        _setExecutorRoute(false);
        router.deliverHeld(1);
        assertGt(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore, "settlement applied on disabled route");
    }

    function testExecutorStillReceivesCommandAckOnDisabledRoute() public {
        router.setAutoDeliver(false);
        address[] memory vaults = new address[](1);
        vaults[0] = trackedVault;
        _setExecutorRoute(true);
        _setDispatcherRoute(true); // lift the dispatcher lane to the same 2M gas policy
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 0);
        bytes32 commandId = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.PENDING), "command in flight");
        router.deliverHeld(0); // dispatcher executes it and its ACK is held by the router
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "command executed");
        assertEq(router.heldCount(), 2, "ACK held");

        _setExecutorRoute(false);
        router.deliverHeld(1);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "ACK applied");
    }
}
