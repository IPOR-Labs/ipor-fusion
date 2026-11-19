// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainMessages, Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateExecutorCommandEventsTest
/// @notice IL-9590 CR: the executor emits its command events through `StargateExecutorCommandLib.emitCommandEvent`,
///         which picks the event by `kind_` (0 `CommandSent`, 1 `CommandRetried`, 2 `CommandCancelRequested`).
///         Each manager action must emit exactly its own event with the active command id, so a swapped kind fails.
contract StargateExecutorCommandEventsTest is CrosschainTestBase {
    /// @dev Local re-declarations of the executor's command events (no indexed params).
    event CommandSent(uint256 dstChainId, bytes32 commandId, uint64 sequence, uint8 action);
    event CommandRetried(uint256 dstChainId, bytes32 commandId);
    event CommandCancelRequested(uint256 dstChainId, bytes32 commandId);

    function setUp() public {
        _baseSetUp();
    }

    function _command() private pure returns (Command memory) {
        return
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: CrosschainMessages.encodeDepositAction(address(0xAA17), 50e6, 0)
            });
    }

    function _failedCommand() private returns (bytes32 commandId) {
        _readyDispatcher();
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _command());
        commandId = _activeCommandId();
        _deliverCommandNack(commandId, 1);
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "FAILED");
    }

    /// @dev Counts the executor's logs by command-event topic.
    function _count(Vm.Log[] memory logs_) private view returns (uint256 sent, uint256 retried, uint256 cancelled) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter != address(executor)) continue;
            if (logs_[i].topics[0] == CommandSent.selector) ++sent;
            else if (logs_[i].topics[0] == CommandRetried.selector) ++retried;
            else if (logs_[i].topics[0] == CommandCancelRequested.selector) ++cancelled;
        }
    }

    /// @dev Negative: `_emitCommand(0, ...)` swapped to kind 1 or 2, or the emit removed -> fails.
    function testShouldEmitCommandSentOnSendCommandToDispatcher() public {
        _readyDispatcher();
        uint64 sequence = executor.nextSequenceToSend(REMOTE_CHAIN);

        vm.recordLogs();
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _command());
        bytes32 commandId = _activeCommandId();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 sent, uint256 retried, uint256 cancelled) = _count(logs);
        assertEq(sent, 1, "one CommandSent");
        assertEq(retried, 0, "no CommandRetried");
        assertEq(cancelled, 0, "no CommandCancelRequested");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == CommandSent.selector) {
                (uint256 chainId, bytes32 id, uint64 seq, uint8 action) = abi.decode(
                    logs[i].data,
                    (uint256, bytes32, uint64, uint8)
                );
                assertEq(chainId, REMOTE_CHAIN, "chain id");
                assertEq(id, commandId, "command id");
                assertEq(seq, sequence, "sequence");
                assertEq(action, uint8(BusinessAction.DEPOSIT), "action");
            }
        }
    }

    /// @dev Negative: `_emitCommand(1, ...)` in `_retry` switched to kind 0 or 2, or removed -> fails.
    function testShouldEmitExactlyCommandRetriedOnRetryCommand() public {
        bytes32 commandId = _failedCommand();

        vm.recordLogs();
        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 sent, uint256 retried, uint256 cancelled) = _count(logs);
        assertEq(retried, 1, "exactly one CommandRetried");
        assertEq(sent, 0, "no CommandSent");
        assertEq(cancelled, 0, "no CommandCancelRequested");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == CommandRetried.selector) {
                (uint256 chainId, bytes32 id) = abi.decode(logs[i].data, (uint256, bytes32));
                assertEq(chainId, REMOTE_CHAIN, "chain id");
                assertEq(id, commandId, "command id");
            }
        }
    }

    /// @dev Same as above for the budgeted retry.
    function testShouldEmitExactlyCommandRetriedOnRetryCommandWithBudget() public {
        bytes32 commandId = _failedCommand();

        vm.expectEmit(false, false, false, true, address(executor));
        emit CommandRetried(REMOTE_CHAIN, commandId);
        vm.prank(manager);
        executor.retryCommandWithBudget(REMOTE_CHAIN, 0);
    }

    /// @dev Negative: `_emitCommand(2, ...)` in `cancelCommand` switched to kind 0 or 1, or removed -> fails.
    function testShouldEmitExactlyCommandCancelRequestedOnCancelCommand() public {
        bytes32 commandId = _failedCommand();

        vm.recordLogs();
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 sent, uint256 retried, uint256 cancelled) = _count(logs);
        assertEq(cancelled, 1, "exactly one CommandCancelRequested");
        assertEq(sent, 0, "no CommandSent");
        assertEq(retried, 0, "no CommandRetried");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == CommandCancelRequested.selector) {
                (uint256 chainId, bytes32 id) = abi.decode(logs[i].data, (uint256, bytes32));
                assertEq(chainId, REMOTE_CHAIN, "chain id");
                assertEq(id, commandId, "command id");
            }
        }
    }
}
