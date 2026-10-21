// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ExecutorCommandTest} from "./ExecutorCommandTest.t.sol";
import {CommandStatus, CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @notice IL-8579: Stargate `cancelCommand` repeats are allowed (a lost cancel must be re-sendable) but metered
///         per command by `CANCEL_COMMAND_COOLDOWN`, so a manager cannot drain the executor's native budget.
contract StargateCancelCommandCooldownTest is ExecutorCommandTest {
    function _failed() internal returns (bytes32 commandId) {
        _readyDispatcher();
        commandId = _send();
        _deliverCommandNack(commandId, 1);
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "FAILED");
    }

    function _cancel() internal {
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
    }

    function testShouldRejectSecondCancelWithinCooldownAndChargeOneFee() public {
        bytes32 commandId = _failed();
        uint256 fee = endpoint.messagingFee();
        uint256 balanceBefore = address(executor).balance;
        uint256 sentBefore = endpoint.sentCount();
        uint256 sentAt = block.timestamp;
        _cancel();

        for (uint256 i; i < 5; ++i) {
            vm.warp(sentAt + i * 1 minutes + 1 minutes);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CrosschainErrors.CancelCooldown.selector,
                    REMOTE_CHAIN,
                    commandId,
                    sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN
                )
            );
            _cancel();
        }
        vm.warp(sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.CancelCooldown.selector,
                REMOTE_CHAIN,
                commandId,
                sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN
            )
        );
        _cancel();

        assertEq(endpoint.sentCount() - sentBefore, 1, "one LayerZero send");
        assertEq(balanceBefore - address(executor).balance, fee, "exactly one fee charged");
    }

    function testShouldAcceptRepeatCancelAfterCooldownAndStillEndCancelled() public {
        bytes32 commandId = _failed();
        uint256 sentBefore = endpoint.sentCount();
        _cancel(); // assume this one is lost in transit
        vm.warp(block.timestamp + CrosschainConstants.CANCEL_COMMAND_COOLDOWN);
        _cancel();
        assertEq(endpoint.sentCount() - sentBefore, 2, "the re-sent cancel left the executor");

        _deliverCommandCancelAck(commandId, 1, 2);
        (bool active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertFalse(active, "slot freed on the cancel ACK");
    }

    function testShouldResetCooldownWhenTheSlotHoldsANewCommand() public {
        bytes32 commandId = _failed();
        _cancel();
        _deliverCommandCancelAck(commandId, 1, 2);

        // a new command occupies the slot and fails: its first cancel is not metered by the previous one
        _send();
        (,,,, bytes32 secondId,,) = executor.activeCommand(REMOTE_CHAIN);
        _deliverCommandNack(secondId, 2);
        _cancel();
    }

    function testShouldKeepRetryRejectedWhileCancelIsInFlight() public {
        bytes32 commandId = _failed();
        _cancel();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CancelInFlight.selector, REMOTE_CHAIN, commandId));
        executor.retryCommand(REMOTE_CHAIN);
    }
}
