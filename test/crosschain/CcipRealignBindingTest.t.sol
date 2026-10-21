// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {CcipCommandLaneRealignTest} from "./CcipCommandLaneRealignTest.t.sol";

/// @title CcipRealignBindingTest
/// @notice IL-8586 (Ackee TP-M-08): `REALIGN_COMMAND_LANE` is bound to the mirrors it was armed against, so an
///         authenticated ACK that advances the lane during the timelock makes the stale rescue revert
///         `RealignStateMoved` instead of rolling the sequence backwards.
/// @dev Reuses the fixture (real dispatcher, held response queue) of `CcipCommandLaneRealignTest` by
///      inheriting it; the inherited tests are simply re-run under this contract name.
contract CcipRealignBindingTest is CcipCommandLaneRealignTest {
    /// @dev Executor behind the dispatcher by one: the deposit ran remotely, its ACK is stuck in the queue and
    ///      the operator abandoned the command without consuming the sequence.
    function _executorBehindWithQueuedAck() internal {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        _holdResponses();
        _sendDeposit(vault, 50e18);
        _abandon(false);
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN) + 1, dispatcher.nextCommandSequence(), "executor behind");
    }

    /// @dev A command whose ACK is lost for good: the slot stays occupied and can be abandoned.
    function _stuckCommandWithLostAck() internal returns (uint64 epoch, uint64 sequence) {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        _holdResponses();
        _sendDeposit(vault, 50e18);
        _skipHead();
        _releaseResponses();
        epoch = executor.commandConfigEpoch(REMOTE_CHAIN);
        sequence = executor.nextCommandSequence(REMOTE_CHAIN);
    }

    function _schedule(uint256 arg_) internal returns (uint256 rescueId) {
        vm.prank(ADMIN);
        rescueId = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg_);
    }

    function _execute(uint256 rescueId_, uint256 arg_) internal {
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId_, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg_);
    }

    /// @notice The finding: the rescue snapshot (sequence 0) is armed, then the late ACK moves the mirror to 1.
    ///         Without the binding the rescue would write 0 back over the newer sequence.
    function testShouldRevertRealignWhenAckAdvancedTheLaneDuringDelay() public {
        _executorBehindWithQueuedAck();
        uint64 epoch = executor.commandConfigEpoch(REMOTE_CHAIN);
        uint64 staleSequence = executor.nextCommandSequence(REMOTE_CHAIN);
        uint256 arg = _realignArg(epoch, staleSequence); // armed against (epoch, staleSequence), writes the same

        uint256 rescueId = _schedule(arg);
        _releaseResponses(); // the late ACK lands during the delay and advances the mirror
        uint64 advanced = executor.nextCommandSequence(REMOTE_CHAIN);
        assertEq(advanced, staleSequence + 1, "the ACK advanced the sequence mirror");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "and the slot is free, so the old check passes");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorCommandLib.RealignStateMoved.selector, REMOTE_CHAIN, staleSequence, advanced, epoch, epoch
            )
        );
        _execute(rescueId, arg);

        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), advanced, "the lane was not rolled backwards");
    }

    function testShouldRealignWhenStateUnchangedDuringDelay() public {
        _executorBehindWithQueuedAck();
        uint64 epoch = executor.commandConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextCommandSequence(REMOTE_CHAIN);
        uint256 arg = _realignArgFrom(epoch, sequence, epoch + 2, sequence + 5);

        uint256 rescueId = _schedule(arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        _execute(rescueId, arg);

        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), sequence + 5, "sequence realigned");
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epoch + 2, "epoch realigned");
    }

    function testShouldRescheduleRealignFromNewStateAfterRevert() public {
        _executorBehindWithQueuedAck();
        uint64 epoch = executor.commandConfigEpoch(REMOTE_CHAIN);
        uint256 stale = _realignArg(epoch, executor.nextCommandSequence(REMOTE_CHAIN));
        uint256 staleId = _schedule(stale);
        _releaseResponses();
        vm.warp(block.timestamp + RESCUE_DELAY);
        uint64 advanced = executor.nextCommandSequence(REMOTE_CHAIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorCommandLib.RealignStateMoved.selector, REMOTE_CHAIN, advanced - 1, advanced, epoch, epoch
            )
        );
        _execute(staleId, stale);

        // Reschedule from the new state: expected pair = what the ACK left behind.
        uint64 newSequence = executor.nextCommandSequence(REMOTE_CHAIN);
        uint256 fresh = _realignArg(epoch, newSequence + 3);
        uint256 freshId = _schedule(fresh);
        vm.warp(block.timestamp + RESCUE_DELAY);
        _execute(freshId, fresh);

        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), newSequence + 3, "realigned from the new state");
    }

    function testShouldRealignAfterConsumedAbandonInSameBatch() public {
        (uint64 epoch, uint64 sequence) = _stuckCommandWithLostAck();
        _abandonThenRealign(true, epoch + 1, sequence + 4);

        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), sequence + 4, "sequence realigned after abandon");
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epoch + 1, "epoch realigned after abandon");
    }

    function testShouldRevertRealignWhenConsumedAbandonPlusOneIsOmitted() public {
        (uint64 epoch, uint64 sequence) = _stuckCommandWithLostAck();
        // Admin passes the pre-abandon sequence: the consumed abandon moves the mirror to sequence + 1 first.
        uint256 abandonArg = _abandonArg(true);
        uint256 realignArg = _realignArgFrom(epoch, sequence, epoch, sequence + 4);
        vm.startPrank(ADMIN);
        uint256 abandonId = executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, abandonArg);
        uint256 realignId =
            executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, realignArg);
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(ADMIN);
        executor.executeChainRescue(abandonId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, abandonArg);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorCommandLib.RealignStateMoved.selector, REMOTE_CHAIN, sequence, sequence + 1, epoch, epoch
            )
        );
        executor.executeChainRescue(realignId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, realignArg);
        vm.stopPrank();
    }

    function testShouldRefuseRealignScheduleWithZeroExpectedEpoch() public {
        _executorBehindWithQueuedAck();
        uint256 legacy = (uint256(1) << 64) | uint256(3); // pre-IL-8586 shape: upper 128 bits unset
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSignature("RealignExpectedEpochZero(uint256)", REMOTE_CHAIN));
        executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, legacy);
    }
}
