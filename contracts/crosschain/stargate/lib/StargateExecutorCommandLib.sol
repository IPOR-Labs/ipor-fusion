// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {BusinessAction, CommandStatus, MsgType, CrosschainConstants} from "../../lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    UpdateVaults,
    RetryCommand,
    CancelCommand,
    SweepFloor
} from "../../lib/CrosschainMessages.sol";
import {StargateExecutorState, ActiveCommand} from "./StargateExecutorState.sol";

/// @title StargateExecutorCommandLib
/// @notice The `StargateCrosschainExecutor` outbound command-lane builders (business command, UPDATE_VAULTS,
///         RETRY_COMMAND, CANCEL_COMMAND): allocate or re-arm the chain's single active-command slot and return the
///         encoded envelope for the executor to send. Extracted from `StargateExecutorAccountingLib` into its own
///         external linked library to keep that library under the EIP-170 runtime limit; the bodies are unchanged.
/// @dev Operates on the executor's own storage via `StargateExecutorState storage self` (delegatecall), so
///      `address(this)` is the executor and the id derivations match it exactly. Access control and the actual
///      LayerZero send stay on the executor. The executor declares this library's event and errors (via
///      `IStargateExecutorLibraryAbi` / `CrosschainErrors`), so its ABI decodes them;
///      `CrosschainLibraryAbiCompletenessTest` enforces this.
/// @author IPOR Labs
library StargateExecutorCommandLib {
    using OptionsBuilder for bytes;

    /// @notice The executor built an UPDATE_VAULTS command for `dstChainId`.
    /// @dev `vaults` is the full replacement allowlist sent to the remote dispatcher. `newConfigEpoch` joins
    ///      it to the dispatcher's `VaultsUpdated(commandConfigEpoch, ...)` on the remote chain (the list was
    ///      applied); `commandId` joins it to the executor's ACK / NACK handling (a NACKed update was not
    ///      applied).
    event VaultsUpdateRequested(
        uint256 dstChainId, bytes32 commandId, uint64 sequence, uint64 newConfigEpoch, address[] vaults
    );
    /// @notice A command was sent to the dispatcher. Same signature as the executor's declaration.
    event CommandSent(uint256 dstChainId, bytes32 commandId, uint64 sequence, uint8 action);
    /// @notice A FAILED command was re-armed and a RETRY_COMMAND was sent. Same signature as the executor's.
    event CommandRetried(uint256 dstChainId, bytes32 commandId);
    /// @notice A CANCEL_COMMAND was sent for a FAILED command. Same signature as the executor's.
    event CommandCancelRequested(uint256 dstChainId, bytes32 commandId);

    /// @dev Emits one of the executor's command events (kind 0 `CommandSent`, 1 `CommandRetried`, 2
    ///      `CommandCancelRequested`) from the executor's address under delegatecall. The executor calls it after the
    ///      LayerZero send, keeping the event order of the inlined version (EIP-170).
    function emitCommandEvent(
        uint8 kind_,
        uint256 chainId_,
        bytes32 commandId_,
        uint64 sequence_,
        uint8 action_
    ) public {
        if (kind_ == 0) emit CommandSent(chainId_, commandId_, sequence_, action_);
        else if (kind_ == 1) emit CommandRetried(chainId_, commandId_);
        else emit CommandCancelRequested(chainId_, commandId_);
    }

    /// @dev Allocate a business command in the free slot and return its encoded COMMAND envelope. The
    ///      executor allocates the authoritative id/sequence/commandConfigEpoch and the gas budget (IL-8625): the
    ///      chain's registered command-lane gas minus its 1/64 hop loss and the payload-dependent pre-call work
    ///      (`CrosschainMessages.commandGasBudget`). `requestedBudget_` is the manager's `Command.minExecutionGas`:
    ///      up to the lane budget (0 included) it keeps the lane budget; above `MAX_COMMAND_EXECUTION_GAS` it reverts
    ///      `CommandBudgetAboveMax`; in between it becomes the budget and `extraOptions` carries the extra
    ///      `lzReceive` gas that makes the formula, applied to the total delivered gas, reach it. Only
    ///      `action`/`actionData`/`minExecutionGas` come from the manager.
    function buildBusinessCommand(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint8 action_,
        bytes memory actionData_,
        uint256 commandNonce_,
        uint256 requestedBudget_
    ) public returns (bytes memory payload, bytes32 commandId, uint64 sequence, bytes memory extraOptions) {
        if (self.activeCommand[chainId_].active) {
            revert CrosschainErrors.ActiveCommandExists(chainId_);
        }
        if (requestedBudget_ > CrosschainConstants.MAX_COMMAND_EXECUTION_GAS) {
            revert CrosschainErrors.CommandBudgetAboveMax(requestedBudget_, CrosschainConstants.MAX_COMMAND_EXECUTION_GAS);
        }
        sequence = self.nextSequenceToSend[chainId_];
        // The id carries the command's expiry (IL-8255); see `CrosschainMessages.stampCommandId`.
        commandId = CrosschainMessages.stampCommandId(
            keccak256(abi.encode(address(this), chainId_, "CMD", sequence, commandNonce_))
        );
        Command memory command = Command({
            commandId: commandId,
            sequence: sequence,
            commandConfigEpoch: self.chainConfigEpoch[chainId_],
            action: action_,
            minExecutionGas: 0,
            actionData: actionData_
        });
        // The encoded length does not depend on the budget value (fixed-size field), so the word count is exact.
        uint256 words = CrosschainMessages.payloadWords(abi.encode(command).length);
        uint256 budget;
        (budget, extraOptions) = _budgetAndTopUp(self.commandLaneReceiveGas[chainId_], words, requestedBudget_);
        command.minExecutionGas = uint64(budget);
        bytes memory inner = abi.encode(command);
        self.activeCommand[chainId_] = ActiveCommand({
            active: true,
            isConfigUpdate: false,
            awaitingCancel: false,
            status: CommandStatus.PENDING,
            target: _depositTarget(action_, actionData_),
            commandId: commandId,
            sequence: sequence,
            newConfigEpoch: 0,
            commitment: keccak256(abi.encode(uint8(MsgType.COMMAND), inner)),
            action: action_,
            lastCancelAt: 0,
            minExecutionGas: uint64(budget),
            payloadWords: uint32(words)
        });
        payload = CrosschainMessages.encodeEnvelope(MsgType.COMMAND, inner);
    }

    /// @dev The lane budget for `words_` stored words and, when `requested_` exceeds it, the capped extra `lzReceive`
    ///      option that lifts the total delivered gas to what `requested_` needs (IL-8625).
    function _budgetAndTopUp(uint256 laneGas_, uint256 words_, uint256 requested_)
        private
        pure
        returns (uint256 budget, bytes memory extraOptions)
    {
        budget = CrosschainMessages.commandGasBudget(laneGas_, words_, true);
        if (requested_ > budget) {
            budget = requested_;
            extraOptions = _extraGasOption(laneGas_, words_, requested_);
        }
    }

    function _extraGasOption(uint256 laneGas_, uint256 words_, uint256 budget_) private pure returns (bytes memory) {
        uint256 total = CrosschainMessages.laneGasFor(budget_, words_, true);
        // `total > laneGas_` whenever the budget exceeds the lane budget (`laneGasFor` is the exact inverse).
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(total - laneGas_), 0);
    }

    /// @dev Target vault of a DEPOSIT (0 for any other action); stored so a retry can re-check its substrate.
    function _depositTarget(uint8 action_, bytes memory actionData_) private pure returns (address vault) {
        if (action_ == uint8(BusinessAction.DEPOSIT)) (vault,,) = CrosschainMessages.decodeDepositAction(actionData_);
    }

    /// @dev Allocate a sequenced UPDATE_VAULTS command and return its encoded envelope (shared by the
    ///      manager path and the factory-callback auto-send; the slot is free in both cases). The budget comes from
    ///      the lane and the payload size (a 32-vault list with 32 sweep floors is the largest case); there is no
    ///      manager top-up path. IL-9629: `floors_` (shared decimals, forwarded verbatim) is validated like a vault
    ///      list: at most `MAX_TRACKED_POSITION_VAULTS` entries (`VaultsCapReached`), no zero or duplicate vault
    ///      (`InvalidVault`).
    function buildUpdateVaults(
        StargateExecutorState storage self,
        uint256 chainId_,
        address[] memory vaults_,
        SweepFloor[] memory floors_,
        uint256 commandNonce_
    ) public returns (bytes memory payload, bytes32 commandId, uint64 sequence) {
        _validateSweepFloors(floors_);
        sequence = self.nextSequenceToSend[chainId_];
        uint64 newEpoch = self.chainConfigEpoch[chainId_] + 1;
        commandId = CrosschainMessages.stampCommandId(
            keccak256(abi.encode(address(this), chainId_, "UPDATE", sequence, commandNonce_))
        );
        UpdateVaults memory u = UpdateVaults({
            commandId: commandId,
            sequence: sequence,
            newConfigEpoch: newEpoch,
            minExecutionGas: 0,
            vaults: vaults_,
            floors: floors_
        });
        uint256 words = CrosschainMessages.payloadWords(abi.encode(u).length);
        u.minExecutionGas = CrosschainMessages.commandGasBudget(self.commandLaneReceiveGas[chainId_], words, true);
        bytes memory inner = abi.encode(u);
        self.activeCommand[chainId_] = ActiveCommand({
            active: true,
            isConfigUpdate: true,
            awaitingCancel: false,
            status: CommandStatus.PENDING,
            target: address(0),
            commandId: commandId,
            sequence: sequence,
            newConfigEpoch: newEpoch,
            commitment: keccak256(abi.encode(uint8(MsgType.UPDATE_VAULTS), inner)),
            action: 0,
            lastCancelAt: 0,
            minExecutionGas: u.minExecutionGas,
            payloadWords: uint32(words)
        });
        payload = CrosschainMessages.encodeEnvelope(MsgType.UPDATE_VAULTS, inner);
        emit VaultsUpdateRequested(chainId_, commandId, sequence, newEpoch, vaults_);
    }

    /// @dev Shape of the sweep floors of an UPDATE_VAULTS (IL-9629), the same rule as a vault list.
    function _validateSweepFloors(SweepFloor[] memory floors_) private pure {
        uint256 len = floors_.length;
        if (len > CrosschainConstants.MAX_TRACKED_POSITION_VAULTS) {
            revert CrosschainErrors.VaultsCapReached(CrosschainConstants.MAX_TRACKED_POSITION_VAULTS);
        }
        for (uint256 i; i < len; ++i) {
            address v = floors_[i].vault;
            if (v == address(0)) revert CrosschainErrors.InvalidVault(v);
            for (uint256 j = i + 1; j < len; ++j) {
                if (floors_[j].vault == v) revert CrosschainErrors.InvalidVault(v);
            }
        }
    }

    /// @dev Re-arm a FAILED command to PENDING and return the encoded RETRY_COMMAND envelope.
    /// @dev A cancel is terminal once issued: the dispatcher resolves the command as CANCELLED and the
    ///      later RETRY is dropped as a duplicate, so a retry racing an in-flight cancel can only ever
    ///      misrepresent the outcome. Reject it outright rather than silently clearing the flag.
    ///      IL-8625: `retryBudget_` (0 = keep) can only raise the command's effective budget (above
    ///      `MAX_COMMAND_EXECUTION_GAS` it reverts `CommandBudgetAboveMax`; past the command's deadline the retry
    ///      reverts `CommandExpired`); the retry is sent with the extra `lzReceive` gas that the effective budget
    ///      (the stored one, a top-up included, or the raise) needs on top of the lane, so an honest delivery reaches
    ///      the dispatcher's check. The dispatcher runs `max(stored, persisted raise, retryBudget)`.
    function buildRetry(StargateExecutorState storage self, uint256 chainId_, uint256 retryBudget_)
        public
        returns (bytes memory payload, bytes32 commandId, bytes memory extraOptions)
    {
        ActiveCommand storage ac = self.activeCommand[chainId_];
        if (!ac.active) revert CrosschainErrors.NoActiveCommand(chainId_);
        if (ac.status != CommandStatus.FAILED) revert CrosschainErrors.CommandNotFailed(chainId_);
        if (ac.awaitingCancel) revert CrosschainErrors.CancelInFlight(chainId_, ac.commandId);
        // IL-8625: a retry of a command past its deadline can only end in a NACK (the dispatcher checks the deadline
        // first), so it is refused rather than paying the fee and a raise; the manager's CANCEL is the exit.
        if (block.timestamp > CrosschainMessages.commandDeadline(ac.commandId)) {
            revert CrosschainErrors.CommandExpired(ac.commandId);
        }
        if (retryBudget_ > CrosschainConstants.MAX_COMMAND_EXECUTION_GAS) {
            revert CrosschainErrors.CommandBudgetAboveMax(retryBudget_, CrosschainConstants.MAX_COMMAND_EXECUTION_GAS);
        }
        uint256 effective = ac.minExecutionGas;
        if (retryBudget_ > effective) effective = retryBudget_;
        uint256 laneGas = self.commandLaneReceiveGas[chainId_];
        if (effective > CrosschainMessages.commandGasBudget(laneGas, ac.payloadWords, true)) {
            extraOptions = _extraGasOption(laneGas, ac.payloadWords, effective);
        }
        ac.minExecutionGas = uint64(effective);
        ac.status = CommandStatus.PENDING;
        commandId = ac.commandId;
        payload = CrosschainMessages.encodeRetryCommand(
            RetryCommand({commandId: commandId, minExecutionGas: uint64(retryBudget_)})
        );
    }

    /// @dev Mark a FAILED command as awaiting cancel and return the encoded CANCEL_COMMAND envelope. A repeat is
    ///      accepted only `CANCEL_COMMAND_COOLDOWN` after the previous one (reverts `CancelCooldown`, IL-8579).
    function buildCancel(StargateExecutorState storage self, uint256 chainId_)
        public
        returns (bytes memory payload, bytes32 commandId)
    {
        ActiveCommand storage ac = self.activeCommand[chainId_];
        if (!ac.active) revert CrosschainErrors.NoActiveCommand(chainId_);
        if (ac.status != CommandStatus.FAILED) revert CrosschainErrors.CommandNotFailed(chainId_);
        commandId = ac.commandId;
        // IL-8579: a repeat is allowed (a lost cancel must be re-sendable) but metered, each send costs a fee.
        uint256 last = ac.lastCancelAt;
        if (last != 0 && block.timestamp < last + CrosschainConstants.CANCEL_COMMAND_COOLDOWN) {
            revert CrosschainErrors.CancelCooldown(
                chainId_, commandId, last + CrosschainConstants.CANCEL_COMMAND_COOLDOWN
            );
        }
        ac.lastCancelAt = uint64(block.timestamp);
        ac.awaitingCancel = true;
        payload = CrosschainMessages.encodeCancelCommand(CancelCommand({commandId: commandId}));
    }
}
