// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {StargateCommandLaneRealignTest} from "./StargateCommandLaneRealignTest.t.sol";

/// @title StargateRealignNewEpochZeroTest
/// @notice IL-9590 (D-074, reopens the IL-9683 / D-052 guard): `REALIGN_COMMAND_LANE` on Stargate accepts a declared
///         new config epoch of zero with ANY sequence, because epoch 0 can carry cancelled commands (a FAILED first
///         `UPDATE_VAULTS` plus its CANCEL gives (sequence 1, epoch 0)). The CCIP twin keeps its strict guard.
/// @dev Reuses the fixture of `StargateCommandLaneRealignTest` by inheriting it; the inherited tests are simply
///      re-run under this contract name. The error is built from its signature so the test also compiles against
///      the pre-fix library.
contract StargateRealignNewEpochZeroTest is StargateCommandLaneRealignTest {
    function _scheduleAndWait(bytes32 id_) internal returns (uint256 rescueId) {
        vm.prank(admin);
        rescueId = executor.scheduleForceResolveTransfer(id_, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.warp(block.timestamp + RESCUE_DELAY);
    }

    function _execute(uint256 rescueId_, bytes32 id_) internal {
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId_, id_, ResolveOutcome.REALIGN_COMMAND_LANE);
    }

    /// @notice A realign armed against the live mirrors that declares (epoch 0, sequence 7) now succeeds (was
    ///         `RealignNewEpochZero` under D-052) and writes both mirrors.
    function testShouldAllowRealignToEpochZeroWithNonZeroSequence() public {
        _readyWithoutCapital();
        bytes32 id = _realignId(REMOTE_CHAIN, 0, 7);
        uint256 rescueId = _scheduleAndWait(id);

        _execute(rescueId, id);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 7, "sequence mirror written");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 0, "epoch mirror written");
    }

    /// @notice Epoch 0 with sequence 0 stays allowed: the pre-first-UPDATE_VAULTS recovery state.
    function testShouldAllowRealignToEpochZeroWithSequenceZero() public {
        _readyWithoutCapital();
        _realign(0, 0);

        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 0, "epoch mirror");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 0, "sequence mirror");
    }

    /// @notice The free-slot check still applies: with a command active the realign reverts `ActiveCommandExists`.
    function testShouldRevertActiveCommandForAnEpochZeroRealign() public {
        _readyWithCapital();
        _commandWithUndeliveredAck();

        bytes32 id = _realignId(REMOTE_CHAIN, 0, 1);
        uint256 rescueId = _scheduleAndWait(id);

        vm.expectPartialRevert(bytes4(keccak256("ActiveCommandExists(uint256)")));
        _execute(rescueId, id);
    }

    /// @notice The binding check still applies: a stale expected pair reports `RealignStateMoved`.
    function testShouldRevertStateMovedForAnEpochZeroRealign() public {
        _readyWithoutCapital();
        uint64 epoch = executor.chainConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextSequenceToSend(REMOTE_CHAIN);
        bytes32 id = _realignIdFrom(REMOTE_CHAIN, epoch + 1, sequence, 0, 5);
        uint256 rescueId = _scheduleAndWait(id);

        vm.expectPartialRevert(bytes4(keccak256("RealignStateMoved(uint256,uint64,uint64,uint64,uint64)")));
        _execute(rescueId, id);
    }

    /// @notice A non-zero declared epoch still realigns (the smallest accepted value, 1).
    function testShouldStillRealignToEpochOne() public {
        _readyWithoutCapital();
        _realign(1, 7);

        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 1, "epoch mirror");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 7, "sequence mirror");
    }
}
