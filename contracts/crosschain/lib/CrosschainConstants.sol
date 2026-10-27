// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Crosschain wire message types
/// @notice Envelope discriminator for every LayerZero message exchanged by the crosschain layer.
/// @dev Order is FROZEN once wire tests exist — appending is allowed, reordering/removing is not.
///      See the transport READMEs (`contracts/crosschain/stargate/README.md`,
///      `contracts/crosschain/ccip/README.md`) for the message flows.
enum MsgType {
    NONE, // 0 - invalid / uninitialized
    CREATE_DISPATCHER, // 1  factory -> factory: bound deployment ticket
    DEPLOYMENT_ACK, // 2  factory -> factory: ticket committed + deployed dispatcher address
    DEPLOYMENT_NACK, // 3  factory -> factory: rejected (address occupied or ticket expired; see `NackReason`)
    UPDATE_VAULTS, // 4  executor -> dispatcher: sequenced allowlist replacement (also the initial list)
    // Also the compose payload of the dispatcher -> executor recall return (`StargateCrosschainDispatcher`).
    OUTBOUND_TRANSFER, // 5  executor -> dispatcher: COMPOSE payload accompanying a Stargate asset send
    TRANSFER_SETTLED, // 6  dispatcher -> executor: inbound asset credited on destination
    RETURN_ASSETS_REQUEST, // 7  executor -> dispatcher (RECALL LANE): please return assets
    // Also carries the dispatcher's post-debit balance (`remoteBalanceSD`, anchor evidence only, IL-8606).
    RETURN_STARTED, // 8  dispatcher -> executor: authenticated return metadata (sent/received SD, guid, version)
    COMMAND, // 9  executor -> dispatcher: business command (wraps a BusinessAction)
    RETRY_COMMAND, // 10 executor -> dispatcher (RECALL LANE): retry a FAILED command
    CANCEL_COMMAND, // 11 executor -> dispatcher (RECALL LANE): cancel a FAILED command
    // Also closes a CANCELLED command and answers an expired cancel (IL-8594): the receipt carries a
    // `CommandResolution`.
    ACK, // 12 dispatcher -> executor: command succeeded (+ stateVersion, value delta)
    NACK, // 13 dispatcher -> executor: command failed
    RETURN_REJECTED // 14 dispatcher -> executor: recall not accepted, see `ReturnRejectReason`
}

/// @title Inner business action carried under `MsgType.COMMAND`
/// @dev `actionData` in the `Command` struct is the ABI-encoding of the per-action tuple documented
///      in `CrosschainMessages` (DEPOSIT/REDEEM/REQUEST_SHARES/REDEEM_FROM_REQUEST).
enum BusinessAction {
    NONE, // 0 - invalid
    DEPOSIT, // 1 - (vault, amount, minShares)
    REDEEM, // 2 - (vault, shares, minAssets)
    REQUEST_SHARES, // 3 - (withdrawManager, plasmaVault, shares, maxFeeShares)
    REDEEM_FROM_REQUEST // 4 - (withdrawManager, plasmaVault, shares, minAssets, receiver)
}

/// @title Dispatcher-side lifecycle of a single business command
enum CommandStatus {
    NONE, // 0 - never seen
    PENDING, // 1 - persisted, self-call in progress / awaiting outcome
    SUCCEEDED, // 2 - business action succeeded, ACK sent, sequence advanced
    FAILED, // 3 - business action reverted or the command had expired, NACK sent, sequence NOT advanced
    CANCELLED // 4 - a FAILED command terminally cancelled, sequence advanced by one (not when closed as EXPIRED)
}

/// @title How the dispatcher resolved a command, as reported by its receipt
/// @dev A cancel resolution reuses the ACK envelope, so the receipt itself must say which outcome it
///      carries. The executor MUST NOT infer this from local flags: a cancel and a retry can both be in
///      flight for the same command, and any local flag is therefore ambiguous by the time the receipt
///      lands (audit `config_epoch_desync_via_retry_clearing_in_flight_cancel`).
enum CommandResolution {
    SUCCEEDED, // 0 - the business/config action ran on the dispatcher
    CANCELLED, // 1 - the command was terminally cancelled; no action was applied
    // 2 - a CANCEL_COMMAND arrived past the command's deadline (IL-8594). The dispatcher closed the command
    //     (CANCELLED) WITHOUT consuming its sequence and applied nothing; the executor frees the slot (only while
    //     the same command sits there FAILED) and keeps its sequence mirror, so a replacement reuses the sequence.
    EXPIRED
}

/// @title Source/destination-factory view of a dispatcher deployment
/// @dev The executor's own request record uses FAILED for every NACK (`onDispatcherRequestFailed`); only the
///      factories record REJECTED_OCCUPIED.
enum DeploymentStatus {
    NONE, // 0 - unknown request id
    PENDING, // 1 - ticket sent, awaiting ACK/NACK
    DEPLOYED, // 2 - authenticated ACK received, hasDispatcher flipped true
    // FAILED: on the source factory a NACK with reason TICKET_EXPIRED (IL-8623) or the reserved, never-sent
    // DESTINATION_VALIDATION.
    FAILED, // 3 - authenticated NACK (no dispatcher, readiness never flips)
    // CANCELLED is not strictly terminal: a late ACK matching the cancelled ticket still promotes the request
    // to DEPLOYED while nothing else decided the chain (IL-8649).
    CANCELLED, // 4 - cancelled after DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN
    REJECTED_OCCUPIED // 5 - destination address occupied by non-own code (squat); never an ACK
}

/// @title Outcome of a Stargate `scheduleForceResolveTransfer` / `executeForceResolveTransfer` rescue
/// @dev 0-3 resolve a permanently stuck in-flight record; 4-7 repair the version frontier or the command lane.
enum ResolveOutcome {
    // For a recall with no leg arrived yet this only releases the slot and moves no bucket.
    DROP_FROM_NAV, // 0 - value provably lost: drop the in-flight entry from NAV
    DELIVERED_TO_SETTLED, // 1 - value provably delivered to the remote: move to settledRemoteBalance
    RETURNED_TO_IDLE, // 2 - reserved: unreachable since H-01, rejected at schedule time on Stargate; CCIP does not use it
    DROP_RETURN_METADATA_INCLUDED, // 3 - abandon pre-metadata recall; subsequent force-set includes its debit
    // ADVANCE_STATE_FRONTIER sizing is the same rule on both transports: `newVersion` = (lowest version that can
    // still be delivered) - 1, never past a retained / queued value-moving response (Stargate: TRANSFER_SETTLED /
    // RETURN_STARTED; CCIP: TRANSFER_SETTLED / RETURN_TRANSFER - ACKs are value-neutral and never move the
    // frontier): the frontier would drop it as a duplicate. The dispatcher's `stateVersion()` alone
    // is NOT the target: it is the latest version assigned (CCIP assigns it when a response is QUEUED, not
    // delivered), so it is at or above the version of every response still deliverable while the queue is
    // non-empty or an OffRamp message is still executable. Read it together with the response queue / what LayerZero still
    // holds. See `CcipCrosschainExecutor._requireFrontierAdvance` and `stargate/README.md`, "Frontier repair
    // (Stargate)".
    ADVANCE_STATE_FRONTIER, // 4 - id packs `(uint192 chainId,uint64 newVersion)`; chain remains blocked
    // The two ABANDON_COMMAND outcomes free a command slot whose receipt can never arrive. `id` is
    // `bytes32(chainId)`. The admin declares, from the observed remote state, whether the dispatcher
    // consumed the command's sequence (it advances its own on BOTH a success and a cancel), because the
    // executor cannot know: the only thing that would have told it is the receipt that was lost.
    // A packet the transport retained at the time of an abandon stays executable afterwards: LayerZero
    // keeps a reverted packet, and a CCIP OffRamp keeps a FAILED message that anyone may execute manually.
    // A retained COMMAND / UPDATE_VAULTS / RETRY_COMMAND would therefore run the abandoned intent later —
    // at a sequence the lane has not reached yet, or at the very sequence the replacement reuses, which it
    // then supersedes. Every command id carries its expiry (`CrosschainMessages.commandDeadline`, set to
    // `COMMAND_TTL` after the build): the dispatcher NACKs expired work without advancing its sequence,
    // and both abandon outcomes are refused until `COMMAND_EXPIRY_MARGIN` past that deadline, so an
    // abandoned command can never execute its business action (IL-8255). A retained CANCEL_COMMAND
    // carries no business action, but an abandon is only possible past the command deadline plus margin, so on both
    // transports a cancel landing afterwards is expired as long as the dispatcher chain's clock lags by no more than
    // `COMMAND_EXPIRY_MARGIN`: the dispatcher closes the command without consuming the sequence and answers an
    // `EXPIRED` receipt (IL-8594), which the executor honours only for the FAILED command that owns the slot, so it
    // cannot retire a same-sequence replacement; a stored command left CANCELLED at its still-current sequence
    // therefore needs `consumed = false`. The residual is an in-window cancel (it consumed the sequence) whose
    // ACK is still in transit when a wrong UNUSED abandon runs: the ACK is adopted (`_adoptLateReceipt`) or one
    // ABANDON_COMMAND_SEQUENCE_CONSUMED round realigns them. Declare CONSUMED only against the dispatcher's
    // observed nextCommandSequence, never from the abandon alone — declaring it when the lane did not move
    // creates the very desync it is meant to repair. If the packet lands AFTER a replacement has already
    // advanced the lane past that sequence, the Stargate dispatcher ignores it as stale (IL-7979). An expired
    // FAILED command is released by the manager's CANCEL without the admin. Within the TTL, prefer funding the
    // dispatcher and letting a retained packet execute; an abandon has to wait the TTL out anyway. (A CCIP
    // RETRY_COMMAND at a stale sequence is rejected with InvalidSequence by its dispatcher instead of being
    // ignored.) A wrong declaration is no longer terminal: both transports adopt a late receipt's counters and
    // supersede a replacement it doomed (`_adoptLateReceipt`), and both have REALIGN_COMMAND_LANE below for the
    // cases where no receipt exists or can be solicited (IL-7970).
    ABANDON_COMMAND_SEQUENCE_UNUSED, // 5 - the dispatcher never ran the command; its sequence is unchanged
    ABANDON_COMMAND_SEQUENCE_CONSUMED, // 6 - the dispatcher resolved the command; its sequence advanced by one
    // REALIGN_COMMAND_LANE sets the lane's mirrors to the dispatcher's observed counters. `id` packs
    // `(uint64 chainId << 192) | (uint48 expectedEpoch << 144) | (uint48 expectedSequence << 96)
    // | (uint48 newEpoch << 48) | uint48 newSequence` (IL-8652). The expected pair is the executor's own
    // `chainConfigEpoch` / `nextSequenceToSend` mirrors the rescue is armed against: execute reverts
    // `RealignStateMoved` if a late ACK moved them during the delay. Armed behind an abandon in the same batch,
    // the expected sequence is the post-abandon value (+1 for CONSUMED). The only outcome that can LOWER the
    // sequence mirror; requires a free command slot (abandon first — both may be scheduled together and
    // executed back to back after one delay). New values are read from the dispatcher's public
    // `nextCommandSequence()` / `commandConfigEpoch()` getters. The 48-bit counter fields are unreachable
    // limits (2^48 commands per lane). A mis-packed id decodes to some other chain id and is refused at
    // schedule time (`DispatcherNotReady`) unless that id happens to be registered. A zero expected epoch is
    // valid on Stargate (the epoch mirror is 0 until the first UPDATE_VAULTS ACK; CCIP's route initialisation
    // sets it to 1). Re-decode `id >> 192` yourself and check it against the chain
    // you meant (IL-7970).
    REALIGN_COMMAND_LANE // 7 - set nextSequenceToSend / chainConfigEpoch for the packed chain id
}

/// @title Chain-scoped timelocked rescue on the CCIP transport
/// @dev CCIP has no generic force-resolve entry point the way Stargate does, so its chain-scoped rescues
///      share one tagged `scheduleChainRescue`/`executeChainRescue` pair. Kept as one pair rather than a
///      function each to save executor runtime bytes (EIP-170): the consolidation is what brought the
///      executor back under the limit.
enum CcipChainRescue {
    ABANDON_COMMAND, // 0 - free a command slot whose receipt can never arrive; `arg` is `sequenceConsumed`
    ADVANCE_FRONTIER, // 1 - skip a lost remote state version; `arg` is the new version. Shorter timelock.
    // FORCE_SET_SETTLED `arg` is `(observedStateVersion << 192) | (observedRemoteTimestamp << 128) | newSettledLD`
    // (IL-8646): the dispatcher `stateVersion` the balance was read at must equal the executor's acknowledged
    // frontier at execute time (IL-8294).
    FORCE_SET_SETTLED, // 2 - overwrite the settled balance and lift a NAV block
    // REALIGN_COMMAND_LANE sets the command-lane mirrors to the dispatcher's observed counters. `arg` is
    // `(expectedEpoch << 192) | (expectedSequence << 128) | (newEpoch << 64) | newSequence`; the chain is the
    // separate `chainId_` parameter, so nothing about the chain is packed here. The expected pair is the
    // executor's own mirrors the rescue is armed against: execute reverts `RealignStateMoved` if a late ACK
    // moved them during the delay, so a stale rescue never rolls the lane back (reschedule from the new state;
    // behind an abandon armed in the same batch, give the post-abandon state). The only kind that can LOWER
    // the sequence mirror; requires a free command slot at EXECUTE time (abandon first — both may be
    // scheduled together and executed back to back after one delay) (IL-7970).
    REALIGN_COMMAND_LANE, // 3 - set nextCommandSequence / commandConfigEpoch mirrors for `chainId_`
    // FORCE_SET_SETTLED_UNCHECKED takes the same argument word and the same schedule-time checks as FORCE_SET_SETTLED
    // and differs only in the execute-time monotonic-clock gate (IL-8648 R1): it may stamp a committed observation
    // time OLDER than `lastApprovedObservedAt`, moving the NAV freshness clock backwards. The kind is part of the
    // rescue commitment, so a strict schedule can never be executed as unchecked and the guardian sees the choice.
    FORCE_SET_SETTLED_UNCHECKED // 4 - FORCE_SET_SETTLED without the "never move the NAV clock backwards" gate
}

/// @title Reason accompanying a `DEPLOYMENT_NACK`
enum NackReason {
    NONE, // 0
    REJECTED_OCCUPIED, // 1 - predicted address occupied by code this factory never deployed
    // Reserved, never sent: Stargate sends REJECTED_OCCUPIED and TICKET_EXPIRED (CCIP uses its own uint8 codes
    // 1-4), because destination validation cannot fail (the dispatcher is born with an empty allowlist). Kept
    // because the wire order is frozen.
    DESTINATION_VALIDATION, // 2 - reserved: ticket failed destination-side validation
    TICKET_EXPIRED // 3 - the ticket was delivered at or after its `expiresAt`; nothing was deployed (IL-8623)
}

/// @title Reason accompanying a `RETURN_REJECTED`
enum ReturnRejectReason {
    NONE, // 0
    NO_TRACKED_IDLE, // 1 - nothing sendable: min(request, accounted bound, tracked idle) == 0
    BELOW_MINIMUM, // 2 - the clamped send (IL-8119) or the pool's quoted credit (IL-8452) is below the floor
    ABOVE_PATH_CREDIT // 3 - the send exceeds the live Stargate path credit; the pool would revert (IL-8616)
}

/// @title CrosschainConstants
/// @notice Codec version, hard caps, timelocks / windows and command gas budgets shared across the crosschain
///         contracts.
/// @dev Where a cap applies, exceeding it reverts BEFORE any iteration or storage growth. Not every list that an
///      on-chain path iterates is capped. The CCIP executor's `dispatcherChainIds` has no cap:
///      `MAX_DISPATCHER_CHAINS` is enforced only when a chain is registered on a Stargate executor. The CCIP list
///      is append-only and gets one entry per chain on which the factory acknowledged a dispatcher, that is, per
///      chain the factory owner routed (timelocked) and the executor's MANAGER asked for. `getBalance` and
///      `getBalanceUnchecked` iterate it. The factories' `executorsOf` registry is not capped either: it is an
///      append-only list meant for off-chain reads that no on-chain path iterates. All numeric limits are
///      POC-tuned and intentionally small.
library CrosschainConstants {
    /// @notice Current envelope codec version. `decodeEnvelope` rejects any other value.
    uint8 internal constant CODEC_VERSION = 4;

    /// @notice Single mandatory compose index for taxi-mode sends (one compose per message).
    /// @dev Not referenced by the code: the factory's dispatcher compose option passes index 0 literally.
    uint16 internal constant COMPOSE_INDEX = 0;

    /// @notice Maximum number of remote chains a single Stargate executor may register a dispatcher on.
    /// @dev Enforced only by the Stargate executor's `registerChain` (`DispatcherChainsCapReached`). The CCIP
    ///      executor does NOT enforce it: its `dispatcherChainIds` list grows with every acknowledged dispatcher.
    uint256 internal constant MAX_DISPATCHER_CHAINS = 32;

    /// @notice Maximum size of a dispatcher deposit allowlist.
    uint256 internal constant MAX_ALLOWED_VAULTS = 32;

    /// @notice Maximum size of the dispatcher tracked-position set (Stargate: vaults holding live shares, the
    ///         allowlist is kept apart; CCIP: allowlist ∪ live positions).
    uint256 internal constant MAX_TRACKED_POSITION_VAULTS = 32;

    /// @notice Maximum concurrent in-flight transfer records per chain. Stargate: one shared counter across
    ///         outbound transfers and recalls. CCIP: outbound transfers only (a recall uses the single
    ///         `activeReturn` slot).
    uint256 internal constant MAX_PENDING_TRANSFERS_PER_CHAIN = 16;

    /// @notice Maximum unresolved manager-cancelled recalls per chain (CCIP). Bounds the `RETURN_TRANSFER` /
    ///         `RETURN_REJECTED` responses an unmetered recall-cancel loop can leave in the dispatcher's bounded
    ///         response queue (IL-8583).
    uint256 internal constant MAX_CANCELLED_RECALLS_PER_CHAIN = 4;

    /// @notice Maximum concurrent scheduled rescues / force-resolves in the rescue queue.
    uint256 internal constant MAX_PENDING_RESCUES = 64;

    /// @notice Governance-approved minimum delay for any value-moving rescue.
    uint256 internal constant MIN_RESCUE_DELAY = 24 hours;

    /// @notice Lower bound on the factory configuration timelock (assets, paths, routes). Shared by Stargate and CCIP.
    uint256 internal constant MIN_CONFIG_DELAY = 24 hours;

    /// @notice Dedicated delay for repairing a missing authenticated state-version frontier.
    ///         Frontier repair never authorizes value movement and still leaves the chain blocked
    ///         until a fresh dual-role attestation is approved, or a timelocked force-set runs (the only exit
    ///         when a block other than an earlier repair's already stood, IL-8620).
    uint256 internal constant FRONTIER_REPAIR_DELAY = 6 hours;

    /// @notice Lower bound on a Stargate executor's `DEPLOYMENT_TTL`, enforced by the
    ///         `StargateCrosschainExecutor` constructor and again by `StargateCrosschainFactory.requestDispatcher`
    ///         when it reads the TTL per ticket; a TTL below this would make an honest in-flight ticket
    ///         cancellable before its ACK can arrive (orphaning the same-address dispatcher) and lets a
    ///         request/cancel loop drain the factory's native budget (IL-8049, IL-8069).
    uint256 internal constant MIN_DEPLOYMENT_TTL = 1 hours;

    /// @notice Upper bound on an executor's `DEPLOYMENT_TTL`; a ticket whose TTL never elapses keeps
    ///         `pendingCountByAsset` / `pendingCountByChain` raised forever and freezes the factory's
    ///         asset/path configuration for every tenant (IL-8049).
    uint256 internal constant MAX_DEPLOYMENT_TTL = 30 days;

    /// @notice Clock-lag allowance between the source and destination factory chains for a deployment ticket's
    ///         `expiresAt` (IL-8623).
    /// @dev `StargateCrosschainFactory.cancelPendingDeployment` and `CcipCrosschainFactory.cancelExpiredDeployment`
    ///      are refused before `expiresAt + this`, while the
    ///      destination refuses to deploy from `expiresAt` on, each by its own clock. The margin must cover the
    ///      largest lag of the destination's `block.timestamp` behind the source's; it is the same rule and the
    ///      same value as `COMMAND_EXPIRY_MARGIN` (see there for the per-chain bounds and the accepted residual).
    uint256 internal constant DEPLOYMENT_CANCEL_MARGIN = 24 hours;

    /// @notice Exclusive window after `expiresAt + DEPLOYMENT_CANCEL_MARGIN` in which only the executor's `MANAGER`
    ///         or the factory owner may cancel a pending deployment ticket; third parties may cancel only from
    ///         `expiresAt + DEPLOYMENT_CANCEL_MARGIN + this` (IL-8637 / IL-8649).
    /// @dev A ticket cancelled while its ACK is still retained or in flight orphans that ACK unless the factory
    ///      accepts it late (see the cancelled-record match in both factories). The window lets the operator
    ///      retry a retained ACK first, so a griefer cannot front-run the retry with a cancel.
    uint256 internal constant DEPLOYMENT_CANCEL_GRACE = 3 days;

    /// @notice Upper bound on `STALENESS_MAX` / `TRANSFER_STALENESS_MAX` (Stargate) and
    ///         `BALANCE_STALENESS_MAX` / `TRANSFER_STALENESS_MAX` (CCIP, IL-8058); above it the
    ///         fail-closed staleness gates become unreachable. Must exceed `MIN_RESCUE_DELAY` so a
    ///         rescue can land inside the window.
    uint256 internal constant MAX_STALENESS_WINDOW = 7 days;

    /// @notice Safety margin added to `TRANSFER_STALENESS_MAX` before the CCIP executor lets `FORCE_SET_SETTLED` /
    ///         `ADVANCE_FRONTIER` clear a cancelled recall's clock (IL-8590). A `RETURN_REQUEST` deadline is stamped
    ///         with the source chain's `block.timestamp` but checked against the dispatcher chain's, so the two
    ///         clocks may disagree; the margin covers that cross-chain `block.timestamp` skew.
    /// @dev The margin is an ASSUMPTION, not a guarantee: it assumes the two chains' `block.timestamp` differ by less
    ///      than 15 minutes (honest-sequencer assumption; e.g. an Arbitrum sequencer may stamp blocks up to ~24 h
    ///      behind L1). If the skew exceeds it, a reset can still precede a late honoured request.
    ///      `TRANSFER_STALENESS_MAX` also bounds recall liveness: if it is shorter than the lane's worst-case CCIP
    ///      delivery (source finality + execution, or a manual re-execution), every recall comes back `EXPIRED`.
    uint256 internal constant RECALL_DEADLINE_SKEW_MARGIN = 15 minutes;

    /// @notice Minimum spacing between two CCIP `requestRemoteBalance` calls to the same chain (IL-8579). Each call
    ///         costs the executor a CCIP fee and queues a `BALANCE_REPORT` in the dispatcher's bounded response FIFO.
    uint256 internal constant BALANCE_REQUEST_COOLDOWN = 10 minutes;

    /// @notice Minimum spacing between two `CANCEL_COMMAND` sends for the same FAILED command (IL-8579). Each send
    ///         costs the executor a transport fee. Same ceiling as balance requests (at most 144 fees per day per
    ///         chain), and a cancel that was lost in transit can still be re-sent once the cooldown has passed.
    uint256 internal constant CANCEL_COMMAND_COOLDOWN = 10 minutes;

    /// @notice Lifetime of a sequenced COMMAND / UPDATE_VAULTS, stamped into its id at build time.
    /// @dev Past it the dispatcher NACKs the command instead of running it, whichever lane delivers it
    ///      (fresh, redelivered or retried), so a packet retained across an abandon cannot execute the
    ///      abandoned intent (IL-8255). Also bounds how stale the manager's slippage floors can be when a
    ///      delayed command finally runs.
    uint256 internal constant COMMAND_TTL = 24 hours;

    /// @notice Clock-lag allowance between the executor and dispatcher chains for the command TTL.
    /// @dev The margin must cover the largest tolerable lag of a destination chain's `block.timestamp` behind the
    ///      source's on the project's lanes. Arbitrum: `SequencerInbox.maxTimeVariation().delaySeconds` is
    ///      86 400 s (a message timestamp may trail L1 by up to a day; `futureSeconds` lets it lead by 3 600 s).
    ///      OP Stack: an L2 block's timestamp is never earlier than its L1 origin's and at most
    ///      `max_sequencer_drift` (1 800 s) ahead of it, and the L1 origin may trail the L1 head by at most the
    ///      sequencing window (3 600 L1 blocks, about 12 h), so the lag stays below 24 h. The margin is checked
    ///      at execute time only; `RESCUE_DELAY` runs from scheduling, which may precede the deadline (the
    ///      commitment names the chain, not the command), so it does not add to the margin: an abandon lands no
    ///      earlier than deadline + `COMMAND_EXPIRY_MARGIN`. This bounds a lagging destination exactly only when
    ///      the executor's own clock does not lead L1; an Arbitrum-hosted executor may lead by `futureSeconds`
    ///      and both parameters are governance-settable, an accepted residual (IL-8591, low). A lane whose
    ///      destination can lag by more than this must not be configured.
    uint256 internal constant COMMAND_EXPIRY_MARGIN = 24 hours;

    /// @notice Maximum number of remote state versions a single frontier repair may skip.
    /// @dev The repair is the one write in the system that moves the anti-replay frontier without an
    ///      authenticated message behind it, and it is irreversible: the frontier is monotonic in every
    ///      writer, so an overshoot can never be walked back. Every remote version the jump lands past is
    ///      consumed as an "older duplicate" by `_advanceVersionFrontier`, and its message's accounting is
    ///      silently dropped; overshoot the dispatcher's real counter and EVERY future message on that lane
    ///      is dropped, permanently (audit
    ///      `unbounded_irreversible_state_version_jump_silently_swallows_authenticated_messages` /
    ///      `unbounded_one_way_frontier_advance_permanently_disables_version_check`).
    ///
    ///      A cap cannot catch an off-by-one — nothing on this chain can observe the remote counter — but
    ///      it does catch the error classes that actually brick a lane: a mis-scaled value (`2 << 32`), a
    ///      fat-fingered extra digit, or a version read off the wrong chain. 32 sits far above any
    ///      plausible run of genuinely lost messages (only value-moving responses take a version, IL-8257;
    ///      a Stargate chain holds at most `MAX_PENDING_TRANSFERS_PER_CHAIN` = 16 unresolved value-moving
    ///      records) while staying orders of magnitude below every realistic mis-scale. A genuinely larger gap is still
    ///      repairable by repeating the rescue, which is the correct friction for a write this final.
    uint256 internal constant MAX_FRONTIER_JUMP = 32;

    /// @notice Minimum `gasleft()` a dispatcher requires before it persists FAILED and sends a NACK (a caught
    ///         business failure or an expired command), else it reverts `InsufficientGasForNack` (retryable).
    /// @dev A guard, not a budget: on the real LayerZero endpoint the NACK send costs more;
    ///      `COMMAND_CATCH_RESERVE_GAS` is what keeps that headroom for the catch path.
    uint256 internal constant MIN_NACK_GAS = 150_000;

    /// @notice Minimum time a balance proposal's `expiry` must leave after propose-time for the approver
    ///         to act (the "meaningful approval window", audit V2-02). A proposal whose
    ///         `expiry - block.timestamp` is below this is rejected at propose-time, so a proposer cannot
    ///         emit proposals (e.g. `expiry = block.timestamp + 1`) that are practically impossible to
    ///         approve within a normal multisig/keeper cycle. Kept below any sane `STALENESS_MAX` so it
    ///         never becomes the binding freshness gate; the executor constructor enforces
    ///         `STALENESS_MAX >= MIN_PROPOSAL_APPROVAL_WINDOW`.
    uint256 internal constant MIN_PROPOSAL_APPROVAL_WINDOW = 15 minutes;

    /// @notice Bound on how far an approved attestation may sit from the per-chain accounting anchor
    ///         (`anchorPrincipal`), expressed in bps (1e4) of the anchor, symmetric in both directions.
    /// @dev The relative per-approval limiter (`bigChangeBps`) bounds only the size of ONE step; it does
    ///      not bound the number of steps, so a compliant proposer/approver pair can walk `settledSD`
    ///      to any value given enough rounds (audit `no_cumulative_bound_on_attested_balance_ratchet`,
    ///      IL-7967). This constant closes that: after the existing relative check, `approve` also
    ///      requires `|newSettled - anchorPrincipal| * 10_000 <= anchorPrincipal * ATTESTATION_ANCHOR_BAND_BPS`.
    ///      `anchorPrincipal` tracks value the vault has verifiably placed on the remote chain (credited
    ///      only by peer-authenticated settlement/return-debit accounting and by the timelocked
    ///      `forceSetSettled` rebase — never raised by the attester pair; the only attester-driven write is
    ///      the dust-to-zero reset, reachable only when `settled` is already within the dust bound), so the band
    ///      recognises remote yield up to ±20% of principal before a rebase is needed, without ever letting two untrusted keys
    ///      set NAV to an arbitrary value.
    ///      MUST be `>= bigChangeBps_` of any deployment (currently 1_000 in the reference config) so a
    ///      single compliant relative step from `anchorPrincipal` can never be rejected by the band alone
    ///      — otherwise the first honest yield attestation after a fresh settle could fail. Both executor
    ///      constructors enforce that obligation (`bigChangeBps <= ATTESTATION_ANCHOR_BAND_BPS`):
    ///      `StargateCrosschainExecutor` since IL-8049, `CcipCrosschainExecutor` since IL-8058.
    ///
    ///      Net principal and the credit cap (IL-8578 / TP-H-02). A recall debits the anchor pro rata
    ///      against the ATTESTED `settled`, so when `settled` carries unrecognised yield the anchor falls
    ///      by less than the principal removed. Crediting the anchor in full on re-supply would then add
    ///      about 0.2x of attestable headroom per ordinary recall / re-supply round trip with no new
    ///      capital. Each transport therefore keeps a per-chain `netPrincipal` next to `anchorPrincipal`:
    ///      the sum of authenticated credits minus the authenticated amounts the dispatcher sent back on
    ///      recalls (not the settled delta, which the attesters can lower in flight), floored at zero,
    ///      rebased to the new value by `forceSetSettled`, zeroed with the anchor on the dust-to-zero
    ///      approval, and never raised by the attester pair. Every anchor CREDIT sets
    ///      `anchor = max(min(anchor + credited, netPrincipal), ceil(settledAfter * 10_000 /
    ///      (10_000 + ATTESTATION_ANCHOR_BAND_BPS)))`, i.e. a credit sets the anchor to
    ///      `max(min(anchor + credited, net), floor)` (it may lower it). Invariant: after any recall /
    ///      re-supply round trip the anchor is at most `max(netPrincipal, the pre-recall anchor)`, so it
    ///      never exceeds the largest net principal the vault has verifiably placed since the last
    ///      force-set, up to one shared-decimal unit of `Ceil` rounding per credit (a cycle costs two
    ///      bridge round trips and an attestation to gain one unit, so it is not economically
    ///      exploitable). The
    ///      band-consistency floor (the same minimum raise the recall debit uses) keeps `settled` at or below
    ///      the band ceiling: an honest yield residue left remote after a full recall (net principal 0),
    ///      followed by a small top-up, stays attestable instead of freezing.
    ///
    ///      The floor does not bound `settled` from below (IL-8737 / IL-8792). After an approved loss and a
    ///      recovery, a full recall leaves `(settled 0, anchor R, net N)` with `N > 0`; a top-up `c` then gives
    ///      `(c, min(R, N) + c)`: `settled` is below the band iff `c < 4 * min(R, N)`, and the `BigChangeExceeded`
    ///      window around it is disjoint from the band (the pre-fix freeze) iff
    ///      `c * (1 + bigChangeBps / 10_000) < 0.8 * (min(R, N) + c)`, e.g. `c < 2 * min(R, N)` at 20%. So
    ///      `approve` applies the relative check only while the current `settled` is inside the band (outside it on either side skips it; only below is reachable); below the
    ///      band it is not a baseline (like zero, IL-8606) and the band alone bounds the approval, which still
    ///      caps one approval at `1.2 * anchor`. The relative check returns after that first band approval.
    ///
    ///      Operational consequence: after a recall that leaves already-recognised yield on the remote
    ///      chain, the next credit sets the anchor at the band floor, so `settled` then sits at the band
    ///      ceiling and further honest yield cannot be attested until a `forceSetSettled` rebase. Runbook
    ///      rule: recall the whole attested bucket (or force-set) rather than only the principal; a
    ///      recognised-yield residue topped up afterwards sits at the band ceiling until a force-set.
    ///
    ///      Known limitation (IL-8554 / FP-H-01). The band bounds the LEVEL of mispricing (within ±20% of
    ///      the anchor at any instant), not the cumulative movement. A jointly compromised proposer /
    ///      approver pair can walk `settled` between the band edges repeatedly (about 9 approvals per
    ///      full 0.8x -> 1.2x -> 0.8x cycle (5 up, 4 down) at the reference `bigChangeBps` (1_000); 3 + 2
    ///      at 2_000), and a colluding depositor can
    ///      extract value on each swing. Accepted by design: it needs both independent attester keys, a
    ///      market refresh on each leg and withdrawable liquidity, and the same compromise can already
    ///      hold NAV at the band edge or block the chain. Mitigation is off-chain monitoring of
    ///      `BalanceApproved` direction reversals.
    uint256 internal constant ATTESTATION_ANCHOR_BAND_BPS = 2_000;

    /// @notice Absolute bound, in shared decimals (0.01 of a 6-shared-decimal asset), at or below which a
    ///         settled bucket may be attested down to exactly zero without the relative `BigChange` and
    ///         anchor-band checks (IL-8499, audit IL-8424 finding 6).
    /// @dev A full recall debits the bucket by the amount the dispatcher actually sent, which sits a few
    ///      units below the attested value (remote ERC-4626 redeem rounding, flooring to shared decimals),
    ///      so a few units of dust survive while the dispatcher reports 0. A dust-to-zero attestation is a
    ///      100% relative change and would revert, leaving only the timelocked `forceSetSettled`. The
    ///      exception applies only to `newBalance == 0` with `oldBalance <= ATTESTATION_ZERO_DUST_SD`, so
    ///      it cannot raise NAV, cannot move a bucket above the bound, and still needs both attestation
    ///      roles and every other `approve` check. Shared by the Stargate and CCIP transports.
    uint256 internal constant ATTESTATION_ZERO_DUST_SD = 10_000;

    // ---- IL-8625: permissionless first delivery of a command ----

    /// @notice Absolute lower bound of a command's gas budget (`Command.minExecutionGas`); a dispatcher also raises
    ///         a stored budget below it to this floor (defence in depth) (IL-8625, Ackee TP-M-47 / TP-L-13).
    /// @dev The first execution of a verified Stargate packet is permissionless with no gas stipend, so a third
    ///      party picks the gas the handler sees (CCIP: the route's exact `messageGasLimit`, a manual execution can
    ///      only raise it). The rule is a budget CARRIED BY THE COMMAND, not a classification of the revert data: a
    ///      delivery that reaches the business call with less gas than the budget reverts (state rolls back, the
    ///      delivery stays retryable); at or above the budget EVERY failure of the business call is a business
    ///      failure (FAILED + NACK), out-of-gas and `InsufficientGasForVaultRead` included. The budget is set by the
    ///      executor at send time from the lane's effective gas (see `COMMAND_PRE_CALL_BASE`) and is part of the
    ///      committed command bytes, so it cannot be lowered by the deliverer and a retry re-runs the stored value.
    ///      Sizing the lane is therefore mandatory: lane gas >= the measured cold gas of the heaviest allowed action
    ///      + the pre-call work (`COMMAND_PRE_CALL_BASE` + `COMMAND_PRE_CALL_PER_WORD` per payload word) + `COMMAND_CATCH_RESERVE_GAS` + the 1/64 slack (see the transport READMEs).
    ///      A lane sized too tightly turns an honest delivery into a NACK, because an attacker can always deliver at
    ///      exactly the budget. The floor is 1,000,000; `StargateExecutorDeploymentLib.COMMAND_LANE_MIN_RECEIVE_GAS`
    ///      is the smallest Stargate lane that still yields the floor budget for a maximum-size UPDATE_VAULTS (CCIP
    ///      routes are sized per README). Mock measurements in `CommandOutOfGasTest`: a
    ///      plain DEPOSIT delivery costs about 0.89M gas in total; a real PlasmaVault REDEEM is far heavier.
    uint256 internal constant COMMAND_EXECUTION_MIN_GAS = 1_000_000;

    /// @notice Fixed part of the gas the dispatcher spends BEFORE it checks a command's budget: the endpoint / router
    ///         hop, envelope decode, commitment, sequence and status writes, the receipt-fee quote (IL-8625).
    /// @dev The executor stamps `budget = laneGas - (Stargate only: laneGas / 64) - COMMAND_PRE_CALL_BASE
    ///      - COMMAND_PRE_CALL_PER_WORD * words`, with `words = ceil(len / 32)` of exactly the bytes the dispatcher
    ///      stores (Stargate: the ABI-encoded command / UPDATE_VAULTS; CCIP: the ABI-encoded
    ///      `(type, command, extra)`), so a delivery at the lane's gas reaches the check with at least the budget.
    ///      The `laneGas / 64` term is the gas the real LayerZero EndpointV2 keeps back on the endpoint -> OApp hop
    ///      (EIP-150); the CCIP router forwards the gas limit exactly, so it has no such term.
    ///
    ///      Calibration, COLD (see `ColdGas`: `foundry.toml` has `isolate = false`, so warm measurements understate the
    ///      cost), taken with forge 1.8.5 semantics (the CI forge; forge 1.7.1's `vm.cool` left the LayerZero fee-quote path
    ///      warm, which under-measured the first delivery by about 130k). Stargate on the real EndpointV2 and its 4-DVN ULN
    ///      receipt quote (`StargatePreCheckForkTest`), each shape the FIRST delivery on a fresh fork pair with every slot
    ///      re-cooled before each bisection trial and 2,500 added for EVERY touched account (conservative: most are cold on
    ///      a fresh fork already): pre-check work net of the lane / 64 hop loss 510k / 730k / 931k / 1,292k - 1,332k for
    ///      7 / 15 / 23 / 39 words (empty UPDATE_VAULTS, 8 / 16 / 32 vaults), a fit of about 331k fixed + 25.7k per word.
    ///      The 11-word DEPOSIT cannot be first on a path, so its figure (about 613k) is EXTRAPOLATED from that fit, not
    ///      measured. The margin over the formula is 104k - 158k, at least 100k for every shape (asserted). The ULN quote
    ///      inside that work is about 204k gas cold; each further DVN in a production config adds about 22k, so the
    ///      smallest margin covers about four more. Stargate on the mock endpoint (`StargatePreCheckPinTest`, cooled) reads
    ///      lower; CCIP, direct `ccipReceive` (`CcipPreCheckPinTest`, cooled) 321k / 344k / 544k / 725k / 1,087k for
    ///      14 / 15 / 23 / 31 / 47 words, a margin of at least 508k.
    uint256 internal constant COMMAND_PRE_CALL_BASE = 500_000;

    /// @notice Gas per stored payload word the dispatcher spends before the budget check (IL-8625).
    /// @dev The dispatcher persists the payload before the check (the writes roll back on a below-budget revert), and a
    ///      fresh non-zero SSTORE costs about 22.1k per 32-byte word, which is why a 32-vault UPDATE_VAULTS needs a
    ///      much larger pre-check allowance than a DEPOSIT. Measured cold work grows by 25.7k per word on the Stargate fork
    ///      (forge 1.8.5 fit through the 0- and 32-vault shapes) and by about 23.2k overall on CCIP (25.1k between 15 and 23
    ///      words), SSTORE plus copy and decode; 24,000 is not a per-step bound, the fixed part of the allowance keeps the
    ///      margin (at least 104k on Stargate, 508k on CCIP). Counting every word as non-zero (zero words cost about 2.2k) is a
    ///      deliberate upper bound.
    uint256 internal constant COMMAND_PRE_CALL_PER_WORD = 24_000;

    /// @notice Upper bound of a manager-chosen command budget (Stargate `minExecutionGas` top-up and RETRY raise; CCIP
    ///         derived budget) (IL-8625).
    /// @dev Bounded by the destination chain's per-transaction gas cap: EIP-7825 (Fusaka) limits a transaction on
    ///      Ethereum to 2^24 = 16,777,216 gas, and delivering the budget needs `laneGasFor(budget, words, true)` of
    ///      `lzReceive` gas (the budget plus `COMMAND_PRE_CALL_BASE` and `COMMAND_PRE_CALL_PER_WORD` per stored word plus
    ///      the endpoint's lane / 64 hop loss) plus the executor's transaction overhead. At 14,000,000 the largest payload
    ///      (39 words, a 32-vault UPDATE_VAULTS retry) needs `laneGasFor` = about 15.68M and the test requires that plus 1M
    ///      of transaction overhead to stay under the cap (about 0.1M of headroom: 14M is the largest round cap that fits) (pinned by `testShouldKeepTheMaximumBudgetDeliverableUnderTheEthereumTransactionGasCap`). On CCIP
    ///      a manual execution adds about three 63/64 hops (roughly 0.4M of headroom at the cap), moot under the lane's
    ///      FeeQuoter `maxPerMsgGasLimit`; the CCIP executor bounds the STAMPED budget by this cap too. A budget above the
    ///      cap could never be delivered on Ethereum. It stays safe even so: an expired command is NACKed before its
    ///      budget is checked, so an undeliverable command is freed by the manager's CANCEL, never stuck.
    uint256 internal constant MAX_COMMAND_EXECUTION_GAS = 14_000_000;

    /// @notice Gas withheld from the capped self-call that runs a command, so the catch frame can always persist
    ///         FAILED and send a NACK after a callee burned all the gas it was forwarded and reverted with a
    ///         selector or ran out of gas (IL-8625, Ackee TP-L-13).
    /// @dev Without the cap the catch frame keeps only about `G / 64` after such a revert (15.6k at 1M, 62k at 4M),
    ///      below `MIN_NACK_GAS`, and the delivery reverts `InsufficientGasForNack`. Measured in
    ///      `CommandOutOfGasTest` (`testShouldFinishTheCatchPathOnTheReserveAloneAtTheFloor`): on the mocks the catch
    ///      path (status write, receipt send, event) needs between 250,000 (fails) and 260,000 (passes); 400,000 keeps
    ///      about 1.5x headroom for a real endpoint / router send. The bracket was measured with a mock endpoint, a
    ///      callee that burns everything then reverts with a selector, and the constant edited by hand; the mock loop
    ///      stops at ~20k gas left, so the figure is ~20k optimistic. Invariants, asserted in the constants test:
    ///      `COMMAND_CATCH_RESERVE_GAS >= MIN_NACK_GAS` and `COMMAND_CATCH_RESERVE_GAS < COMMAND_EXECUTION_MIN_GAS`
    ///      (the budget is at least the floor and is checked first, so `gasleft() - COMMAND_CATCH_RESERVE_GAS`
    ///      cannot underflow).
    uint256 internal constant COMMAND_CATCH_RESERVE_GAS = 400_000;

    /// @notice Upper bound of the gas forwarded to the `redeem` of the best-effort sweep of a vault removed from the
    ///         allowlist (IL-8784, D-029 / D-060 / D-065).
    /// @dev A safety bound, not a promise. The sweep forwards `min(VAULT_SWEEP_GAS, gasleft() - VAULT_SWEEP_RESERVE_GAS)`,
    ///      so the sweep adds no gas threshold of its own (there is no hard pre-check; its capped reads need about 0.25M) and a
    ///      single removal fits any command budget that carries the UPDATE_VAULTS itself (measured figures: Stargate README). Idle-served
    ///      redeems measured on a mainnet fork (`VaultSweepIdleRedeemForkTest`: 3-market PlasmaVault about 1.40M, 12-market
    ///      MetaMorpho about 0.52M) fit the cap; a position allocated into markets needs more (a cold 100k USDC position
    ///      of the Ethereum TESS USDC Optimiser redeemed at 3.11M uncapped), so the sweep ends as a residual (reason 2,
    ///      or 5 when the command gas was the limit) and the vault is untracked all the same (D-028). That is accepted
    ///      (D-060): ALPHA must redeem or recall a position to zero BEFORE removing a vault, so that only the dust path
    ///      (no `redeem` call, D-061) runs. A CCIP RETRY cannot add gas, which is why the sweep never reverts for lack
    ///      of it. Measured cold over the real CCIP transport on a 3M route (`VaultRemovalDustForkTest`): a 1-wei
    ///      donation 0.98M router gas, a 0.0102 USDC donation 1.34M, an unredeemable 2M USDC position (about 8x the vault's TVL; exercises
    ///      the residual path) 2.78M; all ACKed. Realistic 100k to 200k USDC Prime positions are swept fully at 3M.
    ///      The no-revert guarantee holds for ONE removal per command: on tight lanes send one removal per
    ///      UPDATE_VAULTS and adds in a separate command (after a gas-limited sweep a later vault's reads can fail,
    ///      which is a safe NACK that rolls everything back). On a 3M CCIP lane any failed sweep reports reason 5,
    ///      also a non-gas revert, so monitoring must read `redeemError`.
    ///      On Stargate the re-track reads and writes run before the sweeps (IL-8839). On CCIP the COMMAND_ACK prices
    ///      the tracked set outside the capped self-call, after the sweep: size the route for that valuation, otherwise
    ///      the delivery fails on the OffRamp and needs manual execution with a higher gas limit.
    uint256 internal constant VAULT_SWEEP_GAS = 2_000_000;

    /// @notice Gas withheld from the sweep `redeem` call (per vault): what must remain AFTER it for the post-call
    ///         `balanceOf` reads (each capped at 200,000 plus the pre-check slack), the events and the rest of the
    ///         command (D-065). The reserve is per vault; the guarantee holds for one removal per command.
    /// @dev See VAULT_SWEEP_GAS (IL-8839 order, CCIP COMMAND_ACK valuation).
    uint256 internal constant VAULT_SWEEP_RESERVE_GAS = 300_000;

    /// @notice Smallest gas forwarded to a sweep `redeem`; below it the call is skipped as it cannot succeed
    ///         (an idle-served PlasmaVault redeem measured 0.22M at the low end, D-065).
    uint256 internal constant VAULT_SWEEP_MIN_GAS = 150_000;
}
