// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IStargateExecutorLibraryAbi
/// @notice ABI declarations for the events and errors of StargateExecutorAccountingLib, StargateExecutorAttestationLib, StargateExecutorCommandLib and StargateExecutorDeploymentLib that StargateCrosschainExecutor does not declare itself.
/// @dev Declarations only. Linked libraries run under delegatecall, so their events/errors are
///      emitted/raised from the host address but only appear in the host ABI if declared here.
///      Adds no runtime bytecode. Kept complete by CrosschainLibraryAbiCompletenessTest.
/// @author IPOR Labs
interface IStargateExecutorLibraryAbi {
    event AttestationAnchorRebased(uint256 chainId, uint256 principalSD);
    event AttestationAnchorUpdated(uint256 chainId, uint256 principalSD);
    event AttestationNetPrincipalUpdated(uint256 chainId, uint256 netPrincipalSD);
    event AuthenticatedMessageDroppedAheadOfFrontier(
        uint256 srcChainId,
        uint8 msgType,
        bytes32 recordId,
        uint64 stateVersion,
        uint64 frontier
    );
    event ChainUnblockedByApproval(uint256 chainId, uint256 proposalId);
    /// @dev Mirror of `StargateExecutorAccountingLib.CommandExpiryReleased` (IL-8594).
    event CommandExpiryReleased(uint256 chainId, bytes32 commandId, uint64 sequence);
    event ProposalInvalidated(uint256 chainId, uint256 proposalId, uint64 newEpoch);
    event ReturnComposeWithoutStalenessClock(uint256 srcChainId, bytes32 requestId, uint256 amountSD);
    event ReturnComposeReserved(uint256 srcChainId, bytes32 requestId, bytes32 guid, uint256 amountSD);
    event ReturnRecordForceResolved(
        uint256 chainId,
        bytes32 requestId,
        uint8 outcome,
        uint256 inFlightRemovedSD,
        uint256 reserveToIdleSD
    );
    event ReturnCreditClamped(uint256 srcChainId, bytes32 requestId, uint256 reported, uint256 credited);
    event ReturnInFlightWithoutStalenessClock(uint256 srcChainId, bytes32 requestId, uint256 amountReceivedSD);
    event ReturnRejectedAfterValueLeg(uint256 srcChainId, bytes32 requestId, bool metadataArrived, bool composeArrived);
    event NoClockReturnBlockLifted(uint256 chainId);
    event SettledCreditClamped(uint256 srcChainId, bytes32 transferId, uint256 reported, uint256 credited);
    event LateSettlementCredited(
        uint256 srcChainId, bytes32 transferId, uint256 amountSD, uint256 credited, uint64 stateVersion
    );
    event LateSettlementAlreadyAttested(uint256 srcChainId, bytes32 transferId, uint64 stateVersion);
    event VaultsUpdateRequested(
        uint256 dstChainId,
        bytes32 commandId,
        uint64 sequence,
        uint64 newConfigEpoch,
        address[] vaults
    );

    error ActiveReturnRequestExists(uint256 chainId, bytes32 requestId);
    error ObservationTooCloseToStale(uint256 chainId, uint64 remoteTimestamp);
    error ObservationOlderThanApproved(uint256 chainId, uint64 remoteTimestamp, uint64 lastApprovedObservedAt);
    error AttestationOutsideAnchorBand(uint256 chainId, uint256 principal, uint256 proposed, uint256 bandBps);
    error BigChangeExceeded(uint256 oldValue, uint256 newValue, uint256 bps);
    error CancelInFlight(uint256 chainId, bytes32 commandId);
    error CancelCooldown(uint256 chainId, bytes32 commandId, uint256 nextAllowedAt);
    error ChainBlocked(uint256 chainId);
    error CommandBudgetAboveMax(uint256 requested, uint256 maximum);
    error CommandExpired(bytes32 commandId);
    error CommandLaneGasTooLow(uint256 laneGas, uint256 requiredLaneGas);
    error CommandLaneOptionsInvalid(uint32 eid);
    error CommandNotExpired(bytes32 commandId, uint256 abandonableAt);
    error CommandNotFailed(uint256 chainId);
    error DispatcherAddressMismatch(address expected, address got);
    error DispatcherChainsCapReached(uint256 max);
    error FactoryPathMismatch(uint256 chainId, uint32 eid);
    error ForceResolveRequiresReturnMetadata(bytes32 id);
    error ForceResolveWrongState(bytes32 id);
    error ForceSetOlderThanApproved(uint256 chainId, uint64 committedObservedAt, uint64 lastApprovedObservedAt);
    error ForceSetStateVersionMismatch(uint256 chainId, uint64 acknowledged, uint64 observed);
    error FrontierAdvanceTooLarge(uint256 chainId, uint64 current, uint256 requested, uint256 maxJump);
    error FrontierRepairBlockedByOpenTransfers(uint256 chainId, uint256 outboundInFlight);
    error GuidMismatch(bytes32 expected, bytes32 got);
    error InvalidMinimumReturn(uint256 minReturnSD, uint256 maxAccountedSD);
    error InvalidObservationMetadata(uint256 chainId);
    error InvalidOptionType(uint16 optionType);
    error InvalidVault(address vault);
    error MathOverflowedMulDiv();
    error MinUpdateIntervalNotMet(uint256 last, uint256 nowTs, uint256 interval);
    error NavSettledStale(uint256 chainId);
    error NavTransferStale(uint256 chainId);
    error NoActiveCommand(uint256 chainId);
    error NoActiveReturnRequest(uint256 chainId);
    error NoStuckCommand(uint256 chainId);
    error ObservationStale(uint256 chainId);
    error PendingTransfersExist(uint256 chainId, uint256 count);
    error ProposalApprovalWindowTooShort(uint256 chainId, uint256 window, uint256 minWindow);
    error ProposalEpochChanged(uint256 chainId);
    error ProposalExpired(uint256 proposalId);
    error ProposalNotActive(uint256 proposalId);
    error ProposalVersionMismatch(uint64 expected, uint64 got);
    error RealignStateMoved(
        uint256 chainId, uint64 expectedSequence, uint64 actualSequence, uint64 expectedEpoch, uint64 actualEpoch
    );
    error ReceiptSequenceMismatch(uint64 expected, uint64 got);
    error RescueLedgerInvariantViolation(uint256 balance, uint256 tracked);
    error ReturnNotFound(bytes32 requestId);
    error ReturnRequestNotStale(uint256 chainId, uint256 createdAt, uint256 staleAt);
    error ReturnRequestValueMoved(uint256 chainId, bytes32 requestId);
    error SourceOfFundsGuard(uint256 have, uint256 need);
    error StateVersionGap(uint256 chainId, uint64 expected, uint64 got);
    error TransferNotFound(bytes32 transferId);
    error UnanchoredAttestation(uint256 chainId, uint256 proposed);
    error UnclockedReturnOpen(uint256 chainId, uint32 count);
    error UnexpectedValueDelta(int256 valueDeltaSD);
    error VaultsCapReached(uint256 max);
    error WrongSourceChain(uint256 expected, uint256 got);
    error ZeroAccountedReturn(uint256 chainId);
}
