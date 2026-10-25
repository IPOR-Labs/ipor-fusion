// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ICcipExecutorLibraryAbi
/// @notice ABI declarations for the events and errors of CcipExecutorAttestationLib, CcipExecutorCommandLib,
///         CcipExecutorTransferLib and CcipDecimalsLib (including the shared `CrosschainErrors` and OpenZeppelin
///         errors raised inside them) that CcipCrosschainExecutor does not declare itself.
/// @dev Declarations only. Linked libraries run under delegatecall, so their events/errors are
///      emitted/raised from the host address but only appear in the host ABI if declared here.
///      Adds no runtime bytecode. Kept complete by CrosschainLibraryAbiCompletenessTest.
/// @author IPOR Labs
interface ICcipExecutorLibraryAbi {
    event AttestationAnchorRebased(uint256 chainId, uint256 principalSD);
    event AttestationAnchorUpdated(uint256 chainId, uint256 principalSD);
    event AttestationNetPrincipalUpdated(uint256 chainId, uint256 netPrincipalSD);
    event CommandAbandoned(uint256 chainId, bytes32 commandId, uint64 sequence, bool sequenceConsumed);
    event CommandAcknowledged(
        uint256 srcChainId,
        bytes32 commandId,
        uint64 sequence,
        uint64 stateVersion,
        int256 valueDelta,
        uint8 resolution,
        uint64 commandConfigEpoch
    );
    event CommandLaneRealigned(
        uint256 chainId,
        uint64 previousSequence,
        uint64 newSequence,
        uint64 previousEpoch,
        uint64 newEpoch
    );
    event CommandReceiptAdopted(
        uint256 chainId,
        bytes32 commandId,
        uint64 sequence,
        uint64 dispatcherConfigEpoch,
        bytes32 supersededCommandId
    );
    event CommandRetryRequested(uint256 chainId, bytes32 commandId);
    event CommandSent(
        uint256 dstChainId,
        bytes32 commandId,
        uint64 sequence,
        uint8 action,
        bool advancesConfig,
        uint64 commandConfigEpoch
    );
    event ConfigEpochResynced(uint256 chainId, uint64 expectedEpoch, uint64 dispatcherEpoch);
    event LateReceiptEpochAdopted(uint256 chainId, uint64 sequence, uint64 previousEpoch, uint64 newEpoch);
    event LateReceiptRetiredPendingReplacement(uint256 chainId, uint64 sequence, bytes32 retiredCommandId);
    /// @dev Mirror of `CcipExecutorCommandLib.CommandExpiryReleased` (IL-8594).
    event CommandExpiryReleased(uint256 chainId, bytes32 commandId, uint64 sequence);
    event ProposalInvalidated(uint256 chainId, uint256 proposalId, uint64 newEpoch);
    event ReturnDebitExceededAccountingBound(
        uint256 chainId,
        bytes32 operationId,
        uint256 sentSD,
        uint256 bound
    );
    event SettledCreditClamped(uint256 chainId, bytes32 operationId, uint256 reported, uint256 credited);
    event LateSettlementAlreadyAttested(uint256 chainId, bytes32 operationId, uint64 stateVersion);
    event SettledCreditShortfall(uint256 chainId, bytes32 operationId, uint256 amountSD, uint256 receivedSD);
    event SettledBelowMinDelivered(uint256 chainId, bytes32 operationId, uint256 minDeliveredSD, uint256 receivedSD);

    /// @dev OpenZeppelin `SafeERC20` / `Address` errors of `CcipExecutorTransferLib.payOut` (and `CcipSendLib`):
    ///      the executor no longer links `SafeERC20` itself, so they are mirrored here to keep its ABI unchanged.
    error SafeERC20FailedOperation(address token);
    error AddressEmptyCode(address target);
    error AddressInsufficientBalance(address account);
    error FailedInnerCall();
    error ActiveCommandExists(uint256 chainId, bytes32 commandId);
    error AmountHasDust(uint256 amount);
    error AttestationOutsideAnchorBand(uint256 chainId, uint256 principal, uint256 proposed, uint256 bandBps);
    error BigChangeExceeded(uint256 oldBalance, uint256 newBalance, uint256 maximumBps);
    error CancelInFlight(uint256 chainId, bytes32 commandId);
    error CancelCooldown(uint256 chainId, bytes32 commandId, uint256 nextAllowedAt);
    error CancelledRecallCapReached(uint256 chainId, uint256 maximum);
    error CancelledRecallNotExpired(uint256 chainId, uint256 refusedUntil);
    error CommandBudgetAboveLane(uint256 requested, uint256 derived);
    error CommandBudgetAboveMax(uint256 requested, uint256 maximum);
    error CommandExpired(bytes32 commandId);
    error CommandLaneGasTooLow(uint256 laneGas, uint256 requiredLaneGas);
    error CommandNotExpired(bytes32 commandId, uint256 abandonableAt);
    error CommandNotFailed(bytes32 commandId);
    error CommandSequenceMismatch(uint64 expected, uint64 received);
    error FrontierRepairBlockedByOpenTransfers(uint256 chainId, uint256 outboundInFlight);
    error MathOverflowedMulDiv();
    error MinUpdateIntervalNotMet(uint64 previous, uint256 current, uint256 minimum);
    error NoStuckCommand(uint256 chainId);
    error ObservationStale(uint256 chainId);
    error PendingTransferCapReached(uint256 chainId, uint256 maximum);
    error PendingTransfersExist(uint256 chainId, uint256 pending);
    error ProposalEpochChanged(uint256 chainId);
    error ObservationPredatesValueMovingReceipt(uint256 chainId, uint64 remoteTimestamp, uint64 receiptAt);
    error ProposalExpired(uint256 proposalId);
    error ProposalApprovalWindowTooShort(uint256 chainId, uint256 window, uint256 minWindow);
    error ProposalNotActive(uint256 proposalId);
    error ProposalVersionMismatch(uint64 expected, uint64 received);
    error RetryGasBelowCommandBudget(bytes32 commandId, uint256 laneGas, uint256 requiredLaneGas);
    error RealignStateMoved(
        uint256 chainId, uint64 expectedSequence, uint64 actualSequence, uint64 expectedEpoch, uint64 actualEpoch
    );
    error TransferStale(uint256 chainId, uint256 createdAt);
    error UnanchoredAttestation(uint256 chainId, uint256 proposed);
    error UnknownCommand(bytes32 commandId);
}
