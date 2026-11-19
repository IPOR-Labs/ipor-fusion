// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {StargateCommandLaneRealignTest} from "./StargateCommandLaneRealignTest.t.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";

/// @title StargateRealignCancelledEpochZeroTest
/// @notice IL-9590 CR #3 (D-074, reopens D-052): epoch 0 CAN carry a sequenced command on Stargate. The first
///         `UPDATE_VAULTS` FAILs on the dispatcher (the self-call revert rolls back `commandConfigEpoch = epoch + 1`)
///         and the manager's `CANCEL` consumes sequence 0, so the dispatcher sits at (sequence 1, epoch 0). A realign
///         onto that true state must succeed; the old `RealignNewEpochZero` guard refused it and left the lane on
///         `SequenceGap`.
/// @dev Reuses the two-sided fixture of `StargateCommandLaneRealignTest` by inheriting it; the inherited tests are
///      re-run under this contract name.
contract StargateRealignCancelledEpochZeroTest is StargateCommandLaneRealignTest {
    /// @dev Bring-up whose initial `UPDATE_VAULTS` names a vault over the WRONG asset, so the dispatcher fails it.
    function _failFirstUpdateVaultsThenCancel() internal {
        _registerRemote();
        MockRemoteVault wrongAssetVault = new MockRemoteVault(IERC20(address(this)), "Wrong", "WRG");
        address[] memory vaults = new address[](1);
        vaults[0] = address(wrongAssetVault);
        vm.prank(manager);
        executor.createDispatcher(REMOTE_CHAIN, vaults);
        factory.ackDispatcher(address(executor), 1, REMOTE_CHAIN);
        _relayAll(); // UPDATE_VAULTS fails on the dispatcher, the FAILED receipt returns

        (, , , , bytes32 commandId, , ) = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "first UPDATE_VAULTS failed");
        assertEq(dispatcher.commandConfigEpoch(), 0, "failed update rolled the epoch back");

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll(); // CANCEL consumes sequence 0 on the dispatcher; the CANCELLED receipt returns
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.CANCELLED), "cancelled");
        assertEq(dispatcher.nextCommandSequence(), 1, "dispatcher sequence 1");
        assertEq(dispatcher.commandConfigEpoch(), 0, "dispatcher epoch 0");
    }

    /// @notice An executor desynced from (sequence 1, epoch 0) realigns back onto it: epoch 0 with a non-zero
    ///         sequence is accepted.
    function testShouldRealignToEpochZeroWithNonZeroSequenceAfterAFailedAndCancelledFirstUpdate() public {
        _failFirstUpdateVaultsThenCancel();
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 1, "executor mirror in sync before the desync");

        // Desync the mirror with a legitimate (0, 0) realign, then realign back onto the dispatcher's true state.
        _realign(0, 0);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 0, "executor desynced to (0, 0)");

        _realign(dispatcher.commandConfigEpoch(), dispatcher.nextCommandSequence());

        _assertMirrorsMatchDispatcher("realigned onto the cancelled (1, 0) state");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 0, "epoch mirror 0");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 1, "sequence mirror 1");
    }
}
