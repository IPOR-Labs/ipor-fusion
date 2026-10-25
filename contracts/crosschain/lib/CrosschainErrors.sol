// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title CrosschainErrors
/// @notice Centralized custom errors for the crosschain core contracts (rescue module, transport
///         bases, factory, executor and dispatcher).
/// @dev Flat library of `error` declarations mirroring the repo convention in
///      `contracts/fuses/rwa/errors/RWAErrors.sol`: terse names, diagnostic parameters, one place
///      shared by the Stargate contracts, the shared libraries and part of the CCIP code (the CCIP contracts
///      declare most of their errors locally, some with the same signature). All errors carry the
///      parameters an off-chain monitor needs to reconstruct the failing condition.
/// @author IPOR Labs
library CrosschainErrors {
    error InvalidRescueDelay(uint256 supplied, uint256 minimum);
    /// @dev Factory configuration timelock below `CrosschainConstants.MIN_CONFIG_DELAY` (IL-8538).
    error InvalidConfigDelay(uint256 supplied, uint256 minimum);
    error NoActiveReturnRequest(uint256 chainId);
    error ReturnRequestNotStale(uint256 chainId, uint256 createdAt, uint256 staleAt);

    /// @notice Thrown when the permissionless stale-recall escape is applied to a recall that has already
    ///         moved value between accounting buckets (authenticated metadata and/or the delivery compose
    ///         arrived). Such a record's staleness slot is the ONLY clock on the value it booked, so
    ///         releasing it permissionlessly would turn the fail-closed NAV gate into a fail-open one.
    ///         The terminal exit for this state is the timelocked rescue (`forceResolveTransfer`), which
    ///         also removes the value from the NAV buckets.
    /// @param chainId The chain the recall targets.
    /// @param requestId The recall request id.
    error ReturnRequestValueMoved(uint256 chainId, bytes32 requestId);
    error InsufficientGasForNack(uint256 available, uint256 required);
    // ============================================================
    // Generic
    // ============================================================

    /// @notice Thrown when a zero address is supplied where a non-zero address is required.
    error ZeroAddress();

    /// @notice Thrown when two addresses that must differ are equal (e.g. admin == guardian).
    error SameAddress();

    // ============================================================
    // Native fee budget (transport bases pay from their own balance, §4.3)
    // ============================================================

    /// @notice Thrown when the contract's native balance cannot cover a LayerZero/Stargate fee.
    /// @param have The current native balance available to the contract.
    /// @param need The native fee quoted for the pending send.
    error InsufficientNativeBudget(uint256 have, uint256 need);

    /// @notice The LayerZero native fee quoted for a send exceeds the factory's per-destination ceiling.
    /// @param fee The native fee quoted for the pending send.
    /// @param maxNativeFee The ceiling read from the factory for the destination chain.
    error NativeFeeTooHigh(uint256 fee, uint256 maxNativeFee);

    // ============================================================
    // Configuration
    // ============================================================

    /// @notice Thrown by config entry points that are permanently disabled (frozen path/asset, §4.2).
    /// @dev Not thrown by any contract: frozen config reverts `AssetConfigFrozen` / `PathConfigFrozen`.
    error ConfigDisabled();

    /// @notice Thrown by the disabled owner-path OApp config wrappers (`setPeer` / `setEnforcedOptions` /
    ///         `setDelegate`) on every Stargate host.
    /// @dev All path/enforced-option config must flow through the authorized `_registerPath` route
    ///      (constraint §4.1). The public owner setters are neutralized to remove a divergent path, and the
    ///      endpoint delegate cleared at construction can never be re-appointed (IL-8557 / IL-8558).
    error ConfigViaAuthorizedPathOnly();

    // ============================================================
    // Transport authentication (§4.4)
    // ============================================================

    /// @notice Thrown when `lzCompose` is called by an address other than the endpoint (`lzReceive` is guarded
    ///         by the vendored `OAppReceiver` instead).
    /// @param caller The unexpected caller.
    error UnauthorizedEndpoint(address caller);

    /// @notice Thrown when an `lzCompose` message does not originate from the configured Stargate pool.
    /// @param from The `_from` address reported by the endpoint's compose wrapper.
    error UnauthorizedStargatePool(address from);

    /// @notice Thrown when the OFT compose codec's `composeFrom` is not this contract's own address.
    /// @param composeFrom The decoded `composeFrom` value (should equal `bytes32(address(this))`).
    error UnauthorizedComposeFrom(bytes32 composeFrom);

    /// @notice Thrown when an inbound message maps to a source chain that is not registered/expected.
    /// @dev Not thrown by any contract: on Stargate an unregistered source fails the vendored peer check (`NoPeer`)
    ///      or reverts `UnknownEid`, an unexpected registered one `WrongSourceChain`; CCIP has its own errors.
    /// @param chainId The source chain id that failed authorization.
    error UnauthorizedSourceChain(uint256 chainId);

    /// @notice Thrown when a LayerZero peer does not match the expected same-address peer for the EID.
    /// @dev Not thrown by any contract: the peer check is the vendored `OAppReceiver`'s own (`OnlyPeer`); CCIP
    ///      uses `CcipUnauthorizedPeer`.
    /// @param eid The source endpoint id.
    /// @param sender The peer (sender) reported by the endpoint origin.
    error UnauthorizedPeer(uint32 eid, bytes32 sender);

    // ============================================================
    // Chain registration table (chainId <-> EID bijection, §4.1)
    // ============================================================

    /// @notice Thrown when a chain registration is malformed (zero chainId/EID, or the local chain).
    /// @param chainId The chain id supplied to `_registerPath`.
    /// @param eid The endpoint id supplied to `_registerPath`.
    error InvalidChainRegistration(uint256 chainId, uint32 eid);

    /// @notice Thrown when either direction of the chainId<->EID bijection is already occupied.
    /// @param chainId The chain id supplied to `_registerPath`.
    /// @param eid The endpoint id supplied to `_registerPath`.
    error ChainAlreadyRegistered(uint256 chainId, uint32 eid);

    /// @notice Thrown when an enforced-options entry targets a different EID than the path being registered.
    /// @param expectedEid The EID of the path being registered.
    /// @param gotEid The EID found on the enforced-options entry.
    error EnforcedOptionsPathMismatch(uint32 expectedEid, uint32 gotEid);

    /// @notice Thrown by the Stargate executor's chain registration when the options of the last
    ///         supplied `MSG_OPTION_TYPE` entry (the one that would actually be stored) are not exactly
    ///         one executor `lzReceive` option with gas in the command-lane bounds and no value — or
    ///         when no such entry is supplied at all (IL-8296).
    /// @param eid The endpoint id of the path being registered.
    error CommandLaneOptionsInvalid(uint32 eid);

    /// @notice Thrown when a chain id has no registered endpoint id.
    /// @param chainId The unknown chain id.
    error UnknownChain(uint256 chainId);

    /// @notice Thrown when an endpoint id has no registered chain id.
    /// @param eid The unknown endpoint id.
    error UnknownEid(uint32 eid);

    // ============================================================
    // Stargate value-channel wiring (§4.5)
    // ============================================================

    /// @notice Thrown when the configured Stargate pool's `token()` does not equal the local ASSET.
    /// @param expectedAsset The local ASSET the executor/dispatcher is bound to (on the factory's asset config
    ///        check: the configured token).
    /// @param poolToken The token reported by the Stargate pool.
    error StargatePoolAssetMismatch(address expectedAsset, address poolToken);

    /// @notice Thrown when local decimals are smaller than shared decimals (violates the OFT invariant).
    /// @param localDecimals The ASSET's local decimals.
    /// @param sharedDecimals The Stargate pool's shared decimals.
    error InvalidDecimals(uint8 localDecimals, uint8 sharedDecimals);

    // ============================================================
    // Rescue module (timelocked generic rescue + guardian veto, §4.3)
    // ============================================================

    /// @notice Thrown when a rescue-admin-only function is called by another address.
    /// @param caller The unauthorized caller.
    error UnauthorizedRescueAdmin(address caller);

    /// @notice Thrown when a rescue-guardian-only function is called by another address.
    /// @param caller The unauthorized caller.
    error UnauthorizedRescueGuardian(address caller);

    /// @notice Thrown when a cancel is attempted by an address that is neither admin nor guardian.
    /// @param caller The unauthorized caller.
    error UnauthorizedRescueCanceller(address caller);

    /// @notice Thrown when scheduling would exceed `CrosschainConstants.MAX_PENDING_RESCUES`.
    /// @param max The pending-rescue cap.
    error RescueQueueFull(uint256 max);

    /// @notice Thrown when a rescue id is not in the `SCHEDULED` state (never scheduled or cancelled).
    /// @param rescueId The rescue id referenced.
    error RescueNotScheduled(uint256 rescueId);

    /// @notice Thrown when a rescue id has already been executed/consumed.
    /// @param rescueId The rescue id referenced.
    error RescueAlreadyConsumed(uint256 rescueId);

    /// @notice Thrown when a rescue's timelock has not elapsed.
    /// @param rescueId The rescue id referenced.
    /// @param nowTs The current block timestamp.
    /// @param executableAt The earliest timestamp the rescue may execute.
    error RescueTimelockNotElapsed(uint256 rescueId, uint256 nowTs, uint256 executableAt);

    /// @notice Thrown when a rescue's veto epoch no longer matches the current guardian veto epoch.
    /// @param rescueId The rescue id referenced.
    error RescueVetoed(uint256 rescueId);

    /// @notice Thrown when a rescue kind does not match the operation (generic vs force-resolve).
    /// @param rescueId The rescue id referenced.
    error RescueWrongKind(uint256 rescueId);

    /// @notice Thrown when the calldata supplied to `executeRescue` does not hash to the commitment.
    /// @param rescueId The rescue id referenced.
    error RescueCalldataMismatch(uint256 rescueId);

    /// @notice Thrown when the commitment supplied to a force-resolve consume does not match.
    /// @param rescueId The rescue id referenced.
    error ForceResolveCommitmentMismatch(uint256 rescueId);

    /// @notice Thrown when a rescue's external call fails and carries no revert data to bubble; also by the
    ///         Stargate factory's `sweepNative` when the native transfer fails.
    error RescueCallFailed();

    /// @notice Thrown when a rescue would breach the tracked-ledger invariant (rescue may take
    ///         untracked surplus only, §4.3). Raised by the Stargate executor's and dispatcher's
    ///         `_afterRescueExecuted` hooks (bodies in `StargateExecutorAccountingLib` / `StargateDispatcherLib`).
    /// @param balance The post-call ASSET balance of the host (executor or dispatcher).
    /// @param tracked min(pre-rescue ASSET balance, tracked ledger in LD).
    error RescueLedgerInvariantViolation(uint256 balance, uint256 tracked);

    /// @notice Thrown when a rescue targeting the tracked asset is not a plain
    ///         `transfer(address,uint256)`. Any other shape (approve, permit, operator grants) could
    ///         hand out spending rights over tracked value while leaving the post-call balance
    ///         snapshot checked by `_afterRescueExecuted` untouched.
    /// @param token The protected (tracked) asset that was targeted.
    /// @param selector The rejected calldata selector.
    error RescueProtectedTokenCall(address token, bytes4 selector);

    /// @notice Thrown when a generic rescue targets the factory that deployed the caller. The factory
    ///         authenticates executors by `msg.sender`, so a rescue call could open a dispatcher ticket
    ///         the executor has no record of and brick that (executor, chain) pair (IL-8261).
    /// @param factory The caller's factory.
    error RescueFactoryCall(address factory);

    /// @notice Thrown when a generic rescue of the Stargate factory targets one of its own executors (any
    ///         selector, any value), at schedule or at execute time. The executor trusts the factory by bare
    ///         `msg.sender`, so such a call would forge `onDispatcherCreated` / `...RequestFailed` (IL-8763).
    /// @param executor The executor that was targeted.
    error RescueExecutorCall(address executor);

    /// @notice Thrown when a generic rescue carries the ContextManager `runWithContext` selector. The call
    ///         would make the host the context sender and so bypass the vault and share fences (IL-8770).
    /// @param target The targeted contract.
    error RescueContextCall(address target);

    /// @notice Thrown when a generic rescue targets the caller's transport: any call to the CCIP router or
    ///         to the Stargate pool (`STARGATE_POOL()`), or any call to the LayerZero endpoint other than inbound packet hygiene (`skip`, `clear`,
    ///         `nilify`, `burn`). The transport authenticates the host by bare `msg.sender`, so a rescue
    ///         `send` / `ccipSend` / `sendToken` would forge a peer-authenticated message on the other chain (IL-8555).
    /// @param target The transport contract that was targeted.
    /// @param selector The rejected calldata selector.
    error RescueTransportCall(address target, bytes4 selector);

    /// @notice Thrown when a generic rescue targets one of the dispatcher's tracked or allowlisted
    ///         vaults, at schedule or at execute time. Share-token approvals or redemptions would drain NAV outside the
    ///         ASSET floor (IL-8556).
    /// @param vault The tracked or allowlisted vault that was targeted.
    error RescueTrackedVaultCall(address vault);

    /// @notice Thrown when the host's tracked vault set exceeds the protocol cap while a rescue reads it.
    /// @param len The reported length.
    /// @param max The cap (`MAX_TRACKED_POSITION_VAULTS`).
    error RescueTrackedSetTooLarge(uint256 len, uint256 max);

    /// @notice Thrown when a rescue fence cannot read a getter from the host.
    /// @param selector The selector of the failed host read.
    error RescueHostReadFailed(bytes4 selector);

    /// @notice Thrown when a rescue call left a tracked vault's share balance of the caller lower than
    ///         before the call (IL-8556).
    /// @param vault The tracked vault whose shares decreased.
    /// @param before The caller's share balance before the call.
    /// @param after_ The caller's share balance after the call.
    error RescueTrackedSharesReduced(address vault, uint256 before, uint256 after_);

    // ============================================================
    // Executor / Dispatcher — access control (§9/§10)
    // ============================================================

    /// @notice Thrown when a self-only helper (business self-call) is not called by `address(this)`.
    /// @param caller The unexpected caller.
    error OnlySelf(address caller);

    /// @notice Thrown when a manager-only function is called by an address other than `MANAGER`.
    /// @param caller The unexpected caller.
    error UnauthorizedManager(address caller);

    /// @notice Thrown when a factory-only callback is called by an address other than `FACTORY`.
    /// @param caller The unexpected caller.
    error UnauthorizedFactory(address caller);

    /// @notice Thrown when the balance proposer address equals the approver (must differ, §9 Q5).
    error ProposerEqualsApprover();

    /// @notice Thrown when `BIG_CHANGE_BPS` is zero or exceeds `ATTESTATION_ANCHOR_BAND_BPS` at
    ///         construction (§8 P3 item 5, IL-8049).
    /// @param bps The invalid basis-points value.
    error InvalidBigChangeBps(uint256 bps);

    /// @notice Thrown when a timing parameter is zero, above `MAX_STALENESS_WINDOW`, or when
    ///         `STALENESS_MAX < MIN_PROPOSAL_APPROVAL_WINDOW` or `MIN_UPDATE_INTERVAL >= STALENESS_MAX` at
    ///         construction (§8 P3, IL-8049).
    error InvalidTimingParameter();

    /// @notice Thrown when a `deploymentTtl` is outside `[MIN_DEPLOYMENT_TTL, MAX_DEPLOYMENT_TTL]`: at
    ///         `StargateCrosschainExecutor` construction (IL-8049) and, for the lower bound, when
    ///         `StargateCrosschainFactory.requestDispatcher` reads it (IL-8069).
    /// @param supplied The invalid `deploymentTtl` value.
    /// @param minimum `CrosschainConstants.MIN_DEPLOYMENT_TTL`.
    /// @param maximum `CrosschainConstants.MAX_DEPLOYMENT_TTL`.
    error InvalidDeploymentTtl(uint256 supplied, uint256 minimum, uint256 maximum);

    /// @notice Thrown when `proposeBalance` is called by an address other than `BALANCE_PROPOSER`.
    /// @param caller The unexpected caller.
    error UnauthorizedProposer(address caller);

    /// @notice Thrown when an approval/reject is called by an address other than `BALANCE_APPROVER`.
    /// @param caller The unexpected caller.
    error UnauthorizedApprover(address caller);

    // ============================================================
    // Executor — dispatcher lifecycle & caps (§9)
    // ============================================================

    /// @notice Thrown when an action requires a ready dispatcher on a chain that has none.
    /// @param chainId The chain lacking a ready dispatcher.
    error DispatcherNotReady(uint256 chainId);

    /// @notice Thrown when creating a dispatcher on a chain that already has one.
    /// @param chainId The chain that already has a dispatcher.
    error DispatcherAlreadyExists(uint256 chainId);

    /// @notice Thrown when a dispatcher deployment request is already pending for a chain.
    /// @param chainId The chain with a pending request.
    error DispatcherRequestPending(uint256 chainId);

    /// @notice Thrown when a deployment ACK reports a dispatcher address other than the requesting executor's
    ///         (checked by the source factory and again by the executor's `onDispatcherCreated`).
    /// @param expected The expected same-address value (the executor's own address).
    /// @param got The dispatcher address reported by the ACK.
    error DispatcherAddressMismatch(address expected, address got);

    /// @notice Thrown when a deployment request id is unknown or in the wrong state.
    /// @param requestId The referenced request id.
    error DeploymentRequestInvalid(uint256 requestId);

    /// @notice Thrown when registering more chains than `MAX_DISPATCHER_CHAINS`.
    /// @param max The chain cap.
    error DispatcherChainsCapReached(uint256 max);

    /// @notice Thrown when the executor's on-chain factory equality check fails during `registerChain`.
    /// @param chainId The chain id being registered.
    /// @param eid The endpoint id being registered.
    error FactoryPathMismatch(uint256 chainId, uint32 eid);

    // ============================================================
    // Executor — command slot & transfers (§9)
    // ============================================================

    /// @notice Thrown when a business command or UPDATE_VAULTS is sent, or `REALIGN_COMMAND_LANE` executes,
    ///         while a command occupies the chain's slot.
    /// @param chainId The chain with an active command.
    error ActiveCommandExists(uint256 chainId);

    /// @notice Thrown when `REALIGN_COMMAND_LANE` executes after the lane mirrors moved from the pair it was
    ///         scheduled against (IL-8652): an authenticated ACK during the delay advanced them.
    /// @param chainId The chain whose lane was to be realigned.
    /// @param expectedSequence The `nextSequenceToSend` the rescue was armed against.
    /// @param actualSequence The live `nextSequenceToSend`.
    /// @param expectedEpoch The `chainConfigEpoch` the rescue was armed against.
    /// @param actualEpoch The live `chainConfigEpoch`.
    error RealignStateMoved(
        uint256 chainId,
        uint64 expectedSequence,
        uint64 actualSequence,
        uint64 expectedEpoch,
        uint64 actualEpoch
    );

    /// @notice Thrown when retry/cancel targets a chain with no active command.
    /// @param chainId The chain referenced.
    error NoActiveCommand(uint256 chainId);

    /// @notice Thrown when retry/cancel targets a command that is not in the FAILED state.
    /// @param chainId The chain referenced.
    error CommandNotFailed(uint256 chainId);

    /// @notice Thrown when a retry is requested for a command whose CANCEL is still in flight.
    /// @dev A cancel is terminal: the dispatcher resolves the command as CANCELLED and drops the later
    ///      retry, so allowing both to race can only misreport the outcome to the executor.
    /// @param chainId The chain referenced.
    /// @param commandId The command whose cancel is outstanding.
    error CancelInFlight(uint256 chainId, bytes32 commandId);

    /// @notice The previous `CANCEL_COMMAND` for this command is younger than `CANCEL_COMMAND_COOLDOWN` (IL-8579).
    /// @param chainId The chain referenced.
    /// @param commandId The command whose cancel was sent recently.
    /// @param nextAllowedAt Earliest timestamp at which the cancel may be re-sent.
    error CancelCooldown(uint256 chainId, bytes32 commandId, uint256 nextAllowedAt);

    /// @notice Thrown when the `ABANDON_COMMAND_*` rescue targets a chain whose command slot is free.
    /// @dev The rescue is the terminal exit for a command whose receipt can never arrive; there is
    ///      nothing to abandon when no command occupies the slot.
    /// @param chainId The chain referenced.
    error NoStuckCommand(uint256 chainId);

    /// @notice Thrown when an attestation would move the settled balance off zero while the chain has no
    ///         accounting anchor (`anchorPrincipal == 0`).
    /// @dev The big-change limiter is relative, so a zero baseline bounds nothing. With no anchor, leaving zero
    ///      requires either an authenticated settlement or the timelocked `forceSetSettled` rescue — never the
    ///      proposer/approver pair on its own. A residual anchor kept by a full recall (IL-8606) instead bounds
    ///      the attestation by the anchor band (`AttestationOutsideAnchorBand`).
    /// @param chainId The chain referenced.
    /// @param proposed The balance the approval tried to write.
    error UnanchoredAttestation(uint256 chainId, uint256 proposed);

    /// @notice Thrown when an approved attestation would move `settledSD` outside `ATTESTATION_ANCHOR_BAND_BPS`
    ///         of the per-chain accounting anchor (`anchorPrincipal`) — Stargate transport (audit
    ///         `no_cumulative_bound_on_attested_balance_ratchet`, IL-7967).
    /// @param chainId The chain referenced.
    /// @param principal The accounting anchor the proposed value was compared against.
    /// @param proposed The balance the approval tried to write.
    /// @param bandBps The band, in bps of `principal`.
    error AttestationOutsideAnchorBand(uint256 chainId, uint256 principal, uint256 proposed, uint256 bandBps);

    /// @notice Thrown when a per-chain pending-transfer slot cap is reached before growth.
    /// @param chainId The chain referenced.
    /// @param max The per-chain pending-transfer cap.
    error PendingTransfersCapReached(uint256 chainId, uint256 max);

    /// @notice Thrown when the source-of-funds guard fails (would consume ledger-backed tokens, §9).
    /// @param have The current ASSET balance.
    /// @param need The minimum balance required (idle + pending arrival + amount, local decimals).
    error SourceOfFundsGuard(uint256 have, uint256 need);

    /// @notice Thrown when a zero amount is supplied where a positive amount is required.
    error ZeroAmount();

    /// @notice Thrown when a local amount is not a whole multiple of one shared-decimal unit (it carries
    ///         sub-precision dust, or converts to zero shared decimals). Such an amount must never create a
    ///         permanent zero-value or dust-losing transfer/recall record (§9 P2).
    /// @param amountLD The offending amount in local ASSET decimals.
    error AmountBelowSharedDecimals(uint256 amountLD);

    /// @notice Thrown when an inbound message comes from a chain other than the one bound to it: the record's
    ///         chain on the executor, `EXECUTOR_CHAIN_ID` on the dispatcher.
    /// @param expected The chain bound to the record (executor) or `EXECUTOR_CHAIN_ID` (dispatcher).
    /// @param got The source chain of the inbound message.
    error WrongSourceChain(uint256 expected, uint256 got);

    /// @notice Thrown when an inbound transfer settlement references an unknown/foreign transfer id, or a
    ///         force-resolve names an id with no open outbound or return record.
    /// @param transferId The referenced transfer id.
    error TransferNotFound(bytes32 transferId);

    /// @notice Thrown when a settlement/return guid does not match the bound guid.
    /// @param expected The stored guid.
    /// @param got The inbound guid.
    error GuidMismatch(bytes32 expected, bytes32 got);

    /// @notice Thrown when an inbound return-asset message references an unknown request id.
    /// @param requestId The referenced request id.
    error ReturnNotFound(bytes32 requestId);

    /// @notice Thrown when a chain already has a non-terminal recall request.
    error ActiveReturnRequestExists(uint256 chainId, bytes32 requestId);

    /// @notice Thrown when a recall's absolute floor exceeds the accounted upper bound at request time,
    ///         so the request could never be satisfied even before remote idle is taken into account.
    /// @param minReturnSD The requested floor, shared decimals.
    /// @param maxAccountedSD The accounted upper bound, shared decimals.
    error InvalidMinimumReturn(uint256 minReturnSD, uint256 maxAccountedSD);

    /// @notice Thrown when force-set is attempted while unresolved value-moving records exist.
    error PendingTransfersExist(uint256 chainId, uint256 count);

    // ============================================================
    // Executor — version frontier & attestation (§9)
    // ============================================================

    /// @notice Thrown when a value-moving response's remote state version is ahead of the contiguous frontier,
    ///         or when a Stargate `ADVANCE_STATE_FRONTIER` would not move the frontier forward.
    /// @param chainId The chain referenced.
    /// @param expected The next expected version (`acknowledged + 1`).
    /// @param got The version reported by the response (or the requested new frontier).
    error StateVersionGap(uint256 chainId, uint64 expected, uint64 got);

    /// @notice Thrown when a frontier repair would skip more than `MAX_FRONTIER_JUMP` remote versions.
    /// @dev The write is irreversible and every skipped version's message is silently dropped, so a
    ///      mis-scaled or fat-fingered target must fail rather than brick the lane. Repeat the rescue if
    ///      the gap is genuinely larger.
    /// @param chainId The chain referenced.
    /// @param current The current acknowledged frontier.
    /// @param requested The requested new frontier.
    /// @param maxJump The maximum number of versions one repair may skip.
    error FrontierAdvanceTooLarge(uint256 chainId, uint64 current, uint256 requested, uint256 maxJump);

    /// @notice Thrown when a balance proposal id is unknown or no longer the active proposal.
    /// @param proposalId The referenced proposal id.
    error ProposalNotActive(uint256 proposalId);

    /// @notice Thrown when approving an expired proposal, or when proposing one whose `expiry` is not in the
    ///         future; then `proposalId` is 0. A future `expiry` that leaves too little time reverts
    ///         `ProposalApprovalWindowTooShort` instead.
    /// @param proposalId The referenced proposal id.
    error ProposalExpired(uint256 proposalId);

    /// @notice Thrown by both transports (Stargate and CCIP executors) when a proposal's `expiry` does not leave
    ///         a minimum meaningful approval window (`MIN_PROPOSAL_APPROVAL_WINDOW`) for the approver to act. A
    ///         near-immediate expiry (e.g.
    ///         `block.timestamp + 1`) would let a proposer emit proposals that are practically impossible
    ///         to approve within a normal multisig/keeper cycle (audit V2-02).
    /// @param chainId The chain referenced.
    /// @param window The approval window the observation actually left (`expiry - block.timestamp`, seconds).
    /// @param minWindow The required minimum approval window (seconds).
    error ProposalApprovalWindowTooShort(uint256 chainId, uint256 window, uint256 minWindow);

    /// @notice Thrown when the local accounting epoch changed since the proposal was recorded.
    /// @param chainId The chain referenced.
    error ProposalEpochChanged(uint256 chainId);

    /// @notice Thrown when the proposal's remote state version no longer matches the frontier.
    /// @param expected The expected version (the acknowledged frontier).
    /// @param got The proposal's version.
    error ProposalVersionMismatch(uint64 expected, uint64 got);

    /// @notice Thrown when a settled-balance force-set was observed at a dispatcher state version other than
    ///         the acknowledged frontier, so it may count a remote debit this side has not applied yet (IL-8264).
    /// @param chainId The chain referenced.
    /// @param acknowledged The acknowledged remote state version.
    /// @param observed The state version the force-set declares.
    error ForceSetStateVersionMismatch(uint256 chainId, uint64 acknowledged, uint64 observed);

    /// @notice Thrown when a settled-balance force-set that did not opt out (`allowOlderThanApproved_ == false`)
    ///         commits an observation time older than the chain's `lastApprovedObservedAt`: an ordinary approval
    ///         with a newer read landed during the rescue delay, and executing the force-set would roll the NAV
    ///         freshness clock backwards (IL-8648 R1).
    /// @param chainId The chain referenced.
    /// @param committedObservedAt The remote observation time committed in the force-set.
    /// @param lastApprovedObservedAt The chain's last approved observation time.
    error ForceSetOlderThanApproved(uint256 chainId, uint64 committedObservedAt, uint64 lastApprovedObservedAt);

    /// @notice Thrown when a command ACK/NACK receipt's sequence does not match the active command's
    ///         sequence (a matching command id with a different sequence is impossible/forged, §9 P2).
    /// @param expected The active command's sequence.
    /// @param got The receipt's sequence.
    error ReceiptSequenceMismatch(uint64 expected, uint64 got);

    /// @notice Thrown when a command ACK reports a nonzero settled `valueDeltaSD`. All POC business/config
    ///         commands must report zero; a nonzero delta is never trusted from an arbitrary field (§9 P2).
    /// @param valueDeltaSD The unexpected reported delta.
    error UnexpectedValueDelta(int256 valueDeltaSD);

    /// @notice Thrown when a command is re-delivered under an existing command id with a different message
    ///         type, sequence or payload commitment — a command id binds one byte-identical operation (§9 P2).
    /// @param commandId The referenced command id.
    error CommandCommitmentMismatch(bytes32 commandId);

    /// @notice Thrown when a proposal's absolute delta exceeds `BIG_CHANGE_BPS` (use reject-and-block).
    /// @param oldValue The current settled balance (shared decimals).
    /// @param newValue The proposed settled balance (shared decimals).
    /// @param bps The big-change threshold in basis points.
    error BigChangeExceeded(uint256 oldValue, uint256 newValue, uint256 bps);

    /// @notice Thrown when approving before `MIN_UPDATE_INTERVAL` elapsed since the last approval.
    /// @param last The last approval timestamp.
    /// @param nowTs The current timestamp.
    /// @param interval The minimum interval (seconds).
    error MinUpdateIntervalNotMet(uint256 last, uint256 nowTs, uint256 interval);

    /// @notice Thrown when an observation is older than `STALENESS_MAX`: at propose, at approve, and when a
    ///         force-set is scheduled (which also rejects a zero or future observation time, IL-8646).
    ///         The CCIP executor's same-signature error is also its `getBalance()` gate for a stale settled bucket.
    /// @param chainId The chain referenced.
    error ObservationStale(uint256 chainId);

    /// @notice Thrown when a proposed observation carries invalid metadata: a zero `remoteBlock`, a zero
    ///         `remoteTimestamp`, or a `remoteTimestamp` in the future (§9 P1).
    /// @param chainId The chain referenced.
    error InvalidObservationMetadata(uint256 chainId);

    // ============================================================
    // Executor — NAV fail-closed gates (§9)
    // ============================================================

    /// @notice Thrown by `getBalance()` and `getBalanceUnchecked()` when a blocked chain (rejected proposal or
    ///         another fail-closed path, §9) still tracks value, or (Stargate) while a return record without a
    ///         staleness slot is open on it (IL-8618); also by `requestAssetsFromDispatcher` on a blocked chain.
    /// @param chainId The blocked chain.
    error ChainBlocked(uint256 chainId);

    /// @notice Thrown by `getBalance()` when a nonzero settled bucket has no fresh approved observation.
    /// @param chainId The stale chain.
    error NavSettledStale(uint256 chainId);

    /// @notice Thrown by `getBalance()` when an in-flight record, or the clock of a cancelled but unresolved
    ///         recall (IL-8621), is older than `TRANSFER_STALENESS_MAX`.
    /// @param chainId The stale chain.
    error NavTransferStale(uint256 chainId);

    /// @notice Thrown when a force-resolve outcome does not match the target record's bucket/state.
    /// @param id The transfer/return id referenced.
    error ForceResolveWrongState(bytes32 id);

    /// @notice Thrown when a return compose arrived before its authenticated RETURN_STARTED metadata
    ///         and force resolution therefore cannot know the remote amount debited from settled NAV.
    /// @param id The return request id.
    error ForceResolveRequiresReturnMetadata(bytes32 id);

    // ============================================================
    // Dispatcher — sequencing & business actions (§10)
    // ============================================================

    /// @notice Thrown when a command's stamped deadline has passed: by both executors when the manager retries
    ///         an expired FAILED command (IL-8625; the manager's CANCEL is the exit), and inside both dispatchers'
    ///         business self-calls (IL-8255). Since IL-8625 a dispatcher checks the deadline before the budget
    ///         check and records FAILED + NACK without entering the self-call, so there the check is defence in
    ///         depth; either way the command is NACKed and the sequence does not move.
    /// @param commandId The expired command (its high 64 bits are the deadline).
    error CommandExpired(bytes32 commandId);

    /// @notice Thrown when an `ABANDON_COMMAND_*` rescue executes before the command has expired on both
    ///         chains — until then a packet retained by the transport could still run it (IL-8255).
    /// @param commandId The command occupying the slot.
    /// @param abandonableAt The first timestamp strictly after which the abandon is accepted.
    error CommandNotExpired(bytes32 commandId, uint256 abandonableAt);

    /// @notice Thrown when a fresh sequenced command's sequence is not `nextCommandSequence`: ahead of it, LZ
    ///         retains the packet until its predecessors land; behind it, a stale retained packet that can never run.
    /// @param expected The dispatcher's `nextCommandSequence`.
    /// @param got The command's sequence.
    error SequenceGap(uint64 expected, uint64 got);

    /// @notice Thrown when a Stargate executor, dispatcher or factory receives a message type it does not handle
    ///         on that inbound path; the dispatcher also uses it for an unknown business action byte.
    /// @param msgType The unexpected message type (or business action byte).
    error UnexpectedMessageType(uint8 msgType);

    /// @notice Thrown when an UPDATE_VAULTS carries a config epoch other than `commandConfigEpoch + 1`, or a
    ///         business COMMAND one other than the current `commandConfigEpoch` (inside the self-call, so a NACK).
    /// @param expected The expected epoch.
    /// @param got The message epoch.
    error ConfigEpochMismatch(uint64 expected, uint64 got);

    /// @notice Thrown when a bounded vault collection would exceed its cap.
    /// @param max The cap that would be exceeded.
    error VaultsCapReached(uint256 max);

    /// @notice Thrown when a vault fails validation: zero or duplicate in the Stargate executor's shape check; on
    ///         the destination, zero (CCIP), no code or a different `asset()`.
    /// @param vault The offending vault.
    error InvalidVault(address vault);

    /// @notice Thrown when a deposit targets a vault absent from the deposit allowlist.
    /// @param vault The vault referenced.
    error VaultNotAllowed(address vault);

    /// @notice Thrown when a redeem/request targets a vault absent from the tracked-position set.
    /// @param vault The vault referenced.
    error VaultNotTracked(address vault);

    /// @notice Thrown when received shares are below the command's minimum.
    /// @param got The measured shares delta.
    /// @param min The minimum required.
    error InsufficientShares(uint256 got, uint256 min);

    /// @notice Thrown when received assets are below the command's minimum.
    /// @param got The measured assets delta.
    /// @param min The minimum required.
    error InsufficientAssets(uint256 got, uint256 min);

    /// @notice Thrown when the command's WithdrawManager is not the one the vault itself is configured
    ///         with. The vault is the authority: the dispatcher reads the vault's own manager slot through
    ///         `UniversalReader.read` and compares (IL-8117). Before that ticket the check ran the other
    ///         way round — it asked the SUPPLIED manager which vault it served, which any contract can
    ///         claim.
    /// @param withdrawManager The WithdrawManager the command named.
    /// @param plasmaVault The plasma vault whose configured manager it failed to match.
    error WithdrawManagerMismatch(address withdrawManager, address plasmaVault);

    /// @notice Thrown when a redeem-from-request receiver is not the dispatcher itself.
    /// @param receiver The offending receiver.
    error ReceiverMustBeSelf(address receiver);

    /// @notice Thrown by both dispatchers (the CCIP dispatcher since IL-9047) when a REQUEST_SHARES command asks
    ///         for more shares than the dispatcher holds in the vault (the dispatcher keeps no copy of the
    ///         request; the WithdrawManager bounds REDEEM_FROM_REQUEST).
    /// @param have The dispatcher's share balance in the vault.
    /// @param want The requested shares.
    error RequestSharesUnavailable(uint256 have, uint256 want);

    /// @notice Thrown when a REQUEST_SHARES call made the remote WithdrawManager take more shares out of the
    ///         dispatcher than the command's `maxFeeShares` ceiling (IL-8603).
    /// @param plasmaVault The vault whose shares were deducted.
    /// @param deducted The measured drop of the dispatcher's share balance.
    /// @param shares The requested shares.
    /// @param maxFeeShares The ceiling carried by the command.
    error RequestSharesFeeExceeded(address plasmaVault, uint256 deducted, uint256 shares, uint256 maxFeeShares);

    /// @notice Thrown when a recall-lane return would send zero (no tracked idle to return).
    /// @dev Not thrown by any contract: such a recall is answered with `RETURN_REJECTED(NO_TRACKED_IDLE)`.
    /// @param requestId The return request id.
    error ZeroReturnAmount(bytes32 requestId);

    /// @notice Thrown when a recall-lane command references an unknown/foreign command id.
    /// @param commandId The referenced command id.
    error CommandNotFound(bytes32 commandId);

    // ============================================================
    // Factory — executor registry & deployment requests (§4.2)
    // ============================================================

    /// @notice Thrown when `requestDispatcher` is called by an address that is not a registered executor.
    /// @param caller The unexpected caller.
    error NotRegisteredExecutor(address caller);

    /// @notice Thrown when the request's `executor` field does not equal `msg.sender`.
    /// @param caller The calling executor.
    /// @param requestExecutor The `executor` bound in the request.
    error ExecutorRequestMismatch(address caller, address requestExecutor);

    /// @notice Thrown when an asset id is not enabled on the local factory.
    /// @param assetId The chain-independent asset identity.
    error AssetConfigNotEnabled(bytes32 assetId);

    /// @notice Thrown when the request/ticket immutable-parameters hash does not match its raw fields.
    /// @param expected The hash reconstructed from the raw fields.
    /// @param got The hash carried in the request/ticket.
    error ImmutableParamsHashMismatch(bytes32 expected, bytes32 got);

    // ============================================================
    // Factory — inbound ticket validation (destination, §4.2/§3.3)
    // ============================================================

    /// @notice Thrown when a ticket's `dstChainId` does not equal the destination factory's `block.chainid`.
    /// @param expected The ticket's `dstChainId`.
    /// @param got The processing chain (`block.chainid`).
    error TicketWrongDestinationChain(uint256 expected, uint256 got);

    /// @notice Thrown when a ticket's `srcChainId` does not equal the delivery source chain (mapped EID).
    /// @param expected The ticket's `srcChainId`.
    /// @param got The mapped source chain of the inbound message.
    error TicketSourceChainMismatch(uint256 expected, uint256 got);

    /// @notice Thrown when the predicted CREATE3 dispatcher address does not equal the ticket's executor.
    /// @param expected The ticket's `executor` (== predicted dispatcher address).
    /// @param got The `CREATE3.getDeployed(salt, factory)` result.
    error TicketAddressMismatch(address expected, address got);

    /// @notice Thrown when the same `ticketKey` is reused with different data (§4.2 replay guard).
    /// @param expected The first-seen ticket commitment for this key.
    /// @param got The commitment of the replayed message.
    error TicketReplayMismatch(bytes32 expected, bytes32 got);

    /// @notice Thrown when adopting a re-request whose commitment differs from the own deployment's (§4.2 (b)).
    /// @param expected The own deployment's committed immutable-parameters hash.
    /// @param got The re-request's immutable-parameters hash.
    error TicketAdoptionCommitmentMismatch(bytes32 expected, bytes32 got);

    // ============================================================
    // Factory — deployment receipts & cancellation (source, §4.2)
    // ============================================================

    /// @notice Thrown when a receipt/cancel references a request that is not in the PENDING state (a
    ///         DEPLOYMENT_ACK is also accepted for a CANCELLED request, IL-8649).
    /// @param requestId The referenced request id.
    error DeploymentNotPending(uint256 requestId);

    /// @notice Thrown when a deployment receipt arrives from a chain other than the request's destination.
    /// @param expected The request's destination chain.
    /// @param got The receipt's source chain.
    error DeploymentReceiptChainMismatch(uint256 expected, uint256 got);

    /// @notice Thrown when an ACK's `dstChainId` field does not equal the pending request's destination
    ///         chain (§8 P3 item 1).
    /// @param expected The request's destination chain.
    /// @param got The ACK's `dstChainId`.
    error DeploymentAckChainMismatch(uint256 expected, uint256 got);

    /// @notice Thrown when a `DEPLOYMENT_NACK` carries a reason outside the known `NackReason` set
    ///         (`REJECTED_OCCUPIED` / `DESTINATION_VALIDATION` / `TICKET_EXPIRED`; `DESTINATION_VALIDATION` is
    ///         reserved and never sent) (§8 P3 item 2).
    /// @param reason The unrecognized reason byte.
    error InvalidNackReason(uint8 reason);

    /// @notice Thrown when a receipt's ticket commitment does not match the pending request's commitment.
    /// @param expected The pending request's ticket hash.
    /// @param got The receipt's ticket hash.
    error TicketCommitmentMismatch(bytes32 expected, bytes32 got);

    /// @notice Thrown when a pending deployment is cancelled before its TTL plus `DEPLOYMENT_CANCEL_MARGIN`
    ///         has elapsed (plus `DEPLOYMENT_CANCEL_GRACE` for a caller other than the factory owner, the
    ///         executor or its manager, IL-8649).
    /// @param requestId The referenced request id.
    /// @param nowTs The current timestamp.
    /// @param executableAt The earliest cancellable timestamp for this caller (`createdAt + DEPLOYMENT_TTL +
    ///        DEPLOYMENT_CANCEL_MARGIN`, `+ DEPLOYMENT_CANCEL_GRACE` for a third party).
    error DeploymentTtlNotElapsed(uint256 requestId, uint256 nowTs, uint256 executableAt);

    // ============================================================
    // Factory — timelocked configuration (§4.2)
    // ============================================================

    /// @notice Thrown when configuring an asset that is permanently frozen (an executor created for it, a
    ///         deployment ACK received, or a dispatcher deployed / adopted for it on this chain).
    /// @param assetId The frozen asset id.
    error AssetConfigFrozen(bytes32 assetId);

    /// @notice Thrown when configuring a path that is permanently frozen (first dispatcher deployed).
    /// @param chainId The frozen path chain id.
    error PathConfigFrozen(uint256 chainId);

    /// @notice Thrown by the Stargate factory's `schedulePathConfig` when the last supplied entry for one
    ///         of its message types is missing or is not exactly one executor `lzReceive` option with
    ///         gas in the factory path bounds and no value (IL-8296).
    /// @param chainId The chain id of the path being scheduled.
    /// @param msgType The first message type whose options were refused.
    error PathConfigOptionsInvalid(uint256 chainId, uint16 msgType);

    /// @notice Thrown when an asset/path config change is attempted while an affected ticket is pending.
    error ConfigChangeWhilePendingTicket();

    /// @notice Thrown when executing a config that was never scheduled (or already executed/cleared).
    error ConfigNotScheduled();
    error CreationCodesAlreadyConfigured();
    error CreationCodesNotConfigured();
    error EmptyCreationCode();
    error CreationCodeTooLarge();

    /// @notice Thrown when executing a scheduled config before its timelock has elapsed.
    /// @param nowTs The current timestamp.
    /// @param executableAt The earliest executable timestamp (`scheduledAt + CONFIG_DELAY`).
    error ConfigTimelockNotElapsed(uint256 nowTs, uint256 executableAt);

    /// @notice Thrown when a configured token/pool address has no contract code.
    /// @param target The code-less address.
    error NotAContract(address target);

    // ---- IL-8608: legacy withdraw-manager slot ----

    /// @notice Thrown when a remote PlasmaVault reports no withdraw manager in either storage slot, or the
    ///         command names `address(0)` as the manager.
    /// @param plasmaVault The remote vault whose manager could not be resolved.
    error WithdrawManagerUnresolved(address plasmaVault);

    // ---- IL-8614: frontier repair vs open outbound records ----

    /// @notice Thrown by `approveBalance` while a frontier repair (`ADVANCE_STATE_FRONTIER` /
    ///         `ADVANCE_FRONTIER`) is pending on the chain and `outboundInFlight` is still non-zero. The repair
    ///         can skip a lost `TRANSFER_SETTLED`; the attestation read at the repaired frontier already
    ///         contains the delivered amount, so approving it while the outbound record is open would count it
    ///         twice (S + 2A). Close the record first (replayed `TRANSFER_SETTLED`, `DELIVERED_TO_SETTLED` or
    ///         `DROP_FROM_NAV`), then approve.
    /// @param chainId The chain awaiting the approval.
    /// @param outboundInFlight The outbound value still booked in flight (shared decimals).
    error FrontierRepairBlockedByOpenTransfers(uint256 chainId, uint256 outboundInFlight);

    // ---- IL-8618 / IL-8620 / IL-8624: untagged chain block ----

    /// @notice Thrown by `forceSetSettled` while a return record that owns booked value but holds no staleness
    ///         slot is still open on the chain. Such a record is not in `pendingTransferCount`; resolve it
    ///         (`applyForceResolve` or the late leg that finalizes it), then retry.
    /// @param chainId The chain the force-set targets.
    /// @param count Open return records without a staleness slot.
    error UnclockedReturnOpen(uint256 chainId, uint32 count);

    // ---- IL-8625: permissionless first delivery of a command ----

    /// @notice Thrown when a command is delivered with less gas than its budget (`Command.minExecutionGas`, on
    ///         Stargate raised by any RETRY raise, never below `COMMAND_EXECUTION_MIN_GAS`). Nothing is written;
    ///         the packet / message stays retryable with more gas.
    /// @param available The gas left at the check.
    /// @param required The command's budget (at least `CrosschainConstants.COMMAND_EXECUTION_MIN_GAS`).
    error InsufficientGasForCommand(uint256 available, uint256 required);

    /// @notice Thrown by an executor that would stamp a command budget below `COMMAND_EXECUTION_MIN_GAS`: the lane's
    ///         effective gas does not cover the floor plus the pre-call work of THIS payload. Nothing is sent.
    /// @param laneGas The effective delivery gas of the lane (CCIP route policy / Stargate registered `lzReceive` gas).
    /// @param requiredLaneGas The smallest lane gas that yields the floor budget for the payload.
    error CommandLaneGasTooLow(uint256 laneGas, uint256 requiredLaneGas);

    /// @notice Thrown when a manager-chosen command budget exceeds `MAX_COMMAND_EXECUTION_GAS`, or (CCIP) when the
    ///         budget derived from the route's gas limit does.
    error CommandBudgetAboveMax(uint256 requested, uint256 maximum);

    /// @notice Thrown by the CCIP executor when a manager-supplied `minExecutionGas` exceeds the budget its effective
    ///         gas limit yields. CCIP delivers exactly the route's gas limit; more gas needs a timelocked policy raise.
    error CommandBudgetAboveLane(uint256 requested, uint256 derived);

    // ---- IL-8623: absolute expiry of a CREATE_DISPATCHER ticket ----

    /// @notice Thrown by the destination factory when a fresh ticket would deploy a dispatcher while the owner
    ///         has an asset-config migration scheduled for the ticket's asset. The deployment would freeze the
    ///         asset and make the scheduled `executeAssetConfig` (Stargate) / `executeAsset` (CCIP) revert
    ///         permanently; nothing is written and the packet stays retryable until the migration executes, or on
    ///         CCIP is cancelled via `cancelScheduledConfig` (the ticket's own expiry still applies). The gate does
    ///         not apply to an already frozen asset, which cannot be migrated anyway.
    /// @param assetId The asset with a scheduled, not yet executed config.
    error DestinationAssetMigrationScheduled(bytes32 assetId);

    /// @notice Thrown by a destination factory when a ticket's `expiresAt` lies further ahead than any source can
    ///         have set it: `block.timestamp + MAX_DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN`. It rejects a longer
    ///         foreign layout read through the ticket's, the salt decoded as the expiry on CCIP, and a destination
    ///         clock that lags the source beyond the margin. Retryable: nothing is written and no NACK is sent.
    /// @param expiresAt The ticket's `expiresAt`.
    /// @param maxExpiresAt The highest accepted `expiresAt` at this block.
    error TicketExpiryOutOfRange(uint256 expiresAt, uint256 maxExpiresAt);

    /// @notice Thrown by the CCIP source factory on a NACK(`TICKET_EXPIRED`) received before the current pending
    ///         request's own `createdAt + DEPLOYMENT_TTL`: such a NACK answers an earlier, identical request and must
    ///         not close the fresh one. Retryable: the pending request is untouched.
    /// @param executor The executor with the pending request.
    /// @param dstChainId The destination chain id.
    /// @param notBefore The first timestamp at which a TICKET_EXPIRED NACK is accepted.
    error PrematureExpiredNack(address executor, uint256 dstChainId, uint256 notBefore);

    // ---- IL-8645: the remote vault's asset() is re-asserted at deposit time ----

    /// @notice Thrown by a dispatcher deposit when the allowlisted vault's `asset()` is no longer the dispatcher's
    ///         ASSET (an upgradeable or mutable-underlying vault changed it after admission). Nothing is approved
    ///         or deposited; the command FAILS with a NACK. Redeems from such a vault stay possible.
    /// @param vault The drifted vault.
    /// @param actual The `asset()` the vault reports now.
    error VaultAssetDrifted(address vault, address actual);
}
