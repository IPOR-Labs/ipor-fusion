// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainMessages, Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction, CommandStatus, CommandResolution} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title ExecutorCommandTest
/// @notice One active business command per chain, retry/cancel only from FAILED, the recall lane's
///         independence (a FAILED DEPOSIT never blocks `requestAssets`), and ACK advancing sequence+frontier
///         while NACK advances neither (plan §4.4/§4.6, spec §9).
contract ExecutorCommandTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
    }

    function _depositCommand() internal pure returns (Command memory) {
        return Command({
            commandId: bytes32(0), // executor allocates the authoritative id
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.DEPOSIT),
            minExecutionGas: DEFAULT_COMMAND_BUDGET,
            actionData: CrosschainMessages.encodeDepositAction(address(0xAA17), 50e6, 0)
        });
    }

    function _send() internal returns (bytes32 commandId) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand());
        return _activeCommandId();
    }

    // ---------------------------------------------------------------------
    // One active command per chain
    // ---------------------------------------------------------------------

    function testShouldAllowOnlyOneActiveCommandPerChain() public {
        _readyDispatcher();
        _send();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ActiveCommandExists.selector, REMOTE_CHAIN));
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand());
    }

    function testShouldRejectCommandFromNonManager() public {
        _readyDispatcher();
        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedManager.selector, address(0xdead)));
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand());
    }

    // ---------------------------------------------------------------------
    // ACK advances the sequence but never the frontier (IL-8257); NACK advances neither
    // ---------------------------------------------------------------------

    function testShouldClearSlotAndAdvanceSequenceOnAck() public {
        _readyDispatcher();
        bytes32 commandId = _send();
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING));
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 1);

        _deliverCommandAck(commandId, 1, 0, 0);

        (bool active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertFalse(active, "slot cleared on ACK");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 2, "sequence advanced");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "an ACK never advances the frontier");
    }

    function testShouldHoldSlotAndNotAdvanceOnNack() public {
        _readyDispatcher();
        bytes32 commandId = _send();
        _deliverCommandNack(commandId, 1);

        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "marked FAILED");
        (bool active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(active, "slot stays occupied");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 1, "sequence NOT advanced");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "frontier NOT advanced");
    }

    function testShouldRejectNonzeroValueDeltaOnAck() public {
        // §9 P2 item 7: for the POC every command reports a zero settled delta; a nonzero delta from an
        // arbitrary receipt field is never trusted and reverts (the executor no longer credits it).
        _readyDispatcher();
        bytes32 commandId = _send();
        uint64 epoch = executor.chainConfigEpoch(REMOTE_CHAIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnexpectedValueDelta.selector, int256(10e6)));
        _deliverCommandAckAs(commandId, 1, 0, int256(10e6), CommandResolution.SUCCEEDED, epoch);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "no settled mutation from an untrusted delta");
    }

    function testShouldRejectAckWithWrongSequence() public {
        // §9 P2 item 6: a receipt whose sequence does not match the active command's is impossible/forged.
        _readyDispatcher();
        bytes32 commandId = _send(); // active at sequence 1
        uint64 epoch = executor.chainConfigEpoch(REMOTE_CHAIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ReceiptSequenceMismatch.selector, uint64(1), uint64(2)));
        _deliverCommandAckAs(commandId, 2, 2, 0, CommandResolution.SUCCEEDED, epoch);
    }

    function testShouldRejectNackWithWrongSequence() public {
        _readyDispatcher();
        bytes32 commandId = _send(); // active at sequence 1
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ReceiptSequenceMismatch.selector, uint64(1), uint64(2)));
        _deliverCommandNack(commandId, 2);
    }

    function testShouldSendSequentialCommandsAfterAck() public {
        _readyDispatcher();
        bytes32 c1 = _send();
        _deliverCommandAck(c1, 1, 0, 0);
        // Next command takes sequence 2; command ACKs carry the (unchanged) current version as evidence only.
        bytes32 c2 = _send();
        _deliverCommandAck(c2, 2, 0, 0);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 3);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0);
    }

    // ---------------------------------------------------------------------
    // Retry only from FAILED
    // ---------------------------------------------------------------------

    function testShouldRetryOnlyFromFailed() public {
        _readyDispatcher();
        bytes32 commandId = _send(); // PENDING

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandNotFailed.selector, REMOTE_CHAIN));
        executor.retryCommand(REMOTE_CHAIN);

        _deliverCommandNack(commandId, 1); // FAILED
        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "retry re-arms PENDING");
    }

    function testShouldRejectRetryWithNoActiveCommand() public {
        _readyDispatcher();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NoActiveCommand.selector, REMOTE_CHAIN));
        executor.retryCommand(REMOTE_CHAIN);
    }

    // ---------------------------------------------------------------------
    // Cancel only from FAILED
    // ---------------------------------------------------------------------

    function testShouldCancelOnlyFromFailed() public {
        _readyDispatcher();
        bytes32 commandId = _send(); // PENDING

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandNotFailed.selector, REMOTE_CHAIN));
        executor.cancelCommand(REMOTE_CHAIN);

        _deliverCommandNack(commandId, 1); // FAILED
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        (,, bool awaitingCancel,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(awaitingCancel, "cancel requested");

        // The dispatcher's cancel-resolution ACK (reused ACK envelope) clears the slot and advances one.
        _deliverCommandCancelAck(commandId, 1, 2);
        (bool active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertFalse(active, "slot freed on cancel resolution");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 2, "sequence advanced by cancel");
    }

    function testShouldNotCommitConfigEpochWhenUpdateVaultsIsCancelled() public {
        _readyDispatcher();
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 1);

        address[] memory vaults = new address[](1);
        vaults[0] = address(0xBEEF);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        (,,,, bytes32 commandId, uint64 sequence,) = executor.activeCommand(REMOTE_CHAIN);

        _deliverCommandNack(commandId, sequence);
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _deliverCommandCancelAck(commandId, sequence, 2);

        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 1, "cancel must not commit unapplied epoch");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 2, "cancel still resolves the sequence");
    }

    // ---------------------------------------------------------------------
    // Recall lane independence: a FAILED business command never blocks a recall
    // ---------------------------------------------------------------------

    function testShouldNotBlockRecallOnFailedCommand() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2, nextCommandSequence = 1

        bytes32 commandId = _send(); // DEPOSIT PENDING at sequence 1
        _deliverCommandNack(commandId, 1); // FAILED, slot occupied
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED));

        // The recall lane is sequence-exempt: requesting assets home succeeds despite the FAILED command.
        (bytes32 requestId, uint256 amountSD, uint256 maxAccountedSD) = _requestAssets(40e6, 0);
        assertEq(amountSD, 40e6);
        assertEq(maxAccountedSD, 40e6, "bounded by settled");

        // And the return can complete while the business command is still FAILED.
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.idleLedger(), 40e6, "recall settled to idle despite FAILED command");

        (bool active,,, CommandStatus status,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(active, "business command slot untouched by the recall");
        assertEq(uint8(status), uint8(CommandStatus.FAILED));
    }
}
