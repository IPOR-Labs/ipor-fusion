# Stargate / LayerZero cross-chain transport

## Recall cancellation

Each chain has a single recall slot. `requestAssetsFromDispatcher` takes it and arms the record's
transfer-staleness slot at the same time. The slot is released in three ways:

- by the recall finishing normally (compose plus `RETURN_STARTED`), or by an authenticated
  `RETURN_REJECTED` from the dispatcher (`NO_TRACKED_IDLE`, `BELOW_MINIMUM`, `ABOVE_PATH_CREDIT`);
  a recall above the live Stargate path credit is answered `ABOVE_PATH_CREDIT` before any value moves,
  because `quoteOFT` silently caps the quote at that credit while `sendToken` would revert (IL-8616). The
  Stargate executor decodes the reject reason as a range-checked enum, so a dispatcher that can answer
  `ABOVE_PATH_CREDIT` must be deployed together with an executor that knows it (deploy them as a pair);
- by the permissionless `cancelStaleReturnRequest(chainId)`, once `TRANSFER_STALENESS_MAX` has passed
  and only while neither the `RETURN_STARTED` metadata nor the delivery compose has arrived;
- by the timelocked `scheduleForceResolveTransfer` / `executeForceResolveTransfer` rescue, when value has
  already moved.

Unlike CCIP (`CcipCrosschainExecutor.cancelPendingReturn`, fuse command `CANCEL_RETURN`), there is
deliberately no manager-only cancel that skips the staleness wait:

- A cancel is local only. It does not stop the dispatcher. A delivered `RETURN_ASSETS_REQUEST` still
  executes, and a packet that LayerZero retained after a revert can be re-executed by anyone later. A
  cancel therefore cannot undo a mistaken recall. It only frees the executor's slot while the funds may
  still come back.
- A Stargate recall comes home in two independent legs: the `RETURN_STARTED` LayerZero message and the
  Stargate delivery compose. Either leg can land after a cancel. The executor handles that
  (IL-7966): it re-arms a staleness slot for the cancelled record, or sets `chainBlocked` when the
  per-chain pool is full, and the chain then stays blocked until the record's second leg lands (it lifts
  the block only if nothing else raised it) or the timelocked rescue resolves it (plus a force-set after
  `DROP_RETURN_METADATA_INCLUDED`; IL-8618 / IL-8624, below). The staleness precondition
  keeps this rare. A manager cancel that can fire seconds after the request, while both legs are still
  in flight, would make it routine.

  A permissionless cancel (`cancelStaleReturnRequest`) frees the request slot and the staleness slot, but it keeps a
  per-chain **cancelled-recall clock** armed (IL-8621, extends CCIP IL-8590; CCIP has no approval-clear):
  `cancelledRecallCount[chainId]`,
  `cancelledRecallPendingAt[chainId]` (the OLDEST cancelled request's `createdAt`),
  `cancelledRecallGeneration[chainId]` and `cancelledRecallVersion[chainId]` (the acknowledged dispatcher state
  version at the latest cancel; getter `cancelledRecallClock(chainId)`). While the clock is armed `computeNavSD`
  applies the normal transfer-staleness rule to it and reverts `NavTransferStale`. Because a cancel is only possible
  after the recall is already older than `TRANSFER_STALENESS_MAX`, `getBalance` reverts from the cancel on until the
  clock clears. Why: the dispatcher may have bridged the assets already, while a recent truthful attestation at the
  old version keeps `settled` fresh, so without the clock NAV would price the pre-return amount (overstated by the
  in-flight return) until a leg lands.

  The clock clears (one count per cancelled request; the last one clears `cancelledRecallPendingAt`) when:
  - the first return leg for that request lands (`RETURN_STARTED` metadata or the delivery compose), or the request
    is finalized (`RETURN_REJECTED`, force-resolve). The leg then re-arms a fresh staleness slot as before (IL-7966);
  - an approval is accepted whose `stateVersion` is STRICTLY greater than `cancelledRecallVersion` (versions
    are contiguous; if the advancing message was the recall's own `RETURN_STARTED`, that leg already cleared the
    clock; an attestation at the cancel-time version proves nothing about the recall and does not clear it);
  - `ADVANCE_STATE_FRONTIER` or `forceSetSettled` runs (they reset the chain).

  A reset bumps `cancelledRecallGeneration`; a leg for a request cancelled in an older generation is ignored, so it
  cannot clear a newer clock.

  Known limitation: the version rule cannot tell WHICH value-moving message advanced the frontier. If an unrelated
  `TRANSFER_SETTLED` advances the frontier past the cancel-time version while the recall's own `RETURN_STARTED` is
  still in flight, an approval at that version clears the clock early. The in-flight metadata/compose is still
  applied exactly once afterwards; only the staleness bound of that window is lost. An observation below the debit
  version predates the debit, so `NavSettledStale` closes the window at most `STALENESS_MAX` after the dispatcher
  debit; no double count: the value stays in `settled` and later legs move it between buckets exactly once.

  Liveness: with no value-moving traffic and no legs, NAV stays frozen across the whole vault until the timelocked
  force-set or a per-record `DROP_FROM_NAV` (same as CCIP).
- A return record that owns booked value (`returnInFlight` or `pendingArrivalReserve`) but could not reclaim a
  staleness slot is counted in `noClockReturnCount[chainId]` (IL-8618; getter `noClockReturnCount(chainId)`).
  While the count is non-zero `forceSetSettled` reverts `UnclockedReturnOpen(chainId, count)` (such a record is
  not in `pendingTransferCount`) and `computeNavSD` reverts `ChainBlocked` independently of the `chainBlocked`
  bit. That check blocks the NAV of the whole vault even when `chainTotal == 0`, because the reserve sits outside
  NAV; there is no per-reason bitmask (owner decision: minimal variant). Resolve the record first (late leg, or
  `applyForceResolve`), then force-set if needed.
- The block lifts again (IL-8624, event `NoClockReturnBlockLifted(chainId)`) when the LAST counted record closes
  through `_finalizeReturn` (the late second leg, or `applyForceResolve` `DROP_FROM_NAV` on a metadata-first
  record) and the no-clock site was the one that raised the block (`blockRaisedByNoClockReturn`).
  `DROP_RETURN_METADATA_INCLUDED` does not lift it and needs the force-set. Residuals: a no-clock record whose
  second leg never arrives is released only by `applyForceResolve`, and NAV of the whole vault stays blocked until
  then. A block raised before or during the window for another reason (breaker reject,
  `DROP_RETURN_METADATA_INCLUDED`, rejected-after-value-leg, a frontier repair layered over the no-clock block)
  resets the flag, so after the record is resolved it still needs the timelocked `forceSetSettled`.
- `StargateCrosschainExecutor` has almost no EIP-170 headroom left.

The cost of not having a manager cancel is bounded by `TRANSFER_STALENESS_MAX`, which is 1 hour in the
mainnet configuration. After that window the same pending recall makes NAV revert with
`NavTransferStale`, and the manager, or anyone else, can call `cancelStaleReturnRequest` at once.
The cancel frees the slot for a new recall, but NAV keeps reverting until the cancelled-recall clock clears
(IL-8621).

### Stargate pause during a recall (IL-8616)

`ABOVE_PATH_CREDIT` covers only the path-credit cap. A paused Stargate pool (`status() == 3`, `sendToken`
reverts `Stargate_Paused()`) or a paused FeeLib path (`feeConfigs(eid).paused`, `quoteOFT` reverts
`FeeLib_Paused()`) still makes the dispatcher's `lzReceive` for `RETURN_ASSETS_REQUEST` revert, and LayerZero
retains the packet. The request is not rejected: the executor's recall slot and its staleness clock stay armed, NAV
reverts with `NavTransferStale` after `TRANSFER_STALENESS_MAX`, and after a `cancelStaleReturnRequest` it keeps
reverting on the cancelled-recall clock for the whole pause. We cannot void the retained packet. After the unpause
anyone can re-execute it, and the dispatcher then sends the funds to the cancelled record; the executor credits that
late leg when a slot is free (IL-7966). Accepted as a transient Stargate-side condition (no code change).

- Never use `DROP_FROM_NAV` on a recall stalled by a pause. The replayed send would land as untracked executor
  surplus outside `idleLedger` ("Choosing DROP_FROM_NAV" below) and NAV stays understated by the recalled amount
  until another rescue moves it back.
- Before a recall, check on the dispatcher chain that the pool's `status()` is not paused and that
  `feeConfigs(EXECUTOR_EID).paused` is false on its FeeLib; alert on the Stargate pause events (pool pause and FeeLib
  `PausedSet`).
- During a pause, wait. After the unpause re-execute the retained packet instead of rejecting or dropping the
  record. If a third party cancelled the recall meanwhile, watch for `ReturnAssetsSent` with the same `requestId`
  and confirm the late leg was credited.

## Frontier repair (Stargate)

The dispatcher `stateVersion` counts value-moving transitions only (IL-8257), the same meaning as on CCIP:
it is bumped once per inbound transfer settle (`TRANSFER_SETTLED`) and once per return-started
(`RETURN_STARTED`). Command success, command cancel and vault-config updates do not bump it; their
`COMMAND_ACK` carries the current version as evidence and never touches the frontier, and the executor
decides duplicates and late receipts for it by command id and sequence alone (`_adoptLateReceipt`).
Attestation propose/approve and the force-set binding keep requiring equality with the frontier, so command
traffic neither makes an honest attestation drift nor voids a scheduled force-set; only a value-moving
message does.

`_advanceVersionFrontier` (`StargateExecutorAccountingLib`) classifies every `TRANSFER_SETTLED` and
`RETURN_STARTED` by its `stateVersion` against `acknowledgedRemoteStateVersion`:

- a version at or below the frontier is a duplicate: its accounting is dropped, whatever the message was;
- the next version (frontier + 1) applies and moves the frontier;
- anything higher reverts `StateVersionGap(chainId, expected, got)`. LayerZero retains the packet, so it
  can be re-executed once the gap is closed.

When a response is lost for good, `ADVANCE_STATE_FRONTIER` is the only way to close the gap. It cannot be
undone. Size it by the rule shared with CCIP (`CrosschainConstants`, `ADVANCE_STATE_FRONTIER`): the lowest
version that can still be delivered minus one, never past a retained value-moving response; the dispatcher's
`stateVersion()` alone overshoots whenever LayerZero still holds later responses (IL-8570).

1. Pause the vault for the whole repair, as for a force-set (IL-8456). A value-moving response
   (`TRANSFER_SETTLED`, `RETURN_STARTED`) that lands in the window moves the frontier and can void the
   scheduled repair; command ACKs no longer do (IL-8257).
2. Find the lost versions. Read the dispatcher's events (`InboundTransferSettled` carries its version,
   `ReturnAssetsSent` does not: read its version from the LayerZero packet payload; `CommandSucceeded` and
   `VaultsUpdated` carry the current version as evidence but do not bump it), scan LayerZero for the
   packets of the dispatcher's path, and list which of them the endpoint still holds as undelivered.
   Do not take the dispatcher's `stateVersion()` as the target: it is the version of the latest
   value-moving response it sent, and later responses that LayerZero still retains sit above the gap.
3. Size `newVersion` = (lowest version that is still deliverable) - 1. Never advance to or past a retained
   `RETURN_STARTED` or `TRANSFER_SETTLED`. Such a packet becomes a dropped duplicate, and its
   accounting is lost: a settlement never leaves `outboundInFlight` (the next attestation then counts it twice,
   NAV = S + 2A, see "Lost TRANSFER_SETTLED" below), a recall's remote debit is never
   applied and its tokens land in `pendingArrivalReserve` (outside NAV) with the staleness slot re-armed.
   NAV then stays wrong until a further rescue
   (`DROP_RETURN_METADATA_INCLUDED` plus a force-set). One repair may skip at most `MAX_FRONTIER_JUMP`
   versions.
4. Schedule `scheduleForceResolveTransfer(bytes32((chainId << 64) | newVersion), ADVANCE_STATE_FRONTIER)`
   and execute it after `FRONTIER_REPAIR_DELAY`. The frontier moves, the chain is `chainBlocked` and
   `frontierRepairPending(chainId)` is `true`.
5. Retry the retained packets in version order (`lzReceive` retry on the endpoint). Watch for
   `AuthenticatedMessageDroppedAheadOfFrontier(srcChainId, msgType, recordId, stateVersion, frontier)`: it
   fires when an authenticated message with a still-open record was dropped, so it means the target was
   too high. Repair it with the recall rescue below, or the matching force-resolve for the record.
6. The chain stays blocked until the next approved attestation lifts the block
   (`ChainUnblockedByApproval`; the latch `frontierRepairPending` is consumed there). A settled force-set
   also clears both the block and the latch.

   The repair arms `frontierRepairPending` only when it owns the block: the chain was not blocked before, or was
   blocked only by an earlier repair (IL-8620). A repair run over a foreign block (breaker reject, no-slot return
   block, drop) leaves the latch off, so an ordinary approval cannot lift that older block; its exit stays the
   timelocked `forceSetSettled`. A repair layered over a no-clock return block also resets
   `blockRaisedByNoClockReturn`, so finalizing the record later does not lift the block.

### Lost recall metadata (`RETURN_STARTED` lost for good)

The compose-first recall rescue is `DROP_RETURN_METADATA_INCLUDED` followed by `forceSetSettled` at the
current frontier (`CrosschainRecallSafetyTest.testComposeFirstWithLostMetadataCanBeReconciledAndClaimed`).
It fits metadata that is merely LATE. If the `RETURN_STARTED` is lost for good and the dispatcher has sent
later responses, those revert `StateVersionGap` until the frontier is advanced, and the rescue pair alone
does not open the lane. Use this order:

1. `ADVANCE_STATE_FRONTIER` to just below the lost `RETURN_STARTED` version (rule above), and wait for
   `FRONTIER_REPAIR_DELAY`.
2. Let the retained later packets replay in version order.
3. Read the dispatcher's balance at the new frontier, then schedule `DROP_RETURN_METADATA_INCLUDED` for the
   recall together with
   `scheduleForceSetSettledBalance(chainId, value, observedStateVersion, observedRemoteTimestamp, false)`, where
   `observedStateVersion` is the new `acknowledgedRemoteStateVersion` and `value` already excludes the
   recall's debit. Execute both after `RESCUE_DELAY`.
4. No separate attestation is needed: the force-set clears `chainBlocked` and `frontierRepairPending`.
   Idle is credited with the compose amount, the reserve is released and the chain prices again.

Pinned by `CrosschainRecallSafetyTest` (`testShouldRecoverLostReturnMetadataByAdvancingThenComposeFirstRescue`,
`testShouldApplyRetainedReturnStartedWhenFrontierAdvancedToJustBelowIt`,
`testShouldDropRetainedReturnStartedWhenFrontierAdvancedPastIt`).

### Compose-first return: NAV overstated by the bridge fee (TP-L-19 / IL-8647)

When the Stargate delivery compose arrives before the `RETURN_STARTED` metadata, the delivered amount sits in
`pendingArrivalReserve` (outside NAV) while `settledRemoteBalance` still counts the FULL recalled amount (the remote
debit is applied only by the metadata). The Stargate bridge charges its lane fee out of the transferred amount, so the
delivered amount is smaller than the recalled one. Until the metadata lands and reconciles, NAV is therefore
overstated by exactly the realised bridge fee of that return.

Accepted as a fee-sized transient (owner decision). Size: bounded by the lane's fee on the recalled amount. Window:
until `RETURN_STARTED` lands; the record's staleness slot bounds it, so `getBalance` reverts `NavTransferStale` once
`TRANSFER_STALENESS_MAX` has passed. No operator action is required; a metadata that never lands follows "Lost recall
metadata" above.

### Lost TRANSFER_SETTLED (TP-M-36, IL-8614)

The frontier repair skips the lost response but cannot touch the outbound record whose `TRANSFER_SETTLED` it was. The
record keeps the amount `A` in `outboundInFlight`, while the next attestation, read at the repaired frontier, already
contains the delivered `A` and writes `settled = S + A`: NAV = `S + 2A` (measured 120e6 against a true 110e6).

The repair itself is allowed (it is the only exit from a stuck frontier). Instead `approveBalance` reverts
`FrontierRepairBlockedByOpenTransfers(chainId, outboundInFlight)` while `frontierRepairPending(chainId)` is `true`
and `outboundInFlight(chainId) != 0`. The guard reads `outboundInFlight`, not the pending-slot count, because recall
records are legitimately open during the lost-recall-metadata repair above and are not the cause. Procedure:

1. Run the frontier repair as above. The chain is blocked and the latch is armed.
2. If the lost message was a different one and the transfer's `TRANSFER_SETTLED` is merely retained, let it replay in
   version order: the record closes and `settled` carries `A`.
3. If the `TRANSFER_SETTLED` is truly lost, establish on the remote chain whether the dispatcher credited the
   transfer and force-resolve the record: `DELIVERED_TO_SETTLED` if it did, `DROP_FROM_NAV` if it has not arrived
   (if it arrives later, its settlement is credited once, see the next section).
   Wait `RESCUE_DELAY` and execute.
4. Attest the dispatcher balance read at the repaired frontier. NAV equals the true remote balance.

The other exits from the latch stay guarded: a settled force-set needs `pendingTransferCount == 0`, and
`rejectAndBlockProposal` clears the latch but leaves the chain blocked (the exit is then the timelocked force-set).

Pinned by `StargateFrontierRepairOpenOutboundTest`.

### Late settlement after DROP_FROM_NAV (IL-8619)

The outbound record carries `forceResolved` and `remoteCreditAccounted`. A `TRANSFER_SETTLED` for a `DROP_FROM_NAV`
record with a matching guid is credited exactly once: `min(amountReceivedSD, amountSD)` is added to
`settledRemoteBalance` and to the anchor (`LateSettlementCredited(srcChainId, transferId, amountSD, credited,
stateVersion)`), so NAV equals the true remote balance again without a timelocked force-set.

The credit is never skipped, also after the frontier-repair latch-clearing approval or a force-set (IL-8619 review:
skipping it there left NAV understated by `A`). Both writes are bound to the executor's frontier, and a settlement
reaches this path only at frontier + 1 (a lower version is dropped earlier as a duplicate), so a write made before it
was read under a lower version and cannot contain `A`. Never add an in-transit amount to a force-set: it would be
counted again when its settlement arrives. A duplicate settlement, a `DELIVERED_TO_SETTLED` record (credit booked by
the rescue) and a guid mismatch only consume the state version (`TransferSettlementConsumedWithoutAccounting`).
`LateSettlementAlreadyAttested` stays in the ABI but is no longer emitted on Stargate.

Residual: an attestation or force-set whose balance was read at a higher dispatcher version than it declares (attester
or admin misconduct against the runbook) double counts the late settlement.

Deployment note (IL-8619): re-link `StargateExecutorAccountingLib` and `StargateExecutorAttestationLib` and update
their pinned addresses in the `crosschain_deploy` `libraries` of `foundry.toml`. `OutboundRecord` and
`StargateExecutorState` changed (`forceResolved`, `remoteCreditAccounted`; `repairSettleSeq` / `resolveRepairSeq` are
kept for the layout but unused since the IL-8619 review), so the executor needs new creation code; the
factory's `configureCreationCodes` is one-shot, so a factory that is already configured needs a new factory.

Pinned by `StargateLateSettlementCreditTest`.

### Residue after a short return (TP-M-07, IL-8585)

The return leg debits `settled` by the amount the dispatcher declared in `RETURN_STARTED` and the anchor pro rata.
The dispatcher pays every recall out of `trackedIdle` only, never out of the tracked ERC-4626 positions, so any
return smaller than the attested bucket (a partial recall, or a full recall while part of the bucket sits in a
vault) leaves a pro-rata residue that still carries the whole remote loss the attesters had not yet recognised.
Once that loss exceeds `ATTESTATION_ANCHOR_BAND_BPS` (20%) of the residue, the residue cannot be attested down to
its true value: `approve` holds every value within the band of the anchor, and the exact-zero exception applies
only at or below `ATTESTATION_ZERO_DUST_SD`. Example: `settled == anchor == 1,000,000`, 900,000 is idle and
100,000 sits in a vault that lost all of it; a full recall returns the 900,000 and leaves 100,000 against a true
value of 0, and the band floor is 80,000. The recall creates no value; the overstatement equals the loss that was
already unrecognised before it (10% of the bucket before, 100% of the residue after).

1. Just before recalling, attest a fresh observation so every known remote loss is recognised. A recognised loss
   is already out of `settled`, so the recall debits only value that exists and the residue stays correct. A
   loss larger than one `bigChangeBps` step needs several approvals spaced by `MIN_UPDATE_INTERVAL`; a loss
   beyond the band needs the force-set below before the recall.
2. After a return shorter than the bucket, read the dispatcher's balance at
   `acknowledgedRemoteStateVersion(chainId)` and compare it with `settled`. Inside the band, attest normally.
   Below the band floor (and above `ATTESTATION_ZERO_DUST_SD`), block immediately (`rejectAndBlockProposal`; the
   proposer submits the truthful figure, `propose` has no band check) instead of waiting for `STALENESS_MAX` to
   fail NAV closed. The block makes `getBalance()` revert, so the NAV pre-hook closes deposits and withdrawals of
   the whole vault until the force-set executes.
3. Schedule `scheduleForceSetSettledBalance(chainId, value, observedStateVersion, observedRemoteTimestamp, false)`
   with the true value read at `acknowledgedRemoteStateVersion(chainId)` (and its remote read time), and execute
   `executeForceSetSettledBalance` after `RESCUE_DELAY`.
   Pause the vault for the force-set window: manager-triggered value-moving traffic (outbound transfers,
   recalls) voids a scheduled force-set; command ACKs do not (IL-8257).

### Choosing DROP_FROM_NAV (IL-8560)

`DROP_FROM_NAV` drops value from NAV without proof that it never arrived, so a late leg is not reconciled:

- A stuck return on which neither leg has arrived yet but may still arrive (stale past `TRANSFER_STALENESS_MAX`):
  prefer the permissionless `cancelStaleReturnRequest`, which keeps the record able to accept late legs.
- An outbound dropped by `DROP_FROM_NAV` whose `TRANSFER_SETTLED` later arrives is credited once (IL-8619, see
  "Late settlement after DROP_FROM_NAV" above), so the dropped credit no longer needs the timelocked force-set.
  A duplicate, a `DELIVERED_TO_SETTLED` record or a guid mismatch only consume the state version
  (`TransferSettlementConsumedWithoutAccounting`).
- A return dropped by `DROP_FROM_NAV` whose legs arrive late leaves the tokens as untracked executor surplus
  (outside `idleLedger` and `pendingArrivalReserve`); NAV stays understated until a generic rescue `ASSET.transfer`
  moves the surplus back (e.g. straight to the PlasmaVault, `MANAGER`).

### Anchor credit cap and band limitation (TP-H-02 / IL-8578, FP-H-01 / IL-8554)

Anchor credit cap (TP-H-02, IL-8578). Each chain keeps a `netPrincipal` (credits from authenticated settles, debited
by the authenticated amount the dispatcher sent back on each recall, floored at 0, rebased by `forceSetSettled`;
only authenticated returns lower it and the attesters never raise it; they can only zero it together with the anchor through the dust-to-zero approval). A credit on
re-supply sets the anchor to `max(min(anchor + credited, netPrincipal), floor)` (it may lower it), where
`floor = ceil(settledAfter * 10_000 / 12_000)` is the band-consistency floor, so a recall / re-supply round
trip cannot add band headroom without new capital. The "never exceeds the largest net principal" claim holds up
to one shared-decimal unit of `Ceil` rounding per credit (a cycle costs two bridge round trips and an
attestation to gain one unit, so it is not economically exploitable). Known limitation: a realised loss stays in
`netPrincipal` after the bucket is emptied (supply 100, attest 90, recall 90 leaves 10); it is bounded by real
losses and clears on `forceSetSettled`.

Honest-yield consequence: after a recall that leaves already-recognised yield on the remote chain, the next
credit sets the anchor at the band floor, so `settled` then sits at the band ceiling and further honest yield
cannot be attested until a `forceSetSettled` rebase. Runbook rule: recall the whole attested bucket (or
force-set) rather than only the principal; a recognised-yield residue topped up afterwards sits at the band
ceiling until a force-set.

Settled below the anchor band (IL-8737 / IL-8792). The relative `BigChangeExceeded` check applies only while the current settled lies inside the
anchor band (outside the band on either side skips it; only below is reachable). After an approved loss and a recovery, a full recall leaves (settled 0, anchor R, net N) with N > 0 (the approved loss stays in netPrincipal). A later
top-up c then gives (c, min(R, N) + c). When `c * (1 + bigChangeBps / 10_000) < 0.8 * (min(R, N) + c)` (for example
`c < 2 * min(R, N)` at 20%, `c < 8/3 * min(R, N)` at 10%), settled is below the band and the two windows are disjoint,
so before this fix no value was approvable at all and NAV stayed fail-closed after `STALENESS_MAX`. Such a
settled is not a baseline, like zero (IL-8606), so the band alone bounds that one approval (at most `1.2 * anchor`; the
anchor grows only from authenticated credits, IL-8578). The relative check returns after the first band approval.
Example (`bigChangeBps` 10%): (0, R = 8, N = 10) plus a top-up of 5 gives (5, 13), window [4.5; 5.5] against band [10.4; 15.6]; after the fix approving 13 passes. Executors deployed before this change keep the old behaviour; for them
attest the residual before any top-up (see the IL-8606 section below). Once frozen, recall the whole settled bucket or force-set.

Known limitation (FP-H-01, IL-8554): the band bounds the LEVEL of mispricing (+-20% of the anchor), not the
cumulative movement; a jointly compromised proposer/approver pair can walk `settled` between the band edges
repeatedly (about 9 approvals per full 0.8x -> 1.2x -> 0.8x cycle: 5 up, 4 down, at the reference
`bigChangeBps` of 1_000; 3 + 2 at 2_000). Accepted by design (it needs both attester keys); mitigation is
off-chain monitoring of `BalanceApproved` direction reversals.

Residual anchor after a full recall (TP-M-28, IL-8606). Same failure and fix as on CCIP, but the Stargate
`RETURN_STARTED` message did not carry a balance. It now has a trailing field `remoteBalanceSD`: the dispatcher's
post-debit balance (tracked idle plus every PRICED tracked vault, priced by `TrackedVaultPricingLib` with the on-chain
budget `VAULT_READ_GAS`; a vault priced in `observation()` can count as 0 there). An unpriced vault, or one whose value
is absurd (above `type(uint128).max`), counts as zero, so the figure can only understate and one faulty vault can
neither overflow the sum nor revert the recall. When a return empties `settled` while `remoteBalanceSD >
ATTESTATION_ZERO_DUST_SD`, `_applyReturnDebit` keeps `anchorPrincipal` at that residual (the late-metadata debit path
included). `settled` is not credited; an ordinary attestation prices the residual inside the anchor band;
`StargateExecutorAttestationLib.approve` keys the zero-baseline rule on the anchor (positive attestation from `settled
== 0` needs `anchorPrincipal != 0` and the band; zero-to-zero is unchanged; dust residual still zeroes the anchor).

The residual is NOT recallable until it is attested (recall bounds use `settled`), so the order of operations matters.
Attest the residual before re-supplying: a credit that lands before the attestation caps the anchor at the credited
amount (`min(R + D, netPrincipal = D)`, see the anchor credit cap above), which drops the residual out of the band
(covered by `testCreditBeforeResidualAttestationShouldCapTheAnchorAtTheCredit`). The first attestation from the zero
baseline is bounded only by the anchor band, the relative limiter being skipped at a zero baseline, so a single step can
move `settled` from 0 to 1.2 R. The residual anchor is capped at the pre-debit anchor: an honest residual (yield since
the last attestation) never exceeds it, so a reported figure above it cannot raise the anchor, which stays
non-increasing under debits. Until the residual is attested NAV excludes it (it understates, never overstates), and a
zero attestation is allowed, so a lost residual needs no special exit; `rejectAndBlockProposal` plus the timelocked
force-set (`scheduleForceSetSettledBalance`) is only needed to price a residual that has fallen out of the band.

Deployment note. `ReturnStarted` gained one `uint256` (wire change), but `CODEC_VERSION` stayed 3 at that point (IL-8625 bumped it to 4). Creation codes are
one-shot per factory and must come from one build, so dispatcher and executor creation codes of one deployment must be
built together, not merely redeployed together; and the executor must be re-linked to the new
`StargateExecutorAccountingLib` and `StargateExecutorAttestationLib`. Mismatch behaviour: an old executor receiving from
a new dispatcher ignores the trailing word and behaves as before; a new executor receiving from an old dispatcher
reverts in `abi.decode` inside `lzReceive`, so `RETURN_STARTED` is retained and needs the lost-recall-metadata repair.
Recall gas headroom: the recall now prices every tracked vault inside `lzReceive` (up to three capped reads per
held vault (balanceOf, asset, convertToAssets), about 208k for the pre-check), so the recall path can hit
`InsufficientGasForVaultRead` and the permissionless retry must carry more gas. The command-lane minimum is 2,500,000
(`StargateExecutorDeploymentLib.COMMAND_LANE_MIN_RECEIVE_GAS`, IL-8625): the smallest lane that still yields the
`COMMAND_EXECUTION_MIN_GAS` (1,000,000) budget for the largest payload, a 32-vault `UPDATE_VAULTS` (39 stored words,
about 2.47M by the formula in "Command gas budget" below). A lane below it, 2,000,000 included, is refused at registration.
It is a protocol minimum, not a sizing recommendation: size the lane to the heaviest allowed action ("Lane sizing" below),
or top a single command up. A delivery that reaches the budget check with less gas than the command's budget reverts
`InsufficientGasForCommand`: the whole delivery reverts, including state writes, so the packet stays retryable.

### Pricing window between propose and approve (TP-H-01 / IL-8577, TP-M-18 / IL-8596)

A positive `BalanceProposed` is public, but the live executor balance, the vault's cached NAV and the crosschain
pre-hook change only when the proposal is approved and the CROSSCHAIN market is refreshed. A depositor who enters
after the proposal and before the approval pays the old share price and captures part of the attested remote yield
once approve and refresh land (and the converse for an exit ahead of a negative proposal). This is inherent to a
cached, discretely attested NAV and is bounded to one attestation step (at most `STALENESS_MAX` of yield,
further capped by the per-approval relative limiter and the anchor band). Accepted by design: no hook blocks
share-price operations while a proposal is pending, because it would only narrow the window and would fail-close
user operations. Operational rule for the attester pair: submit propose + approve + `updateMarketsBalances`
(`[CROSSCHAIN]`) back-to-back in one block through a private submission channel, keep the attestation cadence well
below `STALENESS_MAX`, and rely on deposit/withdraw fees where remote yield is lumpy.

### Outbound send and rejected recall keep a pending proposal (TP-M-44 / IL-8622)

An outbound `sendAssetToDispatcher` and a `RETURN_REJECTED` no longer bump the chain's accounting epoch, so a pending
balance proposal stays approvable across them. A send only moves value from idle to `outboundInFlight` on the
executor (the attested dispatcher balance is unchanged until the transfer lands), and a rejected return moves no value
on either side (IL-8257). The epoch still advances where attested value lands or is re-attributed:
`TRANSFER_SETTLED` (including a late credit), return metadata/compose legs (not a compose-first leg of a record that
still holds its staleness slot: it only books `pendingArrivalReserve`), command ACK, late-receipt adoption,
abandon, stale-recall cancel, force-set, force-resolve, frontier repair and lane realign. The acknowledged state
version advances only on `TRANSFER_SETTLED`, `RETURN_STARTED` and `ADVANCE_STATE_FRONTIER`. Approval additionally
rejects a proposal whose `stateVersion` no longer equals the acknowledged frontier (`ProposalVersionMismatch`).
Consequence: the ALPHA role can no longer void a pending proposal with a cheap one-unit send to starve
`approveBalance` and drive `computeNavSD` into `NavSettledStale`. Under the frontier-repair latch an outbound still in
flight blocks the latch-clearing approval (`FrontierRepairBlockedByOpenTransfers`, IL-8614) until it settles or is
force-resolved.

### Approval freshness window and monotonic observation clock (IL-8631 / TP-L-03, IL-8648 / TP-L-20)

`approveBalance` applies two extra gates, identically on the Stargate and CCIP executors (after the existing
`ObservationStale` check):

- `ObservationTooCloseToStale(chainId, remoteTimestamp)`: reverts unless
  `remoteTimestamp + stalenessMax >= block.timestamp + minUpdateInterval`. The next approval is rate-limited for
  `minUpdateInterval` from this one, so the observation must stay fresh at least that long; otherwise NAV of a
  chain with a non-zero settled bucket would revert (`NavSettledStale` / `ObservationStale`) until the limiter
  opens. It applies to the first approval and to the repair-latch approval too (both are followed by a
  rate-limited approval). The constructor already guarantees `minUpdateInterval < stalenessMax`, so a fresh
  observation always passes. A proposal that sits so long that it falls below this margin can no longer be
  approved; propose a new one.
- `ObservationOlderThanApproved(chainId, remoteTimestamp, lastApprovedObservedAt)` (IL-8648): the freshness clock
  `lastApprovedObservedAt` is monotonic across ordinary approvals; a force-set re-stamps it with its committed
  observation time, which may be earlier (see "Force-set observation timestamp" below). An ordinary observation older
  than the last approved one is rejected (equal is accepted) instead of rolling the clock back. `forceSetSettled`
  also bumps the accounting epoch, which voids any older pending proposal.

Deployment rule: choose `stalenessMax - minUpdateInterval >= observation lag + approval latency` (at least the
15-minute `MIN_PROPOSAL_APPROVAL_WINDOW`), because an observation is approvable only while its age is at most
`stalenessMax - minUpdateInterval`; the constructors guarantee only that the difference is positive.

### Force-set observation timestamp (IL-8646 / TP-L-18)

`forceSetSettled` no longer stamps the EXECUTE time into `lastApprovedObservedAt` (the clock `computeNavSD` /
`getBalance` measure NAV freshness against). The remote observation time of the figure is part of the schedule-time
commitment and is what gets stamped, exactly like an ordinary approval (which stamps the proposer-supplied remote
timestamp). `lastApprovalAt` (the local rate-limit marker) still takes the execute time.

- `scheduleForceSetSettledBalance(chainId, newSettledLD, observedStateVersion, observedRemoteTimestamp,
  allowOlderThanApproved)` and `executeForceSetSettledBalance(rescueId, chainId, newSettledLD, observedStateVersion,
  observedRemoteTimestamp, allowOlderThanApproved)`. The commitment is `keccak256(abi.encode("SETTLED", chainId,
  newSettledLD, observedStateVersion, observedRemoteTimestamp, allowOlderThanApproved))`, so the flag is chosen at
  schedule time, visible to the guardian, and a strict schedule cannot be executed with `true` or vice versa
  (`ForceResolveCommitmentMismatch`). Pass `false` unless the opt-out below is intended.
- Schedule reverts `ObservationStale(chainId)` unless `0 < observedRemoteTimestamp <= block.timestamp` and
  `block.timestamp - observedRemoteTimestamp <= STALENESS_MAX`.
- Staleness after execute (intended, conservative): the figure ages while it waits out `RESCUE_DELAY`. NAV is stale
  right after execute exactly when `executeTime - observedRemoteTimestamp > STALENESS_MAX` (`NavSettledStale`). An
  observation older than `STALENESS_MAX - RESCUE_DELAY` at schedule is sufficient but not necessary (a late execution
  also ages it), and every force-set is stale on execute when `RESCUE_DELAY >= STALENESS_MAX`. The settled bucket,
  anchor and net principal are still rebased and the block is lifted. Take the observation as late as possible before
  scheduling.
- Cost: when NAV is stale on execute it stays stale for at least `MIN_UPDATE_INTERVAL` (`lastApprovalAt` takes the
  execute time). If production `STALENESS_MAX <= RESCUE_DELAY`, every force-set is stale on execute, so the runbook
  plans an ordinary attestation right after it.
- Short remaining freshness (IL-8631 R1): nothing at execute checks how much freshness the committed observation has
  left. If it is still fresh at execute but has less than `MIN_UPDATE_INTERVAL` left, NAV reverts (`NavSettledStale`)
  from `observedRemoteTimestamp + STALENESS_MAX` until `execute + MIN_UPDATE_INTERVAL`, because the limiter runs from
  the execute time and rejects even a fully fresh replacement (`MinUpdateIntervalNotMet`). A gate at execute would be
  the wrong fix (the force-set is the last-resort path and must not refuse). Procedure:
  - at schedule, check `observedRemoteTimestamp + STALENESS_MAX - (scheduleTime + RESCUE_DELAY) >= MIN_UPDATE_INTERVAL`;
    if not, plan the ordinary attestation as a fixed step after execute;
  - before unpausing, compute `lastApprovedObservedAt(chainId) + STALENESS_MAX - now`; if it is below
    `MIN_UPDATE_INTERVAL` or negative, keep the vault paused until the first ordinary attestation, possible from
    `execute + MIN_UPDATE_INTERVAL`.
- The clock can move backwards only with `allowOlderThanApproved = true` (IL-8648 R1). With `false` the force-set
  mirrors the ordinary approve gate: at execute, right before the rebase, it reverts
  `ForceSetOlderThanApproved(chainId, committedObservedAt, lastApprovedObservedAt)` (`CrosschainErrors`) when an
  ordinary approval with a newer observation landed during the rescue delay (equal passes; a chain with no approval
  yet, `lastApprovedObservedAt == 0`, passes). The settled figure and the clock are then kept, and the admin
  reschedules from a fresh read (`>= lastApprovedObservedAt`). With `true` the older committed time is re-stamped (the
  clock ends earlier than before: more conservative, but the fresher attested figure is overwritten). Why an opt-out
  and not a hard gate: the attester pair can approve on a blocked chain, so a hostile pair could approve a fresh
  in-band observation in every rescue window and deny the last-resort path forever; with the opt-out the admin
  schedules with `true` from the start, and because the flag is part of the commitment the guardian sees the choice
  in the schedule calldata and can veto it. Runbook: before execute, still compare the committed time with
  `lastApprovedObservedAt(chainId)` and `cancelRescue` if an approval landed and the figure should be re-read; this is
  now enforced by default (the strict force-set refuses), the comparison only tells you early.
  Honest attesters block it too (IL-8648 review): `propose`/`approve` do not check `chainBlocked`, so a keeper that keeps
  its normal cadence during `RESCUE_DELAY` makes every strict force-set revert, and each failed attempt keeps NAV
  closed for another delay. Halt ordinary attestation for the chain during the rescue window, or schedule with
  `allowOlderThanApproved = true` when that is not possible. A strict schedule whose committed time is already older than `lastApprovedObservedAt` is
  certain to fail at execute (an approval that predates the schedule refuses it too): re-read before scheduling. A
  refused strict rescue stays SCHEDULED (the revert undoes the consume), holds a `MAX_PENDING_RESCUES` slot and would
  become executable if a force-set with `true` later lowered the clock: `cancelRescue` it. Off-chain guardian decoders
  must decode the new flag.
- Interplay: the IL-8648 check `ObservationOlderThanApproved` compares against `lastApprovedObservedAt`; after a
  force-set that value is the committed remote timestamp, so the next ordinary observation must be `>=` it. The
  force-set itself is held to the same rule by `ForceSetOlderThanApproved` unless `allowOlderThanApproved` is `true`.
  The IL-8631
  check `ObservationTooCloseToStale` is unchanged. A force-set no longer affects the IL-8619 late credit (always
  credited once on Stargate); the IL-8614 repair latch is unchanged.
- `SettledBalanceForceSet` carries no timestamp (event signature unchanged on purpose): monitors read
  `lastApprovedObservedAt(chainId)` or decode the schedule calldata.

### Performance fees while an executor is fail-closed (TP-M-21 / IL-8599)

`CrosschainNavValidationPreHook` gates `deposit`, `mint`, `withdraw`, `redeem` and the other share-pricing selectors
on every granted executor's `getBalance()`, which reverts when the attestation is stale, a chain is blocked or an
in-flight record is too old. It deliberately returns early for `execute` (fuse-level action gating keeps recovery
callable) and `updateMarketsBalances` (the refresh must keep working for the other markets). Neither selector is
gated against fee realisation. Both can run `_addPerformanceFee` after refreshing an unrelated market. While an
executor is fail-closed, its cached market value may overstate the real remote value (an unattested remote loss),
so an ordinary authorised refresh can lift the cached aggregate above the high-water mark and mint performance-fee
shares although the true NAV is still below it. The high-water mark is then ratcheted to the inflated value.

Accepted as a known limitation (low severity): it needs an unattested remote loss plus a high-water-mark crossing
caused by unrelated gains, the damage is bounded by `performanceFee x phantom delta`, and it is a generic property
of Fusion's cached NAV, not a bypass specific to the crosschain layer. Operational rule: do not realise
performance fees (a fee-bearing `execute` or `updateMarketsBalances`) while any granted crosschain executor's
`getBalance()` reverts. Clear the fail-closed condition first (fresh attestation, frontier repair, or the
force-set path), then refresh. A vault-side fix would skip `_addPerformanceFee` and the high-water-mark update in a
transaction in which an executor read reverted, using a transient "NAV unverified" flag set by the hook; that
belongs to the PlasmaVault core and is out of scope for the crosschain layer. Same family as the pricing window
above (IL-8577, IL-8596): a cached NAV that is correct only after the next attestation and refresh.

### Share views are not gated while the NAV gate is closed (TP-L-11 / IL-8639)

The fail-closed gate lives only in `CrosschainNavValidationPreHook.run()`, which guards the state-changing selectors
through `PlasmaVault._checkCanCall`. `maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem`, `preview*` and
`convertTo*` are not gated: while an executor is fail-closed they keep returning values priced from the cached NAV,
although EIP-4626 integrators would expect `max*` to return 0 during a halt. The `max*` semantics of PlasmaVault are
intentionally unchanged (owner decision): a user operation attempted in that state reverts in the hook.

For integrators and monitoring the hook offers a non-reverting best-effort probe
`CrosschainNavValidationPreHook.isNavHealthy(plasmaVault)`. It returns false when the hook's `run()` would revert for
a gated selector: a granted executor whose `getBalance()` reverts, a malformed substrate, an executor without code or
with a different `MANAGER`, or an unreadable substrate list; it returns true when no executor is granted. It is not a
security control (the answer can change within a block). Check it before quoting `max*` or `preview*` values to users.

### Cached-NAV fallback and recovery-marked commands (TP-M-33 / IL-8611, TP-M-34 / IL-8612)

Cached-NAV fallback with several executors (TP-M-33, IL-8611). The balance fuse used to serve the recovery fallback
only when exactly one executor was granted to the market, because the cached value is one market-wide aggregate that
cannot be decomposed per executor. With two executors any stale or blocked getter therefore made the mandatory
post-execute market refresh revert and rolled back the very claim / recall / retry / cancel that repairs it. Both
executors expose `getBalanceUnchecked()`: the booked balance (`idle + sum(settled + in-flight buckets)`) WITHOUT the
staleness reverts of `getBalance()`. With several executors in the market the fuse substitutes, for the executor that
is recovery-marked in this transaction (`CrosschainRecoveryLib.isRecovery(market, executor)`) AND whose `getBalance()`
reverted with a STALENESS selector (`NavSettledStale`, `NavTransferStale`), that executor's own
`getBalanceUnchecked()`; every sibling is still read with `getBalance()` and keeps its own verdict (an unmarked
fail-closed sibling still reverts), and the market cache is not used. `CrosschainUncheckedBalanceServed(marketId,
executor, reason)` is emitted. A market with a single executor behaves as before (cache fallback with the
recovered-USD correction, `CrosschainCachedBalanceServed`, `ChainBlocked` included). Only one executor can be marked
per transaction.

A blocked chain is NOT substituted (follow-up to IL-8611, TP-M-33 review). A blocked chain means the books are
known-inconsistent until a rescue completes. The Stargate example is `DROP_RETURN_METADATA_INCLUDED` (compose arrived,
`RETURN_STARTED` lost): the rescue moves the returned amount into `idleLedger` while `settledRemoteBalance` still
holds it, and only `chainBlocked` keeps NAV from counting it twice until the force-set. Serving the unchecked value
there would count the return twice and persist the phantom value as the market's NAV (and mint performance-fee shares
on it). So a `ChainBlocked` reason from the marked executor is rethrown, and `getBalanceUnchecked()` itself reverts
`ChainBlocked` exactly where `getBalance()` does: a blocked chain that still tracks value (`settled + outbound +
return != 0`; an empty blocked chain adds nothing, IL-8260), or a return record without a staleness slot
(`noClockReturnCount != 0`) (a staleness selector can surface first). Known limitation: in a multi-executor market,
batches that read a market whose executor has a blocked chain with value stay blocked until the rescue / force-set
completes. The unchecked value may still be stale for the staleness case; it is the state the fail-closed gate refused
to price, it is never used to size a new deposit (a DEPOSIT batch is `markNewExposure`-gated and cannot be
recovery-marked), and it contains no value a blocked chain double books. Recommended layout: one transport per market,
with a multi-market NAV hook, so a blocked chain on one transport does not hold the other transport's market. Against
pre-IL-8611 executors (no `getBalanceUnchecked`) multi-executor recovery batches still revert.

Operational rule for write-offs (documented risk, the fuses do not police grant / revoke consequences). In a
multi-executor market, FUSE_MANAGER can write an executor off (re-granting only the sibling) and later re-grant it
while it is still stale; a recovery batch then restores it at its stale booked value through `getBalanceUnchecked()`
(market 0 -> 60 and NAV 900 -> 1000 in the review PoC, whereas a single-executor market stays clamped by its zero
cache). Never re-grant a written-off executor in a multi-executor market before its `getBalance()` is live (a fresh
approved attestation). The unchecked value can carry value no live read priced, bounded only by the last approved
observation.

The fail-closed selectors on Stargate are `ChainBlocked`, `NavSettledStale` and `NavTransferStale`; anything else is
rethrown. In a multi-executor market `ChainBlocked` is rethrown too, and only the two staleness selectors are
substituted.

Diagnostic commands are recovery-marked (TP-M-34, IL-8612). `CANCEL_DISPATCHER_REQUEST` cancels a pending deployment
request, moves no value and is recovery-marked, so it works while NAV is fail-closed. `REGISTER_CHAIN`,
`CREATE_DISPATCHER` and `UPDATE_PLASMA_VAULTS` stay blocked. Same trade-off as on CCIP: each recovery-marked command
widens the surface on which the fallback can be served.

Consequences: the recovery marker is reachable at will (on CCIP via `REFRESH_BALANCE`, bounded only by its 10-minute
request cooldown; on Stargate via `CANCEL_DISPATCHER_REQUEST`), so the cached / unchecked fallback can be reached during
any fail-closed window, not only inside a claim / recall repair. A batch carrying REFRESH_BALANCE or
CANCEL_DISPATCHER_REQUEST cannot also hold a DEPOSIT or a supply (`RecoveryExposureBatchForbidden`).

### What a generic rescue may not target (IL-8555 / IL-8556 / IL-8763 / IL-8770)

`scheduleRescue` (queue shared by the executor and dispatcher, and also hosted by the Stargate factory; fenced in
`RescueLogicLib`) refuses: the host's
factory (IL-8261); non-`transfer` calls on the tracked asset; every call to the Stargate pool
(`STARGATE_POOL`); every call to the LayerZero endpoint except inbound packet hygiene (`skip`, `clear`,
`nilify`, `burn`; `send`, `setDelegate`, `setConfig`, library setters and `lzReceive` are refused); and, on a
dispatcher, any call to a tracked or allowlisted vault (checked at schedule and again at execute, because
UPDATE_VAULTS can change both sets during the timelock). Why: the endpoint and the pool authenticate the host
by bare `msg.sender` (`lzCompose` accepts `composeFrom == address(this)`, the caller of `pool.sendToken`), and
executor and dispatcher are same-address twins, so a rescue `send`/`sendToken` would forge a peer-authenticated
message or compose delivery (e.g. UPDATE_VAULTS + DEPOSIT, or a zero-amount compose that pre-sets
`transferSettled` and strands the real transfer) that moves value on the other chain, where no floor runs; and
tracked-vault shares are in NAV but outside the ASSET floor, so `approve`/`redeem` on a share token would drain
a position unseen. `executeRescue` also reverts `RescueTrackedSharesReduced` if any tracked vault's share
balance fell during the call (bounds what a rescue may move; the target ban bounds what it may authorise).

Two further fences (IL-8763 / IL-8770). The Stargate factory also hosts the rescue queue, and each of its
executors trusts the factory by bare `msg.sender` on `onDispatcherCreated`, `onDispatcherRequestFailed` and
`onDispatcherRequestCancelled`. So the factory refuses every call (any selector, any value) to an address its own
`isExecutor(address)` reports, at schedule and again at execute, because the CREATE3 executor address can be
scheduled before it has code. Hosts without `isExecutor` are unaffected. Without this fence a factory rescue could
forge a dispatcher ACK or NACK.

IL-8770: no call may carry the ContextManager `runWithContext` selector, on any target and on every host. A vault's
ContextManager has no role gate on `runWithContext` and makes its `msg.sender` (here the rescue host) the context
sender, so `runWithContext({vault.approve(ADMIN, max)})` would grant the rescue admin a share allowance that neither
the vault ban (the target is the ContextManager) nor the share snapshot (the balance is unchanged) sees, and the admin
could redeem outside the timelock. Checked at schedule, where the calldata is committed. Residual: a non-Fusion vault
behind a signature-less ERC-2771 trusted forwarder lets the forwarder pick the sender; no such vault is among the
remote vaults we know, and the vault ban plus the share snapshot still apply to direct calls.

Path configuration: the rescue path can no longer reach the endpoint's config setters, and `setDelegate` reverts
on all three hosts (factory, executor, dispatcher; IL-8557 / IL-8558; a one-word `virtual` patch to the vendored
`OAppCore`). The LayerZero configuration of every host follows the endpoint defaults, which LayerZero
maintains; changing it requires redeploying the host. These defaults are set, and may be changed at any time, by
the LayerZero endpoint owner; a host follows them and cannot opt out without a redeploy. Before registering a
path, check off-chain that the endpoint's default config for that eid is not the LZ Dead DVN / BlockedMessageLib,
otherwise the host is dead on that path.

Residual (accepted, documented limitation): the Stargate dispatcher keeps its deposit allowlist apart from the
tracked set, and the target ban covers the union of both.
A vault approved via rescue while it is NOT allowlisted is not caught: before it is ever allowlisted, or after an
`UPDATE_VAULTS` removal that left a residual (IL-8784: the vault is then neither allowlisted nor tracked). If such an
`approve` executes while the vault is out, the allowance survives a later re-allowlisting, which tracks the residual
again, and the spender can move those shares, and the shares of later deposits, outside any timelock. A rescue
scheduled while the vault was out but executed after the re-add is refused at execute. Before re-allowlisting a
removed vault, revoke any share allowance the dispatcher granted (a rescue `approve(spender, 0)` while the vault is
still out; after the re-add every rescue on it is refused). We accept this rather than banning approve-family
selectors on every target.

A rescue cannot leave a tracked vault's share balance lower than before the call: business flows untrack a vault only at a zero share balance (`_maybeUntrack`), so a vault is never untracked
by them with shares left. The one exception is an ALPHA `UPDATE_VAULTS` removal, which sweeps best-effort and
untracks regardless (IL-8784, D-028): any residual is reported by `TrackedVaultSweepResidual` and leaves the
rescue snapshot with the vault. The allowed LayerZero hygiene calls (`skip` / `clear` / `nilify` / `burn`) let the admin drop or
delay genuine inbound packets (liveness / stale accounting, no direct value movement); they are timelocked and
guardian-vetoable. If a tracked vault's `balanceOf` reverts, every generic rescue on that dispatcher reverts
(`observation()` reports the vault unpriced; write it off first, see "Unpriced tracked vaults" below).

### Rescue post-condition is non-worsening (IL-8640)

After every generic rescue (`executeRescue`) each host (both executors, both dispatchers) checks its ASSET balance
against its tracked ledger. The check is non-worsening: the host snapshots `ASSET.balanceOf(this)` before the
rescue call (`_beforeRescueExecuted`; the `RescueModule` default is `type(uint256).max`, which keeps the absolute
rule for a host that overrides only the after-hook) and `_afterRescueExecuted` requires
`balanceAfter >= min(balanceBefore, ledger)`.

- A rescue can never lower a sufficient balance below the ledger.
- A rescue can never lower an already-insufficient balance any further.
- If an issuer-side adjustment (for example Tether `destroyBlackFunds`, a negative rebase) leaves the host's ASSET
  balance below its ledger, rescues that do not touch ASSET still work: LayerZero endpoint
  skip/clear/nilify/burn (Stargate hosts), native-balance recovery, unrelated-token sweeps and ERC-4626 share
  recoveries.
- The donation remedy stays available: transferring ASSET to the host restores the backing. A partial donation
  raises the floor for later rescues (the next snapshot is the higher balance, so `min(balanceBefore, ledger)`
  grows with it); once the balance is back at or above the ledger the absolute rule applies again.
- The revert keeps its existing per-host error (`RescueLedgerInvariantViolation` on both), now reported as
  `(balanceAfter, min(balanceBefore, ledger))`.

Ledger used as the floor, per host:

| Host | Ledger used as the floor |
| --- | --- |
| Executor | `idleLedger + pendingArrivalReserve` |
| Dispatcher | `trackedIdle` |

Residual (accepted): a rescue never repairs a shortfall. While a host is short (balance below its ledger), no ASSET
at all can leave through a generic rescue. The shortfall is closed by a donation (transfer ASSET to the host), or
value is moved by the admin recall / force-resolve paths.

The admin recall (`scheduleAdminRecall` / `executeAdminRecall`) pays only the immutable `ADMIN()`: if the ASSET issuer
blocklists `ADMIN` on the dispatcher's chain, the outcome depends on the token. A token that checks the recipient (USDC,
`isBlacklisted`) makes `executeAdminRecall` revert, so tracked idle has no on-chain exit until the lane recovers or the
block is lifted. A token that checks only the sender (USDT, `isBlackListed` on Ethereum; USDT0, `isBlocked` on Arbitrum)
lets the transfer succeed and the tokens are frozen at `ADMIN` (IL-8807). Either way, check the issuer's blocklist for
`ADMIN` before relying on it.

## Observability: remote vault allowlist

The dispatcher's `VaultsUpdated(commandConfigEpoch, stateVersion, count)` carries only the length of the
input list. It equals the allowlist size because the executor rejects duplicates. The dispatcher does not
log the list itself because it has almost no EIP-170 headroom left.

To follow the remote allowlist from events, join the executor's
`VaultsUpdateRequested(dstChainId, commandId, sequence, newConfigEpoch, vaults)` with the dispatcher's
`VaultsUpdated` on `newConfigEpoch == commandConfigEpoch`. The `vaults` array is the full replacement
list. A `commandId` that the executor later sees NACKed was not applied. Alternatively, read
`getAllowedVaults()` on the dispatcher at that block.

Events declare no `indexed` parameters by design: every field is in the data section; filter by emitter address and topic0.

## Tracked-position set

The Stargate dispatcher does not emit tracked-set membership events on deposits and redeems (EIP-170 headroom;
known limitation). Such a change coincides with `DepositExecuted`, `RedeemExecuted` or `RedeemedFromRequest` of the
same vault, so read `getTrackedVaults()` / `observation()` at that block; only the timelocked write-off emits its own
`TrackedVaultWrittenOff` (IL-8602). Removal is swap-and-pop: it reorders the
set and changes the tracked-position set hash. 
Vaults leaving the allowlist via `UPDATE_VAULTS` are swept and untracked (IL-8784, below).

## Removing a vault: sweep, always untrack (IL-8784, D-020 / D-028)

Right after it replaces the allowlist, the same linked `StargateDispatcherLib.applyUpdateVaults` call reconciles the
tracked set inside the gas-bounded self-call (`runBusinessSelf`): every tracked vault that is no longer allowlisted is
swept with `CrosschainVaultActionLib.sweepShares` (best-effort `redeem(min(balanceOf, maxRedeem))`, low-level, capped at
`VAULT_SWEEP_GAS` = 2,000,000, revert data limited to four bytes) and ALWAYS untracked, whatever is left. The measured
ASSET delta is credited to `trackedIdle`; the ACK delta stays 0 (the move into idle is value-neutral and the executor
reverts on a non-zero delta). Events: `TrackedVaultSwept(vault, sharesRedeemed, assetsLD)` and, for a residual,
`TrackedVaultSweepResidual(vault, sharesLeft, reason, redeemError, untracked)` (reason 1 unreadable, 2 revert or out of
cap, 3 partial or `maxRedeem` 0, 4 dust skipped, 5 redeem failed with less than the full sweep gas forwarded, D-065; not necessarily a gas failure, so monitoring must read `redeemError`). When the held shares are worth at most 0.01 asset unit
(about $30 on WETH, about $1,000 on an 8-decimal BTC-class asset; `10^(decimals - 2)`, read with gas-capped `decimals()` and `convertToAssets` views; a failing or oversized view
counts as not dust) `redeem` is not called at all (D-061): the vault is untracked at once and the event carries
reason 4, so a 1-wei donation cannot make a removal expensive. The sweep never reverts for lack of gas (D-065): the
`redeem` gets `min(VAULT_SWEEP_GAS, gasleft() - VAULT_SWEEP_RESERVE_GAS)`; if that is below the full cap and the call fails
the residual reason is 5, and later removals in the same command get what the earlier ones left (each keeps a 300,000
reserve). A removal of k vaults with real positions fits fully when the lane gives about 0.4M + the sum of the sweeps +
0.3M per vault (the 14M lane fits about 5 to 6 worst-case removals; split bigger updates into several replaces). The no-revert guarantee holds for ONE removal per command. On Stargate every read and write of the re-track pass runs BEFORE the sweeps (IL-8839), so after a gas-limited sweep only the removal's own bookkeeping remains, whatever the size of the allowlist; a second removal in the same command can still fail its reads after the first sweep burned its forward, which is a safe NACK that rolls everything back (a NACK means "split it"). The update itself must still fit the command budget (see "UPDATE_VAULTS gas budget"): measured on committed state, the 2,500,000 minimum lane carries one burned-sweep removal with all 31 kept vaults with about 98k (4%) of margin (the ACK edge is 2,402,000 of delivery gas, about 9.9k per kept vault; pinned by `StargateVaultRemovalCommittedLaneTest`), so the full 32-vault allowlist works on the minimum lane but with a thin margin. Because the re-track pass runs first, each vault it newly tracks (a donated or residual position) costs about 50k of writes before the sweep, so a removal combined with many new re-tracks in the same command on the minimum lane can NACK; that is a safe rollback, retry it with `retryCommandWithBudget` or split it. The Stargate lane is
sized per message (a fresh send can carry more gas), unlike CCIP, where a RETRY is clamped to the route gas limit.
Note the 2,000,000 cap is a safety bound, not a promise: it was calibrated on redeems served from idle cash (a cold 100k to 200k USDC Prime position is still swept fine on a 3M lane), and a
position allocated into markets can need more (a cold 100k USDC position of the Ethereum TESS USDC Optimiser: 3.11M uncapped), in which
case the sweep ends as a residual (reason 2, or 5 when the command gas was the limit). This frees the slot of an
emptied or failing vault (IL-8644). A vault that is allowlisted again while the dispatcher still holds its shares is
tracked immediately (cap-checked), so the residual is valued again without a new deposit. This needs a working `balanceOf`: a vault whose read fails is skipped silently and its residual stays outside NAV. After the re-add ACK check `isTrackedVault(vault)`; if it is false while the vault still holds the residual, fix the vault and re-send the same allowlist.

**Mandatory procedure (D-060): ALPHA redeems or recalls the position to zero BEFORE removing a vault**; then the
removal costs only the dust path. The sweep is best effort: a failed sweep drops a healthy residual out of NAV until
the vault is allowlisted again. A residual (locked by the redemption delay,
`WithdrawManager` liquidity, market illiquidity, `restricted`, `maxRedeem`) drops out of NAV and out of the IL-8556
rescue fence until the vault is allowlisted again. Alert on `TrackedVaultSweepResidual` and re-allowlist the vault to
bring a healthy residual back into NAV. A residual created on a blocked chain has no command path (REDEEM / RFR are
gated on `isTrackedVault`, a re-add is refused) until the chain is unblocked: never remove a vault that holds shares
on a blocked chain. Deploy: new
`StargateDispatcherLib`, `CrosschainVaultActionLib`, dispatcher code and factory.

## REQUEST_SHARES fee ceiling (IL-8603)

`REQUEST_SHARES` carries a fourth action word, `maxFeeShares`, next to `withdrawManager`, `plasmaVault` and `shares`
(`CrosschainMessages.encodeRequestSharesAction`). All three share-valued words are SHARE units of the remote vault and
are never converted. The dispatcher snapshots its own vault-share balance around `requestShares(shares)`; if the
remote WithdrawManager took more than `maxFeeShares` out of it (its request fee, which the vault owner can change
while the command is in flight), the command reverts and is NACKed (`RequestSharesFeeExceeded`), leaving the lane
repairable like any failed business command. `type(uint256).max` means "no ceiling"; `0` tolerates no fee at all.
The measured deduction is reported in `SharesRequested(vault, pendingShares, feeShares)`. This is a wire-format change
(four words instead of three, and a third event field): the old three-word encoding no longer decodes, so executors,
dispatchers and command fuses of a lane must be upgraded together, and any off-chain builder of `actionData` must
pass the new word. The command fuses forward `Command.actionData` as opaque bytes, so only their target-vault
decoding changed. Upgrade order matters in the fail-open direction: a dispatcher that has NOT been upgraded still
accepts a four-word payload, because the old three-word decode ignores trailing bytes, and silently drops the
ceiling, so dispatchers must be upgraded no later than the fuses and executors. The `SharesRequested` event gained a
`feeShares` field, so its topic changed and indexers must be updated.

### Tracked vault left with zero shares (TP-L-16 / IL-8644)

Since IL-8784 removing such a vault from the allowlist with `UPDATE_VAULTS` frees its slot (the sweep finds no shares
and the vault is untracked). A zero-share `REDEEM` still does not remove the entry. Historic ways out remain available:
restore a positive balance (a small `DEPOSIT` into that vault) and redeem it again, which removes the entry; or write
it off with the IL-8602 force-untrack (`scheduleForceUntrack` / `executeForceUntrack`, emits
`TrackedVaultWrittenOff(vault, 0)`, see "Unpriced tracked vaults" below). Plan slot headroom accordingly when
rotating vaults.

## Unpriced tracked vaults (IL-8602)

A tracked vault whose `balanceOf` or `convertToAssets` reverts (or returns less than a word) no longer reverts
`observation()`. The view prices the rest and returns `vaultValued[]` (aligned with `trackedVaults`, `false` = not
priced, value 0) and `unpricedCount`; both are appended to the `Observation` tuple, so older readers keep decoding
the leading fields. Nothing on the Stargate wire carries a remote balance except the recall, which prices with
`TrackedVaultPricingLib` on the on-chain budget (`VAULT_READ_GAS`; a vault priced in `observation()` can count as 0
there). An attester MUST NOT approve while `unpricedCount != 0`: the aggregate then omits that
position. The executor already fails closed by staleness while no fresh approved observation arrives.

Runbook for a vault that stays unpriceable: the fastest way out is an ALPHA `UPDATE_VAULTS` that removes it from the
allowlist (D-028: the best-effort sweep runs, a failing vault is reported as a residual and the vault is untracked at
once, no timelock). If it must also stay allowlisted or the removal is not wanted, the rescue admin calls `scheduleForceUntrack(vault)` (full rescue delay,
guardian can `cancelRescue` / `vetoAllPendingRescues`), then `executeForceUntrack(rescueId, vault)` emits
`TrackedVaultWrittenOff(vault, sharesLeft)` and removes it from the tracked set whatever its share balance (`sharesLeft`
is 0 when the balance is unreadable). This WRITES OFF the position from observations: lower the executor's value with
the timelocked `scheduleForceSetSettledBalance`. The shares stay in the dispatcher; the vault is no longer tracked, so
once it is also off the allowlist (the fence covers tracked and allowlisted vaults) the IL-8555/8556 vault fence no
longer blocks a generic rescue of them if the vault heals. A vault still on the allowlist is tracked again by its next
deposit or by the next `UPDATE_VAULTS` naming it.

On the on-chain paths each vault read is capped at 200,000 gas (`TrackedVaultPricingLib.VAULT_READ_GAS`) and a pre-check
reverts with `InsufficientGasForVaultRead` when the caller supplied less; an honest read above the cap is reported
unpriced (errs low, flagged). `UPDATE_VAULTS` replaces the allowlist and validates only the vaults in the new list, so
omitting a vault de-allowlists it; since IL-8784 the removal calls the vault once more (capped views and the best-effort
sweep `redeem`), and a vault that reverts is reported as a residual and untracked. Stargate force-untrack does not
require de-allowlisting.

**Two `convertToAssets` budgets (IL-8602 review G-1).** `balanceOf` and `asset()` always get `VAULT_READ_GAS`. For
`convertToAssets`, `observation()` gets `VIEW_CONVERT_GAS` = 2,000,000: it runs as eth_call and blocks nothing on-chain,
and a MetaMorpho V1 vault costs about 40k gas per market cold (about 1.25M at its 30-market queue limit; honest
12-market vaults need about 460k). The recall (`RETURN_STARTED.remoteBalanceSD`) keeps the 200k budget so a gas-burning
vault cannot make it heavy. Consequences for operators:

- Attesters gate on `observation().unpricedCount` (a priced vault there can still count as 0 in a recall report).
- Call `observation()` with an explicit high gas limit. Too little gas reverts with `InsufficientGasForVaultRead`; it
  never understates. Worst case is about `trackedVaults.length` x 2.45M (a convert-burner costs about 2.01M with the
  pre-check, plus up to 2 x 200k on `balanceOf` / `asset()`): about 64-77M at 32 vaults, so pass e.g. 80M (providers'
  caps vary; geth's default `--rpc.gascap` is 50M). If the view still reverts, find the burners with direct per-vault
  `convertToAssets` eth_calls over `trackedVaults(i)`, then de-allowlist and force-untrack them (both on the 200k
  budget, unaffected). This is not a new attestation DoS: one burner already sets `unpricedCount != 0`.
- For the same state, view and response values agree whenever both price a vault; they differ only in which vaults get
  priced. A vault whose cold `convertToAssets` is between 200k and 2M is 0 in a cold response, so
  `RETURN_STARTED.remoteBalanceSD` can be lower than `observation().accountedBalance`. Trust `observation()`.
- Allowlisting rule: before allowlisting a vault, measure its cold `convertToAssets` on a fork and accept it only at
  about 1M gas or less. A curator adding markets later can push it up, so re-check periodically.
- Procedure (full recall): before a full recall from a chain that holds a vault whose cold `convertToAssets` exceeds
  `VAULT_READ_GAS`, approve a current attestation first, so the recall does not empty `settled` and the IL-8606 residual
  rule never applies. Otherwise the residual anchor drops to 0 and only the timelocked force-set
  (`scheduleForceSetSettledBalance`), or a later bridge credit that brings the residual back within the anchor band,
  fixes it (no funds are lost). The CCIP side pins
  this flow (`CcipViewConvertBudgetFlowTest`).

Stargate keeps the locked `Observation` shape, so asset drift (IL-8645) has no reason code: it is reported through
`vaultValued[i] == false` and counted in `unpricedCount`, like every other IL-8602 failure (its `vaultAssetValues`
entry is 0). A parallel `unpricedCodes` array was not added because it would change the tuple that keepers already
decode, for a signal an attester treats identically (do not approve while `unpricedCount != 0`). The recall
(`RETURN_STARTED.remoteBalanceSD`, IL-8606) prices with the same library (on-chain budget), so it makes up to three
capped reads per held vault; size the recall gas accordingly. `observation()` view cost grows by at most one capped
`asset()` read per held vault (up to about 205k each, same pre-check).

**Vault `asset()` is re-asserted (IL-8645).** The allowlist update validates a remote vault once (`code.length != 0`
and `asset() == ASSET`). An upgradeable vault, or one with a mutable underlying, can change its `asset()` afterwards.
Two places now re-assert it:

- DEPOSIT: before any approval the dispatcher reads `IERC4626(vault).asset()`; a mismatch reverts with
  `VaultAssetDrifted(vault, actual)` and the command FAILS with a NACK (nothing approved, deposited or debited, the
  sequence does not advance). A vault whose `asset()` reverts also fails the deposit, which is intended: a deposit into
  a broken vault should fail.
- Pricing: a tracked vault that HOLDS shares is priced only while `asset() == ASSET` (read with the same capped
  `staticcall` and the same `VAULT_READ_GAS` budget and pre-check as `balanceOf`). Otherwise
  `convertToAssets` would be denominated in a different token, so the vault is reported unpriced instead of feeding
  its number into the NAV attestation. A zero-share position is worth zero whatever the asset and is not flagged.
  The asset read happens after `balanceOf` and before `convertToAssets`.

REDEEM, REQUEST_SHARES and REDEEM_FROM_REQUEST are deliberately NOT gated. They only move value out of the vault
(shares burned, ASSET received and measured as a balance delta), grant no approval and cannot be used to push funds
into a vault. Gating them would trap the position in exactly the vault that has become suspect. Exiting a drifted
vault therefore stays possible; if a redeem returns nothing it is the measured delta (`minAssets`) that fails it. Use
`minAssets > 0`: with 0, a drifted vault paying another token burns the shares and credits nothing (that token lands in
the dispatcher, recoverable only by rescue).

A drifted vault that cannot be exited stays flagged unpriced; the IL-8602 force-untrack (timelocked rescue-admin
write-off, guardian veto) remains the ejection path. No new timelocked path was added.

While a tracked vault's `balanceOf` reverts, the generic rescue (`executeRescue`) is unavailable, because its share
snapshot uses a plain `balanceOf` (`RescueLogicLib`); it works again once the vault is written off.
`TrackedVaultWrittenOff` is the attester's signal: `unpricedCount` drops back to 0 after the write-off. A force-set of
the executor value is needed only when the drop exceeds `bigChangeBps` or the anchor band; otherwise normal attestation
suffices.

## Supply amount floor (IL-8634)

`StargateCrosschainSupplyFuse.enter` clamps `amount` to the vault's raw asset balance, then floors it to a multiple of
the executor's shared-decimals unit (`10 ** (LOCAL_DECIMALS - SHARED_DECIMALS)`) before the transfer and send. The
sub-unit dust stays in the vault, so a third party donating 1 wei cannot make a clamped supply revert
`AmountBelowSharedDecimals`; an amount that floors to 0 returns early (no transfer, no send, no event), and an explicit
misaligned `amount` is floored rather than rejected, so alpha does not need to pre-round. The Stargate pool removes dust
itself, so the amount received on the destination is never above the floored amount; the `minAmountLD` floor is
unaffected.

## UPDATE_VAULTS gas budget (IL-8617)

A fresh `UPDATE_VAULTS` with the allowed maximum of 32 vaults does not fit the old 2,000,000-gas command-lane receive
option: persisting the command bytes (`_storedCommands`) and installing the allowlist (one flag and one array slot per
vault) already cost more than that, before the per-vault validation (`code.length`, `asset()`), the IL-8784 reconcile
(one capped `balanceOf` of about 208k pre-check for every allowlisted vault that is not tracked yet) and the ACK. Measured on
the dispatcher `lzReceive` with every touched account cooled (`StargateUpdateVaultsGasBudgetTest`):

| Update                              | Dispatcher `lzReceive` gas |
| ----------------------------------- | -------------------------- |
| fresh, N = 0                        | 626,237                    |
| fresh, N = 1                        | 733,283                    |
| fresh, N = 8                        | 1,259,862                  |
| fresh, N = 16                       | 1,861,677                  |
| fresh, N = 24                       | 2,463,505                  |
| fresh, N = 32 (the maximum)         | 3,065,376                  |
| replace, 32 -> 32 different vaults  | 3,172,016                  |
| remove, 32 -> 0                     | 789,192                    |

Cost is about 76k gas per fresh vault on top of about 0.63M fixed (IL-8784 added about 7k per vault: 2.81M -> 3.07M at 32, measured by the budget test; these figures are for vaults without shares and exclude any sweep, which adds up to `VAULT_SWEEP_GAS` plus overhead per removed vault). The executor-side ACK receive is about 67k. The ACK
carries no valuation (`CommandAck` is fixed size) and `UPDATE_VAULTS` never prices vaults, but since IL-8784 it does read
`balanceOf` of every allowlisted vault it does not track (and `decimals()` / `convertToAssets` for a removed vault's
dust check), each on the IL-8602 `TrackedVaultPricingLib.VAULT_READ_GAS` cap (200,000 per read, about 208k pre-check);
this is included in the table above. Per-vault read headroom therefore only
matters for the same lane's
`RETURN_ASSETS_REQUEST` and balance paths, which are sized separately (see "Recall gas headroom" above).

Recommended reference command-lane receive option (the `addExecutorLzReceiveOption(gas, 0)` blob passed to
`registerChain`): 4,000,000 gas (about 30% headroom over the 3.07M fresh maximum and 26% over the 3.17M replace; `COMMAND_LANE_MAX_RECEIVE_GAS` is 10M so it
is accepted). `MAX_ALLOWED_VAULTS` stays 32. The test pins the N = 32 cost (fresh, replace and removal) at no more than
80% of that option, so a future handler change that eats the headroom fails CI. The 3.07M fresh maximum above is total handler gas and
already contains the pre-check work (about 1.06M for a 32-vault payload); under the IL-8625 budget a 4M lane leaves the
business call about 2.10M after the pre-call allowance and the catch reserve, and the largest fresh install executes at
the lane's gas (`StargatePreCheckPinTest`). The lane minimum is 2,500,000 (2,000,000 is no longer registrable), where a
32-vault install reaches the check but its business call is short of gas and NACKs: operators on a small lane keep the
allowlist small. An update that does not fit is a FAILED + NACK, recovered with a fresh send or a retry carrying a raised
budget (the lane cannot change). Because
`UPDATE_VAULTS` replaces the whole list and every message pays the fixed part plus the per-vault part for the full new
list, splitting growth into several messages does not lower the cost of the final one: with a smaller option the
allowlist itself has to stay below the size that option supports (the manager can always shrink it, a 32 -> 0 removal
costs about 0.79M). The 32 -> 32 replace (3,172,016) sits at 79.3% of the 80% CI pin (3.2M of the 4M option), about
28k gas of margin: a handler change adding more than that fails `StargateUpdateVaultsGasBudgetTest`.

## Command gas budget and out-of-gas handling (TP-M-47 / IL-8625, TP-L-13 / IL-8641 closed by the catch reserve)

Every COMMAND and UPDATE_VAULTS carries `minExecutionGas` (`CODEC_VERSION` 4), stamped by the executor at send time:

    budget = laneGas - laneGas / 64 - COMMAND_PRE_CALL_BASE - COMMAND_PRE_CALL_PER_WORD x words

`laneGas` is the chain's registered command-lane `lzReceive` gas, parsed from the enforced options at `registerChain` and
stored per chain (`StargateExecutorState.commandLaneReceiveGas`; paths are append-only, so it never changes). `laneGas / 64`
is what the real EndpointV2 keeps back on its hop to the OApp (EIP-150). `words` is the 32-byte word count of exactly what
the dispatcher stores before the check (the ABI-encoded command / UPDATE_VAULTS, 7 + vault count for an UPDATE_VAULTS: a
fresh non-zero SSTORE is about 22.1k per word, which is why a 32-vault list needs much more than a DEPOSIT), and the
constants are `COMMAND_PRE_CALL_BASE` 500,000 and `COMMAND_PRE_CALL_PER_WORD` 24,000. Calibration on the real
EndpointV2 + its 4-DVN ULN receipt quote, measured COLD with forge 1.8.5 semantics, the CI forge (`StargatePreCheckForkTest`: each shape is the first delivery on a
fresh fork pair, every slot is re-cooled before each bisection trial with `vm.cool`, and 2,500 is added for EVERY touched
account, which is conservative because most are cold on a fresh fork already; the ULN quote alone is about 204k gas cold;
forge 1.7.1 left that quote path warm and under-measured the first delivery by about 130k):
pre-check work net of the hop loss for 7 / 15 / 23 / 39 words (empty UPDATE_VAULTS, 8 / 16 / 32 vaults) is 510k / 730k /
931k / 1,292k - 1,332k, a fit of about 331k + 25.7k per word. The 11-word DEPOSIT cannot be the first message on a path, so its
figure (about 613k) is EXTRAPOLATED from the fit, not measured. The formula leaves at least 104k of margin on every shape
(asserted at 100k); each extra DVN in a production ULN config costs about 22k, so the smallest margin covers about four more.
The mock endpoint reads lower. The executor reverts `CommandLaneGasTooLow(laneGas, requiredLaneGas)` rather than stamp a budget below
`COMMAND_EXECUTION_MIN_GAS`, which registration already makes unreachable for every payload (a 32-vault UPDATE_VAULTS is
the largest, see `COMMAND_LANE_MIN_RECEIVE_GAS`). The budget sits inside the committed envelope bytes, so a redelivery
with another value is a `CommandCommitmentMismatch`.

The rule. On Stargate the first delivery is permissionless with no stipend, so the caller chooses the gas. The budget is
checked after the sequence / `PENDING` writes, right before the capped self-call. A delivery that reaches it with less
gas reverts `InsufficientGasForCommand(available, required)`: the whole delivery reverts, including state writes, so the
packet stays retryable and no NACK exists. At or above the budget EVERY failure of the business call is a business
failure (FAILED + NACK), whatever the revert data says: a decodable error, an empty revert, an out-of-gas,
`InsufficientGasForVaultRead` (the lane is too small for the tracked set), an OpenZeppelin `FailedInnerCall` /
`FailedCall`, or an `AccessManagedUnauthorized` / `UnsupportedAsset` that an out-of-gas produced. There is no
classification of revert data. The command runs in a self-call capped at `gasleft() - COMMAND_CATCH_RESERVE_GAS`
(400,000, measured: the catch path needs 250k-260k on mocks), so a callee that burns everything it was forwarded still
leaves the catch frame enough gas to persist FAILED and send the NACK (closes TP-L-13); `MIN_NACK_GAS` guards the send.

**Per-command gas top-up.** The lane is fixed at registration and sends use no caller options, so a command that needs more
than the lane gives would NACK forever. `Command.minExecutionGas` (the manager's value, forwarded by the command fuse) is
therefore honoured: 0 keeps the lane budget; above it (at most `MAX_COMMAND_EXECUTION_GAS`, 14,000,000, else
`CommandBudgetAboveMax`) it becomes the budget, and the send carries an extra `addExecutorLzReceiveOption(extra, 0)` sized
so the formula, applied to the total delivered gas (lane + extra, hop loss included), reaches the requested budget
(`CrosschainMessages.laneGasFor` is the exact inverse). The combined options are what the fee is quoted on, so the extra
gas is inside the `maxNativeFee` check (`NativeFeeTooHigh`). A request at or below the lane budget adds nothing.
UPDATE_VAULTS has no manager top-up path (it is sized by the lane and its vault count).

**RETRY with a raised budget.** `retryCommandWithBudget(chainId, minExecutionGas)` (the command fuse's RETRY_COMMAND with a
non-zero `command.minExecutionGas`) sends a RETRY_COMMAND carrying the raise (0 = keep the stored budget). The RETRY is
authenticated, so it can only RAISE: the dispatcher runs `max(stored, persisted raise, retry raise)` and persists the
maximum in `StoredCommand.raisedBudget` (before the check, so it rolls back with a below-budget revert); every later run of
that command uses it. The executor tracks the effective budget in `ActiveCommand.minExecutionGas`, and every retry (a plain
one too) appends the extra `lzReceive` option the effective budget needs on top of the lane, so a topped-up command keeps
being funded. Cap 14M. A retry raise below the stored budget changes nothing.

**Lane sizing (mandatory, or top up).** Because an attacker can always deliver at exactly the budget, the lane gas must
satisfy lane gas >= the measured cold gas of the heaviest action of every allowed vault + the pre-call work of its payload
(folded into the budget formula above) + `COMMAND_CATCH_RESERVE_GAS` (400,000) + the 1/64 slack of the call (the endpoint's lane / 64 hop loss is already in the budget formula). In practice: measured
redeem + about 1,000,000. Reviewer lower bounds for a real REDEEM alone: IPOR USDC Prime Arbitrum 0.77M, Base ETH Lending
Optimizer 1.75M, Base USDC Lending Optimizer 1.77M, TESS USDC Ethereum 3.26M, Harvest USDC Base 4.00M, Harvest WETH Base
7.26M, so 2M and 4M lanes are too small for several ordinary REDEEMs; 4M is no longer a universal recommendation (it was
IL-8617's figure for the 32-vault UPDATE_VAULTS, which now needs only about 2.5M). Re-measure whenever a vault's curator adds
markets. Residual: a lane sized too tightly turns an honest delivery into a FAILED + NACK, and the lane cannot be resized
(paths are append-only): recover with the manager's per-command top-up (a fresh SEND_COMMAND with `minExecutionGas`) or a
`retryCommandWithBudget`, both of which fund the extra gas through the send options. A real liquidity shortfall (a REDEEM
above the vault's instant liquidity, including on WETH9- or USDT-shaped tokens whose empty revert SafeERC20 wraps) and a
real permission or price-feed refusal NACK within the delivery, so the manager can cancel and send a smaller command in
the same block.

**Deployment note (IL-8625).** `Command`, `UpdateVaults` and `RetryCommand` gained `minExecutionGas`, so the command
fuses' calldata (`StargateCrosschainCommandFuseEnterData.command`) changed: redeploy the Stargate and CCIP command fuses and
re-grant them. `CODEC_VERSION` is 4: a mixed old/new executor-dispatcher pair fails `UnsupportedCodecVersion`, so deploy
executors and dispatchers together, built together. The linked libraries `StargateExecutorAccountingLib`,
`StargateExecutorDeploymentLib` and `StargateLzSendLib` changed (and `CcipExecutorCommandLib`, `CcipSendLib` on the CCIP
side): re-pin them in `crosschain_deploy` and re-link the executors (the IL-8551 size round later moved the command
builders into the new linked `StargateExecutorCommandLib`: pin it too). `StargateExecutorState` gained
`commandLaneReceiveGas` (executors registered before this build have no stored lane gas and cannot send commands: register
chains on the new executor), `ActiveCommand` gained `minExecutionGas` / `payloadWords`, and the dispatcher's `StoredCommand`
gained `raisedBudget`. The command-lane minimum rose to 2,500,000: lanes registered below it by older scripts (2,000,000)
must be re-registered on a new executor. The deploy repo's `RegisterRemoteChains.s.sol` (it registers 2,000,000 today) must be
changed to register at least the new minimum (2,500,000; CCIP routes at least 2,630,000 for a 32-vault UPDATE_VAULTS), and the dispatcher factory's `DISPATCHER_RECEIVE_GAS` path options are a separate
setting that is unaffected.

**Gas cap per transaction and the deadline.** `MAX_COMMAND_EXECUTION_GAS` is 14,000,000, not 30M: EIP-7825 (Fusaka) caps an
Ethereum transaction at 2^24 = 16,777,216 gas, and delivering a budget needs `laneGasFor(budget, words)` of `lzReceive` gas
(`laneGasFor` = about 15.68M for the cap and the largest payload; the test requires that plus 1M of executor transaction
overhead to stay under the cap, about 0.1M of headroom, which is why 14M is the cap; pinned by
`testShouldKeepTheMaximumBudgetDeliverableUnderTheEthereumTransactionGasCap`). A destination with a lower per-transaction cap
accepts a lower top-up. An undeliverable budget can never wedge the lane: the dispatcher checks the command DEADLINE before
the budget (`_executeStoredCommand`; the deadline is inclusive as before), so once `COMMAND_TTL` (24h) has passed a delivery with
enough gas to store the payload and send the NACK (on the real endpoint the NACK send costs more than `MIN_NACK_GAS`; with less
the delivery reverts and stays retryable) records FAILED + NACK without a business call (the NACK carries only
`(commandId, sequence)`; the expired path emits the same `CommandFailed`), and the manager's CANCEL of that FAILED command
(it pays its fee and honours the IL-8579 cooldown) is answered with an `EXPIRED` receipt that frees the lane (see "Expired
cancel" below), no ABANDON and no admin. The executor refuses a RETRY of a command already past its deadline
(`CommandExpired`), since it can only end in a NACK and would waste the fee and a raise; a retry sent before the deadline
and delivered after it is NACKed the same way. Before the deadline a below-budget delivery still reverts. A
command that failed within its TTL no longer waits for it: the NACK exists at once, and an in-window CANCEL frees the lane in
the same block.

Expired cancel and the `EXPIRED` receipt (IL-8594). `_onCancelCommand` has the same deadline fence as the CCIP
dispatcher, placed after `_ensureReceiptBudget()`: a CANCEL for a FAILED command that still owns the lane's next
sequence and arrives past `commandDeadline(commandId)` marks the command CANCELLED, does NOT consume the sequence, emits
`CancelCommandExpiredIgnored(commandId, sequence)` and sends a `COMMAND_ACK` with resolution `EXPIRED` (2). A cancel at
the deadline itself is a normal one. A stale packet for a sequence the lane already passed is still consumed by
`_ignoreIfStale` first. The executor (`StargateExecutorAccountingLib._onCommandAck`) frees `activeCommand` only when it
is active, names the same command id and sequence, and is FAILED: it emits `CommandExpiryReleased(chainId, commandId,
sequence)` and bumps the accounting epoch like every other slot release; `nextSequenceToSend` and the config epoch are
never touched, so the next command reuses the unconsumed sequence. In any other state the receipt is ignored
(reported with the existing `CommandReceiptConsumedWithoutCommand`, as every receipt that resolves no active command)
and never reaches `_adoptLateReceipt`: a retained cancel that lands after an
`ABANDON_COMMAND_SEQUENCE_UNUSED` and a same-sequence replacement therefore no longer consumes the replacement's
sequence or retires it. An old executor cannot decode resolution 2 (enum range check reverts the receipt): upgrade
executors before dispatchers.

ABANDON runbook (IL-8594). (1) Before executing `ABANDON_COMMAND_SEQUENCE_UNUSED`, check that the dispatcher chain's
latest safe block has a timestamp strictly greater than `commandDeadline(commandId)`. The fence reads the
dispatcher chain's clock, the abandon the executor chain's and already waits for deadline + `COMMAND_EXPIRY_MARGIN`, so
only a dispatcher clock lagging by MORE than the margin (e.g. Arbitrum `delaySeconds` plus an executor leading by
`futureSeconds`, the IL-8591 residual) would still run a retained cancel as an in-window one. (2) Read the
dispatcher's `nextCommandSequence()` and `commandStatus` for the declaration only after the deadline has passed there:
a retained CANCEL or RETRY executed inside the window still consumes the sequence. (3) After the deadline the cancel
that executes first is answered `EXPIRED` and frees the slot, so a re-send is worth its fee; a re-send to a command
already closed is idempotent and sends no second receipt.

## Late receipt refreshes the config epoch after a CONSUMED abandon (IL-8632)

`ABANDON_COMMAND(true)` / `ABANDON_COMMAND_SEQUENCE_CONSUMED` advances the executor's command-sequence mirror
(`nextSequenceToSend`) but cannot carry the dispatcher's `commandConfigEpoch`: an UPDATE_VAULTS that succeeded
remotely advanced that epoch, and the abandon is a declaration made from no observation. The delayed COMMAND_ACK is
the only authenticated source of the new epoch. A receipt for `nextSequenceToSend - 1`
(`StargateExecutorAccountingLib._adoptLateReceipt`) therefore refreshes the epoch mirror (`chainConfigEpoch`) ONLY,
and only when the receipt's epoch is newer than the mirror. It does so even when a command sent after the abandon owns
the slot: that command carries the old epoch (an UPDATE_VAULTS carries old epoch + 1), the dispatcher NACKs it anyway
(`ConfigEpochMismatch`), and a receipt ignored at that point would never be delivered again. The slot is left alone,
so that command still needs its NACK and a CANCEL (answered CANCELLED before its deadline, EXPIRED after it; either
frees the slot, and the epoch is already right). The sequence mirror is not touched, and
`LateReceiptEpochAdopted(chainId, sequence, previousEpoch, newEpoch)` is emitted (alert on it). Monitoring events
around it: `CommandReceiptConsumedWithoutCommand` is also emitted. Older receipts, equal/older epochs and NACKs stay
ignored as before.

Why it matters: every command is stamped with the executor's epoch mirror and the dispatcher rejects a mismatch (a
stale command is NACKed with `ConfigEpochMismatch`, raised by a self-call inside try/catch; UPDATE_VAULTS needs
`commandConfigEpoch + 1`), so a stale mirror blocks the whole lane (business commands too), until a receipt or a
timelocked `REALIGN_COMMAND_LANE` repairs it. Timelock-free repair: cancel the stale command before its deadline; the
CANCELLED ACK it returns carries the dispatcher's epoch, so the mirrors catch up. Past the deadline the EXPIRED receipt
frees the slot but not the epoch, so `REALIGN_COMMAND_LANE` is the fallback if the late receipt never arrived.

Design choice: late adoption rather than letting `ABANDON_COMMAND(true)` carry an observed dispatcher epoch. The
abandon argument would be a second rescue-admin-supplied figure to get wrong (a wrong epoch bricks the lane until
realign), whereas the receipt is authenticated by the transport. If no receipt ever arrives, `REALIGN_COMMAND_LANE`
remains the fallback and takes both observed counters. The abandon does not refresh the epoch.

REALIGN interplay: a `REALIGN_COMMAND_LANE` armed for the stale pair reverts `RealignStateMoved` once an adoption has
moved the mirrors (IL-8652, below), so it can no longer roll the lane back over an adopted receipt.

Command-lane realign (TP-M-08 / IL-8652). `scheduleForceResolveTransfer(id, REALIGN_COMMAND_LANE)` takes
`id = (uint64 chainId << 192) | (uint48 expectedEpoch << 144) | (uint48 expectedSequence << 96) | (uint48 newEpoch << 48) | uint48 newSequence`.
Before scheduling, read the expected pair from your own executor (`chainConfigEpoch(chainId)` /
`nextSequenceToSend(chainId)`) and the new pair from the dispatcher (`commandConfigEpoch()` / `nextCommandSequence()`).
If an authenticated ACK moves the executor mirrors during `RESCUE_DELAY`, execute reverts
`RealignStateMoved(chainId, expectedSequence, actualSequence, expectedEpoch, actualEpoch)` instead of rolling the lane
back: re-read both sides and reschedule from the new state. Armed behind an `ABANDON_COMMAND_SEQUENCE_*` in the same
batch, the expected sequence is the post-abandon value (current + 1 if the abandon declares the sequence consumed,
unchanged for UNUSED); the epoch mirror is not touched by an abandon. Schedule refuses an id whose chain has no ready
dispatcher (`DispatcherNotReady`, which also catches the pre-IL-8652 layout with the chain id at bit 128). A zero
expected epoch is valid and is not refused: on Stargate the epoch mirror is 0 until the first UPDATE_VAULTS ACK (CCIP
differs because its route initialisation sets the epoch to 1). The counter
fields are 48-bit (a lane would need 2^48 commands to overflow them). A realign already queued in the old layout must
be rescheduled in the new one. The free-slot check stays execute-time only.

## CREATE_DISPATCHER ticket expiry (IL-8623)

- The `CREATE_DISPATCHER` ticket (`DeploymentTicket`) carries `expiresAt = createdAt + deploymentTtl` (source
  timestamp), appended as the last struct field. Wire-format change: all factories sharing a CREATE3 address must
  run the same build; never extend an existing factory set to a new chain with this build and never mix versions.
  IL-8623 did not bump `CODEC_VERSION` (the envelope is the same; IL-8625 later set it to 4).
- Destination sanity bound: a ticket with `expiresAt > block.timestamp + MAX_DEPLOYMENT_TTL (30 d) +
  DEPLOYMENT_CANCEL_MARGIN` reverts `TicketExpiryOutOfRange` (retryable, no NACK). It also turns a destination clock
  lagging the source beyond the margin at delivery into a retryable revert instead of a wrong deploy.
- `deploymentTtl` (min 1 h) is also the delivery deadline, including the time the packet spends on the LayerZero gate
  or waiting for a manual execution.
- Destination: a fresh ticket delivered at `block.timestamp >= expiresAt` is NOT deployed. The factory answers
  `DEPLOYMENT_NACK` with the new reason `NackReason.TICKET_EXPIRED` (3) and emits `DispatcherTicketExpired`. Nothing
  is recorded (time is monotonic, a re-delivery is expired again). An already consumed ticket (DEPLOYED /
  REJECTED_OCCUPIED) is still replayed idempotently after expiry. For a new ticket key the expiry check runs before
  adoption of an existing own deployment and before the occupied-address check.
- Source: the NACK is consumed like any other (PENDING -> FAILED, config freeze released,
  `onDispatcherRequestFailed`). `cancelPendingDeployment` / `cancelDispatcherRequest` are allowed only from
  `createdAt + deploymentTtl + DEPLOYMENT_CANCEL_MARGIN` (24 h, same rule and value as `COMMAND_EXPIRY_MARGIN`: the
  destination clock may lag the source by up to the margin), and only for the factory owner, the executor and its
  manager; everyone else needs a further `DEPLOYMENT_CANCEL_GRACE` (3 days, IL-8649). So a ticket is never deployed
  after the source cancelled it. The effective cancel delay is now TTL + 24 h (3 days more for third parties).
- Destination also refuses a fresh deployment while `scheduledAssetConfig[assetId].exists`
  (`DestinationAssetMigrationScheduled`, the packet reverts and stays retryable) until `executeAssetConfig` ran; a
  deployment would freeze the asset and make the scheduled update revert for good. Adoption of an existing own
  deployment is not affected.
- Runbook: Stargate has no `cancelAssetConfig`. If `executeAssetConfig` starts failing, re-schedule a valid config.
  The migration gate does not apply once the asset is frozen (any `createExecutor` or deployment freezes it), and a
  frozen asset cannot be migrated at all, so a stale schedule on it never blocks deployments.
- Residual: a lag larger than `DEPLOYMENT_CANCEL_MARGIN` (accepted, as for IL-8591) could let a ticket deploy after
  the source cancelled it; a lane whose destination can lag by more must not be configured.

### Late ACK after a cancel (IL-8637 / IL-8649)

- A deployment cancel never reaches the destination. A ticket delivered before its `expiresAt` can still deploy, and
  its DEPLOYMENT_ACK can be retained by LayerZero (the executor callback reverted on an unfunded initial
  `UPDATE_VAULTS`) and retried after the source cancelled.
- `_onDeploymentAck` accepts an ACK matching a CANCELLED request (hash, chain, dispatcher == executor) and promotes it
  to DEPLOYED (`DispatcherRequestLateAcked` after `DispatcherRequestAcked`). The pending counters were released at
  cancel and are not released again. `StargateExecutorDeploymentLib.markReady` promotes a CANCELLED request only if
  no newer request is pending and no dispatcher is recorded.
- Cancel is exclusive to the factory owner, the executor and its manager from `expiresAt + DEPLOYMENT_CANCEL_MARGIN`;
  third parties only after a further `DEPLOYMENT_CANCEL_GRACE` (3 days).
- `_onDeploymentAck` still does NOT catch an executor `onDispatcherCreated` revert (a catch would discard the
  executor's `markReady`); the retained ACK can now be retried after a cancel.
- A late ACK sets `pathFrozen` after the cancel had released it, so a path config the owner scheduled in between
  reverts `PathConfigFrozen` (same as an on-time ACK).
- Deployment note: no wire change and no storage change, but both factories' bytecode changed (the cancel gate and
  `_onDeploymentAck`), so both are redeployed. An executor still linked to the OLD `StargateExecutorDeploymentLib`
  under the new factory falls back to the old behaviour: `markReady` rejects CANCELLED and the ACK stays retained.
  The CCIP side changed too (cancelled-ticket mappings on its factory, a `CANCEL_DEPLOYMENT` fuse command; see its
  README).

## Factory fee budget (IL-8565 / IL-8605)

The factory pays the LayerZero fee of every CREATE_DISPATCHER ticket, and of its ACK and NACK replies, from one native budget shared by all tenants. To bound what a single executor can burn, `requestDispatcher` counts tickets per (executor, destination chain) in `deploymentAttempts` and reverts `DeploymentAttemptsExhausted` once `MAX_DEPLOYMENT_ATTEMPTS` (3) is reached. A NACK or a TTL cancel does not lower the counter; only a successful DEPLOYMENT_ACK deletes it, or the owner with `resetDeploymentAttempts(executor, dstChainId)` (immediate, not timelocked, because it only re-opens spending of the owner's own budget). The factory's own sends are now capped like executor sends: `StargateNativeFeeCapLib` applies `maxNativeFee(dstChainId)` to them, so set the ceiling for every registered path on BOTH factories (ticket on the source, ACK/NACK on the destination); a zero ceiling blocks the send. What LayerZero retains in that case is the inbound CREATE_DISPATCHER on the destination (the whole receive reverts, including the deployment); anyone can retry it once the ceiling is set. A retry that lands after the ticket's `expiresAt` is NACKed `TICKET_EXPIRED` and not deployed (see "CREATE_DISPATCHER ticket expiry (IL-8623)"); the next re-request is a fresh ticket and uses one of the 3 attempts (the owner can reset them).

The per-chain ceiling is shared by executor sends and the CREATE_DISPATCHER ticket, which runs with 8M destination gas, so toward L1 the ceiling must be sized for the ticket quote (at 0.01 ETH the ticket fits only below ~1.2 gwei L1 gas). If the quote exceeds the ceiling, `createDispatcher` reverts synchronously and no attempt is consumed.

Ops note: call `setMaxNativeFee` on every factory for every registered chain it answers on. A Verify-script assertion that every registered path has a non-zero ceiling is recommended (not implemented here).

## Factory ownership and creator permission

The factory constructor emits the initial `CreatorAllowanceUpdated(owner, true)` and `CreationRestrictionUpdated(true)`, so an event-built history of creators starts from the correct state.

`transferOwnership` on the Stargate factory is one-step and does not revoke the previous owner's creator permission. After a transfer the new owner should call `setCreatorAllowed(previousOwner, false)`, unless the previous owner is meant to keep creating executors.

## Blocked chains (IL-8580)

`StargateCrosschainCommandFuse` refuses a fresh `SEND_COMMAND` DEPOSIT and a non-empty `UPDATE_PLASMA_VAULTS` on a chain
the executor has circuit-broken (`CrosschainCommandFuseChainBlocked`); an empty list (pure removal) stays allowed.
Redeem-type commands and `CANCEL_COMMAND` stay open as repair actions. `RETRY_COMMAND` reads the stored command's
action (IL-8600) and is gated like a fresh send of it: a retried DEPOSIT is refused on a blocked chain, re-checks its
target vault against the REMOTE_VAULT substrates (`activeCommandTarget`; the substrate may have been revoked since the
first send) and performs the live `getBalance()` NAV read like `SEND_COMMAND` (`CANCEL_COMMAND` is the alternative);
a retried redeem-type command stays a repair action; a retried `UPDATE_PLASMA_VAULTS` is refused on a blocked chain
whatever its list (the executor stores only its commitment) and, like a fresh one, is unavailable while NAV is
fail-closed. On a blocked chain `CANCEL_COMMAND` and a fresh empty list stay available; while NAV is fail-closed only
`CANCEL_COMMAND` does (a fresh empty list is not recovery-marked either). A retried allowlist add cannot re-check its
vaults against the REMOTE_VAULT substrates (the list is not stored): after revoking a substrate, cancel a pending
allowlist update instead of retrying it. Every DEPOSIT into such a vault is still checked at send and at retry. The supply path on a blocked chain is not checked
explicitly by the fuse or the executor: it is stopped by the NAV fail-closed `ChainBlocked` revert in `computeNavSD`,
either in the supply fuse's `getBalance()` read before the send or, for a chain that held no value, in the market
refresh at the end of the vault transaction.

Re-sending a cancel (IL-8579). A lost `CANCEL_COMMAND` can be sent again, but every send costs the executor a LayerZero
fee, so repeats for the same command are metered: `cancelCommand` reverts
`CancelCooldown(chainId, commandId, nextAllowedAt)` until `CrosschainConstants.CANCEL_COMMAND_COOLDOWN` (10 minutes)
has passed since the previous send. The cancel stays terminal: `retryCommand` keeps reverting `CancelInFlight` for that
command. The timestamp lives in `ActiveCommand.lastCancelAt` and is cleared whenever the slot is freed or reused.

Deployment (IL-8600): the new command fuse calls the executor's new `activeCommandAction` and `activeCommandTarget`
getters, so `RETRY_COMMAND` reverts against executors deployed before IL-8600 until they are redeployed (Stargate also
needs the re-linked command-builder library), and the old command fuses must be removed from vaults or the gap stays
reachable. Both fields are written by `buildBusinessCommand`, which lives in the linked `StargateExecutorCommandLib`
since the IL-8551 size round (before it, in `StargateExecutorAccountingLib`). For an executor of an older build that
still takes its builders from `StargateExecutorAccountingLib`: a library built before IL-8625 has other
`buildBusinessCommand` / `buildRetry` signatures, so an executor linked to it reverts on every send; a library built
between IL-8625 and this follow-up has the same signatures and writes `action` but not `target`: every retried
DEPOSIT then reverts `CrosschainFuseRemoteVaultNotGranted(chainId, 0)` (fails safe, `CANCEL_COMMAND` still works).
Check after deploying: send a DEPOSIT through the fuse and, before it is delivered, `activeCommandAction(chainId)` must
return 1 and `activeCommandTarget(chainId)` must return the DEPOSIT's vault.

## Remote vault allowlisting rules (IL-8607 / IL-8608 / IL-8609)

**No exit fee on allowlisted vaults (IL-8607).** The dispatcher values remote shares with `convertToAssets`, which
ERC-4626 permits to exclude exit/withdraw fees, so an attested position can be priced above what a redeem returns.
Allowlist only remote vaults that charge no exit or withdraw fee, or make the attesters report net-of-fee value.
`convertToAssets` is kept for consistency with core Fusion's `Erc4626BalanceFuse`; the overstatement is bounded by
the vault's exit fee.

**Withdraw-manager discovery reads the legacy slot too (IL-8608).** `plasmaVaultWithdrawManager()` runs inside the
remote vault through `UniversalReader.read` and returns the manager with the legacy fallback
(`getWithdrawManagerAddressWithLegacyFallback`): the corrected ERC-7201 slot first, then
`WITHDRAW_MANAGER_LEGACY_SLOT`. This deliberately differs from the "new code reads the corrected slot only" rule,
because a vault deployed from a pre-IL-6952 base keeps its manager in the legacy slot and a corrected-slot-only read
would return `address(0)`. A zero command manager or a vault with no manager in either slot is rejected with
`WithdrawManagerUnresolved(vault)`; a non-zero mismatch stays `WithdrawManagerMismatch`.
Edge cases: on a legacy vault where `UpdateWithdrawManagerMaintenanceFuse` wrote the corrected slot, the corrected
slot wins (it fails closed if the vault's own code still reads the legacy slot). Vaults predating `UniversalReader`
have no `read` and always NACK.

**Redeem floors are shared decimals (IL-8609).** `minAssets` of REDEEM and REDEEM_FROM_REQUEST is carried in shared
decimals on both transports and compared with the measured local-decimal receipt after `_toLD`. Both dispatchers
apply `_toLD` exactly once: CCIP normalises in the executor (its fuse takes local decimals), while Stargate forwards
the value verbatim (its fuse takes shared decimals).

Migration: Stargate scripts that built `minAssets` in local decimals (the previously documented unit) now NACK on
routes where local differs from shared decimals (e.g. WETH 18/6); routes where they match (e.g. USDC 6/6) are
unaffected.
