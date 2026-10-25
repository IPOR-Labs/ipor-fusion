# Chainlink CCIP cross-chain transport

This directory contains a transport-isolated alternative to the existing
Stargate/LayerZero stack.

## Components

- `CcipCrosschainFactory`: deterministic CREATE3 executor/dispatcher deployment,
  factory-to-factory tickets and manager executor enumeration.
- `CcipCrosschainExecutor`: source-side NAV buckets, send, recall and claim.
- `CcipCrosschainDispatcher`: authenticated token+data receive, tracked remote
  idle, ERC-4626 deposit/redeem and withdraw-request (`REQUEST_SHARES`, `REDEEM_FROM_REQUEST`) commands.
- `CcipAppBase`: Router, selector, peer and replay checks; sends go through the linked `CcipSendLib` (route-policy
  gas binding, fee ceiling, scoped approvals) and route writes through the linked `CcipRouteLib`.
- Linked libraries (EIP-170; IL-8659 added `CcipDispatcherLib`, IL-8660 / IL-8551 moved more bodies out):
  `CcipExecutorAttestationLib`, `CcipExecutorCommandLib` and `CcipExecutorTransferLib` hold most executor bodies,
  `CcipDecimalsLib` its decimal conversions, `CcipDispatcherLib` the dispatcher's vault-set configuration and
  removal sweep;
  `CrosschainVaultActionLib` and `RescueLogicLib` are shared with Stargate. They run by delegatecall on the host's
  storage; the host ABIs mirror their events and errors in `ICcipExecutorLibraryAbi` / `ICcipDispatcherLibraryAbi`
  (kept complete by `CrosschainLibraryAbiCompletenessTest`). A library change means re-pinning it in the
  `crosschain_deploy` profile and re-linking its hosts.
- `CcipCrosschainSupplyFuse` / `CcipCrosschainCommandFuse`: PlasmaVault delegatecall integration.

The contracts use the minimal EVM ABI from Chainlink CCIP Client/Router v1.6.1,
declared locally in `interfaces/CcipClient.sol`. This avoids forcing the
repository's legacy Chainlink Feed Registry dependency from 1.2.0 to 1.4.0.

The live Ethereum, Base and Arbitrum lanes run CCIP 2.0 (OnRamp/OffRamp 2.0.0
with the packed MessageV1 codec). The application-facing ABI used here —
Router `ccipSend`/`getFee`, `ccipReceive` and the Client message structs — is
unchanged in 2.0, so the contracts are unaffected; off-chain parsers of
OnRamp/OffRamp events must target the 2.0 layout. CCIP 2.0 also ignores
`allowOutOfOrderExecution = false` and lets anyone execute a message, so
responses can arrive out of order (see IL-8496).

## Invariants

- One executor belongs to one transport.
- Existing `EXECUTOR(address)` and `REMOTE_VAULT(chainId,address)` substrates
  are unchanged.
- Router authentication is followed by selector and peer authentication.
- Route identity (`chainSelector`, `peer`) is immutable after first registration. Fee token, gas limits,
  fee ceiling and enabled state are delivery policy sourced from the timelocked local factory.
- A CCIP `messageId` and an application operation ID are processed once.
- Token callbacks accept only the configured asset: exactly one entry on an outbound delivery, at most one on a
  `RETURN_TRANSFER` (no entry is a zero delivery, IL-8635).
- Direct donations are not added to NAV.
- The executor and every one of its dispatchers have the same CREATE3 address.
- The factory has the same CREATE3 address on every participating chain even
  though its chain-specific Router immutable differs.
- Source outbound value moves to remote settled only on authenticated ACK.
- Recall credits idle only with a physically delivered token.
- A recall above the local token pool's outbound rate-limit CAPACITY (`TokenMaxCapacityExceeded`, permanent until the
  pool admin raises it) is answered `RETURN_REJECTED(ABOVE_POOL_CAPACITY)` before any value moves, and neither
  `trackedIdle` nor `stateVersion` changes. A transient `TokenRateLimitReached` still queues the
  `RETURN_TRANSFER` and `flushResponse` retries it (IL-8553). The reject applies only when the recall meets an
  empty response queue; a recall queued behind an occupied head can still stick later in `flushResponse` and then
  needs the `scheduleSkipStuckResponse` + executor `ADVANCE_FRONTIER` rescue (TP-M-05 family); that
  `ADVANCE_FRONTIER` clears the cancelled-recall clock of the chain only once the reset guard window has passed
  (otherwise it keeps the clock; see checklist item 6, IL-8590). Only the
  `TokenMaxCapacityExceeded` selector of Chainlink's `RateLimiter` is recognised; other permanent limits (a CCTP
  USDC pool's per-message burn limit, which reverts with a string; the CCIP 1.5 OnRamp
  `AggregateValueMaxCapacityExceeded`, not present on 1.6/2.0 OnRamps) are not.
- CCIP token pools may charge a fee or apply a haircut (the pool owner is a trusted external party), so the
  destination can receive less than a supply sent. The credit that arrived is booked and the shortfall is a realized
  NAV loss; the chain is NOT blocked. Settlement emits `SettledCreditShortfall(chainId, operationId, amountSD,
  receivedSD)` whenever `received < amount`, and additionally `SettledBelowMinDelivered(chainId, operationId,
  minDeliveredSD, receivedSD)` when the supply fuse's optional `minDelivered` floor (local decimals, `<= amount`,
  0 = none) was missed; both are observability only and never revert, because the tokens have already moved. They
  are also emitted by a late settle that credits nothing (balance already attested, IL-8619, or already credited by a
  crediting force-resolve, ignored as `"credited"`), without any `settled` write. On the return leg
  `ReturnFinalized.sentSD - received` is the pool fee, and `minReturn` is checked by the dispatcher against the gross
  amount, before that fee (IL-8581).
- Supply amounts are floored to the shared-decimals unit (IL-8634): `CcipCrosschainSupplyFuse.enter` clamps `amount`
  to the vault's raw asset balance, then floors it to a multiple of the executor's `DECIMAL_CONVERSION_RATE` before the
  transfer and send. The sub-unit dust stays in the vault, so a third party donating 1 wei cannot make a clamped supply
  revert `AmountHasDust`; an amount that floors to 0 returns early (no transfer, no send, no event), and an explicit
  misaligned `amount` is floored rather than rejected. Flooring never pushes the amount below a unit-aligned
  `minDelivered` (the floor is the largest multiple not above the clamped amount); a misaligned `minDelivered` still
  reverts `AmountHasDust`, and `InvalidMinDelivered` stays reachable only through the clamp (vault balance below
  `minDelivered`), unchanged.
- The return leg debits `settled` by the amount the dispatcher declared it sent (clamped to the recall's
  `maxAccounted` and to `settled`), and credits idle with the amount actually received. The transport fee
  (sent - received) is therefore a realized NAV loss at finalization, like on the supply leg (`ReturnFinalized` /
  `LateReturnFinalized` carry a trailing `debitedSD`, the debit actually applied, bounded by
  `min(maxAccounted, settled)`; `sentSD - received` remains the fee), and a full
  recall leaves `settled == 0` only when the declared send covers the whole bucket; a return that sends less
  (the dispatcher returns at most `trackedIdle`) leaves `settled` and the anchor at a pro-rata residue that
  still carries all of any unrecognised remote loss. Once that loss puts the true value below the attestation
  band, the residue is cleared only through reject-and-block plus the timelocked `FORCE_SET_SETTLED` rescue
  (IL-8585). `minReturn` is enforced by the dispatcher on the sent (pre-fee) amount.
- Remote NAV is reconciled from tracked idle plus ERC-4626
  `convertToAssets(dispatcherShares)` using monotonic dispatcher state versions.
- The dispatcher `stateVersion` counts value-moving transitions only (IL-8257): it is bumped once per
  `TRANSFER_SETTLED` and once per `RETURN_TRANSFER` response it produces. `BALANCE_REPORT`, `COMMAND_ACK`,
  `COMMAND_NACK` and `RETURN_REJECTED` carry no bump; `BALANCE_REPORT` and `COMMAND_ACK` carry the current
  version as evidence only. The executor frontier (`lastRemoteStateVersion`) advances solely on
  `TRANSFER_SETTLED` and `RETURN_TRANSFER` (exactly `frontier + 1`, a gap reverts, a stale version is ignored);
  value-neutral responses emit `RemoteBalanceUpdated` and never read or write the frontier, so CCIP 2.0
  reordering cannot make them overtake and discard a pending value response.
- Approvals are scoped to one Router call and reset to zero.
- Only the factory owner can change who may create executors (`setCreationRestricted`, `setCreatorAllowed`).

**Gas limits are bound to route policy.** The destination gas limit of every executor send is bounded by the
timelocked route policy the factory synchronises (`syncRoutePolicy`): `tokenGasLimit` for a send that carries
tokens, `messageGasLimit` otherwise. The `gasLimit_` argument chosen by the manager (ALPHA, through the CCIP
fuses) is interpreted as: `0` means "use the route policy", a value above the policy is clamped to it (the quote
cannot be inflated), and a non-zero value below the policy reverts with
`CcipGasLimitBelowRoutePolicy(supplied, policy)` (a token transfer cannot be under-gassed). An enabled route must
carry non-zero `messageGasLimit` and `tokenGasLimit` (`CcipRouteGasPolicyUnset` otherwise). Dispatcher responses
and the factory's ACK/NACK always use the route policy. The deployment ticket is the one exception: it uses the
separately timelocked `dispatcherDeploymentGasLimit[chainId]`. Because the manager can no longer raise the limit
per send, `messageGasLimit` must be sized for the heaviest message the executor originates
(`sendCommandToDispatcher`, the recall path of `requestAssetsFromDispatcher`, `UPDATE_VAULTS` at the vault cap)
and `tokenGasLimit` for a token receive, and `maxFee` must cover the fee quoted at those limits, otherwise every
send reverts `CcipFeeTooHigh`.

**UPDATE_VAULTS gas budget (IL-8617).** `messageGasLimit` must also cover a maximum-size (32 vault) `UPDATE_VAULTS`.
The Stargate dispatcher, which persists the command bytes and installs the allowlist the same way, measures 3.07M gas
for a fresh 32-vault install (about 0.63M fixed plus 76k per vault; see the Stargate README, "UPDATE_VAULTS gas budget"),
and its reference command-lane option is now 4,000,000. The CCIP dispatcher stores the same payload before its budget
check (measured in `CcipPreCheckPinTest`: about 1.09M of pre-check work for 32 vaults, already part of the budget
formula below) and has the same business cost, so size `messageGasLimit` for the larger of this message and the
recall path, with at least 25% headroom (at least 2,700,000, rounded up from the 2,628,000 minimum route gas of a
32-vault UPDATE_VAULTS, see below). The IL-8602 per-vault read cap (200,000 gas, about 208k pre-check) applies:
the UPDATE_VAULTS ACK carries `_reportedBalance()`, so size it like the recall (see the IL-8602 gas section).

**Command gas budget and out-of-gas handling (TP-M-47 / IL-8625, TP-L-13 / IL-8641 closed by the catch reserve).**
Every `Command` (COMMAND and UPDATE_VAULTS) carries `minExecutionGas`, set by the executor at send time to
`routeGas - COMMAND_PRE_CALL_BASE (500,000) - COMMAND_PRE_CALL_PER_WORD (24,000) x words`, where `words` is the 32-byte
word count of exactly what the dispatcher stores before the check (`abi.encode(type, command, extra)`; an UPDATE_VAULTS
pays for its vault list) and `routeGas` is the route's `messageGasLimit`. The router forwards the gas limit exactly, so
there is no `routeGas / 64` term on CCIP (Stargate has one). The executor resolves the effective gas exactly as
`CcipSendLib.send` does (0 or above policy is clamped to it, below reverts) and refuses to send, reverting
`CommandLaneGasTooLow(routeGas, requiredRouteGas)`, when the budget would be below `COMMAND_EXECUTION_MIN_GAS` (1,000,000).
Route minimums follow from the formula: a DEPOSIT needs about 1.84M, an empty UPDATE_VAULTS about 1.86M, a 32-vault
UPDATE_VAULTS (47 stored words) 2.63M; set `messageGasLimit` to at least 2,700,000 (CcipPreCheckPinTest pins all of it).
The budget is part of the committed bytes (`commandCommitment = keccak256` of the stored data), so a deliverer cannot lower
it. `CcipMessages.VERSION` is 3 so a mixed old/new pair fails `InvalidVersion`. Calibration of the two constants (cooled
with `vm.cool`, direct `ccipReceive`, 2,500 added for every touched account; `CcipPreCheckPinTest`): pre-check work 321k / 344k / 544k /
725k / 1,087k for 14 / 15 / 23 / 31 / 47 words (about 23.2k per word overall, 25.1k between 15 and 23 words, so 24k per word
is not a per-step bound), covered by 500k + 24k per word with at least 508k of margin (asserted at 100k). The real Router's own overhead is outside the receiver's gas limit. The real-endpoint cold
calibration is the Stargate one (`stargate/README.md`).

The rule: a delivery that reaches the business call with less gas than the budget reverts `InsufficientGasForCommand`
(checked right before the capped self-call, after the storage writes; the revert rolls them back and the message is
re-run by manual execution with more gas). At or above the budget EVERY failure of the business call is a business
failure (FAILED + NACK), whatever the revert data says: a decodable error, an empty revert, an out-of-gas,
`InsufficientGasForVaultRead` (the lane is too small for the tracked set) or an OpenZeppelin wrapper. There is no
classification of revert data. The self-call is capped at `gasleft() - COMMAND_CATCH_RESERVE_GAS`, so a callee that burns
its gas still leaves the catch frame enough to persist FAILED and send the NACK (`MIN_NACK_GAS` guards the send).
RETRY_COMMAND re-runs the STORED budget; the executor refuses a retry (`RetryGasBelowCommandBudget`) whose effective gas is
below what the stored budget needs (the same formula inverted), which can only happen if the route policy was lowered after
the original send.

**Lane sizing (mandatory).** Because an attacker can always deliver at exactly the budget, the route gas must satisfy
route gas >= the measured cold gas of the heaviest action of every allowed vault + the pre-call work of its payload
(`COMMAND_PRE_CALL_BASE` + `COMMAND_PRE_CALL_PER_WORD` per stored word, folded into the budget formula above) +
`COMMAND_CATCH_RESERVE_GAS` (400,000) (CCIP has no endpoint hop loss: the Router forwards the gas limit exactly). In practice: measured redeem + about 1,000,000. Reviewer lower
bounds for a real REDEEM alone: IPOR USDC Prime Arbitrum 0.77M, Base ETH Lending Optimizer 1.75M, Base USDC Lending
Optimizer 1.77M, TESS USDC Ethereum 3.26M, Harvest USDC Base 4.00M, Harvest WETH Base 7.26M, so 2M and 4M routes are too
small for several ordinary REDEEMs. Re-measure whenever a vault's curator adds markets. Residual: a route sized too
tightly turns an honest delivery into a FAILED + NACK. CCIP delivers exactly the route's gas limit and a NACKed message
is a SUCCESSFUL execution on the OffRamp, so there is no override and no manual re-execution to add gas; the way to give a
command more gas is a TIMELOCKED route-policy raise (`syncRoutePolicy`) followed by `retryCommand`, whose gas limit is
clamped to the new policy and which re-runs the stored budget (`CcipCommandOutOfGasTest.testShouldNackATightRouteAndRecoverWithAPolicyRaiseThenARetry`),
or cancelling and re-sending. A manager-supplied `Command.minExecutionGas` cannot exceed the derived budget (it reverts
`CommandBudgetAboveLane`) and the 14M cap (`CommandBudgetAboveMax`). A real liquidity shortfall (a REDEEM above the vault's
instant liquidity, including on WETH9- or USDT-shaped tokens whose empty revert SafeERC20 wraps) and a real permission or
price-feed refusal NACK within the delivery, so the manager can cancel and send a smaller command in the same block.

**Deployment note (IL-8625).** `Command` and `UpdateVaults` gained `minExecutionGas`, so the command fuses' calldata
(`CcipCommandFuseEnterData.command`) changed: redeploy the CCIP and Stargate command fuses and re-grant them.
`CcipMessages.VERSION` is 3: a mixed old/new executor-dispatcher pair fails `InvalidVersion`, so deploy executors and
dispatchers together, built together. The linked libraries `CcipExecutorCommandLib` (its `build` takes a `BuildParams`
struct and the executor's payload-word mapping, `requireRetryGas` changed) and `CcipSendLib` (new `commandGasLimit`)
changed: re-pin them in `crosschain_deploy` and re-link the executors (the Stargate libraries `StargateExecutorAccountingLib`,
`StargateExecutorDeploymentLib` and `StargateLzSendLib` changed too). The executor gained a payload-word mapping appended
after all existing state, so no existing slot moved. Routes registered with `messageGasLimit` below the payload's minimum
(see the formula above; 2,628,000 for a 32-vault UPDATE_VAULTS) refuse the matching sends until the policy is raised
through the timelocked `syncRoutePolicy`.

**Per-message gas cap and the deadline.** CCIP lanes also cap the gas of one message (the destination FeeQuoter's
`maxPerMsgGasLimit`, commonly 3,000,000; verify it per lane before sizing a route), so a REDEEM measured at 3.26M - 7.26M may
never run over CCIP at all, and the timelocked route-policy raise cannot exceed that cap either. `MAX_COMMAND_EXECUTION_GAS`
(14M) is the Ethereum transaction cap (EIP-7825) bound, not a CCIP limit. An undeliverable command can never wedge the lane:
the dispatcher checks the command DEADLINE before the budget (`_runCommand`, first run and retry; inclusive as before), so once
`COMMAND_TTL` (24h) has passed an execution with enough gas to send the NACK records FAILED + NACK without a business call
(the NACK carries only `(commandId, sequence)`; the expired path emits the same `CommandFailed`), and the manager's
`CANCEL_COMMAND` is answered with an `EXPIRED` receipt that frees the lane (see "Expired cancel" below), no ABANDON and no
admin. Before the deadline a below-budget execution still fails on the OffRamp. The executor refuses a RETRY of a command
already past its deadline (`CommandExpired`): it can only end in a NACK and would waste the fee; a retry sent before the
deadline and delivered after it is NACKed the same way. The CCIP executor also bounds the STAMPED budget by
`MAX_COMMAND_EXECUTION_GAS` (`CommandBudgetAboveMax`), so a route policy above 14M plus the pre-check work refuses commands. A
manual execution adds about three 63/64 hops (roughly 0.4M of headroom at the cap), moot under the FeeQuoter per-message cap.

## Fee budget and executor creation policy

The factory pays every CCIP message it originates from its own native or LINK balance: deployment
tickets sent by `requestDispatcher`, and the deployment ACK or NACK it sends back when it is the
destination. Executors and dispatchers pay their own sends from their own balances.

**Deployment attempt cap (IL-8565 / IL-8605).** Every `CREATE_DISPATCHER` ticket is paid from the factory's own
balance, which all tenants share. `requestDispatcher` therefore counts tickets per `(executor, dstChainId)` in
`deploymentAttempts` and reverts `DeploymentAttemptsExhausted` once `MAX_DEPLOYMENT_ATTEMPTS` (3) have been sent.
A NACK or a `cancelExpiredDeployment` TTL cancel clears the pending ticket but does not reset the counter; a
`DEPLOYMENT_ACK` deletes it. The owner can re-open an executor/chain pair with
`resetDeploymentAttempts(executor, chainId)`, which is immediate and not timelocked because it only re-opens
spending of the owner's own budget. The factory's ticket, ACK and NACK sends are all bounded by the route's
`maxFee`, so the exposure is at most 3 x `route.maxFee` per executor and chain, plus the destination's NACK fee.
The cap is per executor: with `setCreationRestricted(false)` anyone could create executors, each with a fresh budget
of 3 attempts, so creation stays restricted (IL-8069) wherever this bound matters.

**Balance request metering (IL-8579).** `REFRESH_BALANCE` (`requestRemoteBalance`) costs the executor one CCIP fee
(bounded by `route.maxFee`) and queues one `BALANCE_REPORT` in the dispatcher's 64-slot response FIFO. It is therefore
metered per destination chain: one request may be outstanding (`BalanceRequestOutstanding`, cleared by any
`BALANCE_REPORT` from that chain, since reports are evidence only, or once the request is older than the executor's
immutable `BALANCE_STALENESS_MAX`, bounded by `MAX_STALENESS_WINDOW` = 7 days, so a lost report cannot wedge it), and
two requests must be at least `CrosschainConstants.BALANCE_REQUEST_COOLDOWN` (10 minutes) apart
(`BalanceRequestCooldown`).

**Blocked chains (IL-8580).** The command fuse refuses a fresh DEPOSIT and an allowlist-adding `UPDATE_VAULTS`
(`vaultsAllowed` with a non-empty list; an empty replace-all only removes vaults and stays allowed) on a chain the
executor has circuit-broken (`CommandFuseChainBlocked`). Redeems, cancels and `REFRESH_BALANCE` stay open as
repair and observe actions. `RETRY_COMMAND` reads the stored command's action (IL-8600) and is gated like a fresh send
of it: a retried DEPOSIT is refused on a blocked chain, re-checks its target vault against the REMOTE_VAULT substrates
(`commandDepositTarget`; the substrate may have been revoked since the first send) and performs the live
`getBalance()` NAV read like `SEND_COMMAND` (`CANCEL_COMMAND` is the alternative); a retried redeem-type command stays
a repair action; a retried `UPDATE_VAULTS` is refused on a blocked chain whatever its list (the executor does not
store the list) and, like a fresh one, is unavailable while NAV is fail-closed. On a blocked chain `CANCEL_COMMAND` and a fresh
pure-removal update stay available; while NAV is fail-closed only `CANCEL_COMMAND` does (a fresh pure-removal update is
not recovery-marked either). A retried allowlist add cannot re-check its vaults against the REMOTE_VAULT substrates
(the list is not stored): after revoking a substrate, cancel a pending allowlist update instead of retrying it. Every
DEPOSIT into such a vault is still checked at send and at retry. The supply path on a
blocked chain has no explicit `chainBlocked` check in the fuse or the executor: it is stopped by the fail-closed
`ChainBlocked` revert of `balanceByChain`, in the supply fuse's live `getBalance()` read when the blocked chain still
holds value, otherwise in the NAV refresh at the end of the vault transaction (the send has booked `outboundInFlight`).

Diagnostic commands are recovery-marked (TP-M-34, IL-8612). While the market's live NAV is fail-closed, config-changing
commands are unavailable: `REGISTER_ROUTE`, `CREATE_DISPATCHER`, `UPDATE_VAULTS`, `CANCEL_DEPLOYMENT` and the
new-exposure actions are not
recovery-marked, so a batch that holds only them reverts on the end-of-batch NAV refresh. The two value-neutral
diagnostic commands are recovery-marked: CCIP `REFRESH_BALANCE` (`requestRemoteBalance`) here, Stargate
`CANCEL_DISPATCHER_REQUEST` in the Stargate README. They move no value, so a batch containing only one of them completes
(single executor: cached value served; several executors: the marked executor's `getBalanceUnchecked()`
when it is only stale, see IL-8611).
Trade-off: every recovery-marked command widens the surface on which the cached / unchecked fallback can be served, so
only commands that cannot move value qualify.

Consequences: the recovery marker is reachable at will via `REFRESH_BALANCE` (bounded only by the 10-minute request
cooldown), so the cached / unchecked fallback can be reached during any fail-closed window, not only inside a claim /
recall repair. A batch carrying REFRESH_BALANCE or CANCEL_DISPATCHER_REQUEST cannot also hold a DEPOSIT or a supply: the
marker and the new-exposure flag are mutually exclusive in one transaction (`RecoveryExposureBatchForbidden`).

**Deployment (IL-8600).** The new command fuse calls the executor's new `commandAction` and `commandDepositTarget`
getters, so `RETRY_COMMAND` reverts against executors deployed before IL-8600 until they are redeployed, and the old
command fuses must be removed from vaults or the gap stays reachable. `commandDepositTarget` decodes the stored action
data in `CcipExecutorCommandLib`, so the executor and that library must come from the same build.

`requestDispatcher` is callable by the `MANAGER` of any registered executor and takes no payment from
the caller. Each call pays the router quote, capped by the caller's `maxFee_` and by the timelocked
route ceiling `route.maxFee`; the quote is priced on the ticket, whose `vaults` list the caller chooses. The list
is shape-checked before the fee is paid (at most 32 entries, no zero address, no duplicate), as in
`updateVaults`.

Per executor and destination chain the factory holds at most one open ticket and sends none once the
dispatcher is acknowledged (`hasDispatcher` on the executor is set by the ACK and not cleared).

A pending ticket is cleared by the destination's ACK or NACK, or by `cancelExpiredDeployment` strictly after
`DEPLOYMENT_TTL` (7 days) plus `DEPLOYMENT_CANCEL_MARGIN` (24 h) for the factory owner and the executor's manager,
and after a further `DEPLOYMENT_CANCEL_GRACE` (3 days) for everyone else (IL-8637; see "Deployment ticket expiry
(IL-8623)" below). A NACK clears it at once, so the manager can request again in the next transaction.

The destination answers every deterministic rejection with a NACK instead of reverting (IL-8561, IL-8636).
Reason codes (relayed in `DeploymentNack`, informational): `1` the predicted address is occupied by another
ticket; `2` asset not enabled, shared-decimals mismatch, creation code not configured or CREATE3 failed;
`3` the dispatcher rejected the vault list (`InvalidVault`: no code or a different `asset()`, e.g. a vault
that changed after the ticket was sent; `VaultsCapReached`). The deployment runs in a self-call
(`deployDispatcherForTicket`), so a NACK leaves no state behind: the ticket is not consumed, nothing is
registered, and the same ticket re-delivered gets the same answer. Only transient failures still revert the
whole receive and leave the ticket pending until the message is re-executed manually or the TTL cancel: the
ACK/NACK send itself (fee budget or ceiling) and gas exhaustion. An out-of-gas deployment is not guaranteed to
revert: each nested call frame keeps 1/64 of its gas when the callee runs out and the deployment is three frames
deep (self-call, CREATE3 proxy, CREATE), so with a large ticket gas limit it can leave more than 200,000 gas and be
answered NACK(2) (the fee is lost and the ticket is freed, no inconsistent state; CCIP marks the message SUCCESS,
so there is no manual re-execution). The factory therefore also reverts (`InsufficientGasForNack`) when the
attempt consumed more than 90% of its gas, and when less than 200,000 gas remains; those receives stay
retryable. The IL-8623 expiry sanity bound (`TicketExpiryOutOfRange`) and migration gate
(`DestinationAssetMigrationScheduled`) also revert retryably instead of answering NACK (see below).
`dispatcherDeploymentGasLimit` must be sized for the largest vault list (mock measurements: about
5.7M gas with no vaults, about 8.7M with 32 vaults, about 95k per vault); the 6M `DEPLOY_GAS` used in tests is
too low for a 32-vault ticket.

The ticket carries no nonce: its hash covers only the salt, executor, chains, asset, shared decimals,
`vaults` list and the rescue admin, guardian and delay. A dispatcher orphaned because its ACK was lost or
arrived after `cancelExpiredDeployment` is adopted either directly by that late ACK (IL-8637, see "Late ACK after
a cancel" below) or by re-requesting with byte-identical ticket inputs: the same `vaults` list in the same order
and the same rescue admin, guardian and delay. The destination then re-ACKs the identical ticket. Any change
produces a different hash, and the destination answers NACK(1) (address occupied) for that executor and chain
permanently. A late ACK matching a cancelled ticket is accepted directly while its hash is in the cancelled set; the
byte-identical re-request stays the fallback. Pinned by `CcipFactoryDeploymentRecoveryTest`.

What bounds the spend is executor creation. A creator allowed by `createExecutor` can mint executors
limited only by gas (the CREATE3 salt is derived from the creator and a caller-chosen `userSalt_`) and
chooses each executor's manager.

Policy (IL-8104, applying the decision recorded for IL-8069 for the Stargate factory): `creationRestricted`
stays `true` in production and only IPOR-operated addresses are allowlisted with `setCreatorAllowed`. The
factory budget is an IPOR-funded operations budget spent by IPOR's own executors. The policy setters
(`setCreationRestricted`, `setCreatorAllowed`) are `onlyOwner`; `CcipFactoryBudgetPolicyTest` pins the
default, the setters and the per-ticket bounds above.

If a third party is allowlisted, or creation is opened, that party can spend the source factory's budget
once per executor per destination, and — if it can also create executors on the destination factory —
occupy the ticket's CREATE3 address there so that every ticket is NACKed at the destination factory's
expense and re-requested at once. That loop is bounded by CCIP delivery latency and the party's gas, not
by any factory limit.

Opening creation to third parties therefore needs per-creator fee accounting on both the source and the
destination factory first; that is a redesign of this contract, not a configuration change.

A drained budget stalls the deployment lane only: on a native-fee route, new tickets and, at a
destination, ACK/NACK sends fail with `CcipInsufficientNativeFeeBalance`; a factory `ccipReceive`
whose send fails reverts as a whole.
NAV, transfers, commands and attestations run on executor and dispatcher balances. Anyone can refill the
factory through `receive()`; the owner can recover funds with `sweepNative` and `sweepToken`.

### Deployment ticket expiry (IL-8623)

- The `CREATE_DISPATCHER` payload is now `abi.encode(DeploymentTicket, uint256 expiresAt)`; `expiresAt = createdAt +
  DEPLOYMENT_TTL` (7 days). It sits next to the ticket, not inside it, so the ticket hash stays identical across
  re-requests (IL-8486 late-ACK recovery is unchanged). Wire-format change: all factories sharing a CREATE3 address
  must run the same build; never extend an existing factory set to a new chain with this build and never mix
  versions. On CCIP a version mismatch decodes silently (the old payload's `expiresAt` reads the salt word); the
  destination sanity bound rejects it: `expiresAt > block.timestamp + MAX_DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN`
  reverts `TicketExpiryOutOfRange` (retryable).
- `DEPLOYMENT_TTL` (7 days) is also the delivery deadline, including time spent on the CCIP manual-execution path.
- Stale NACK(4) guard: the ticket hash is identical across re-requests, so a NACK(4) answering a previous request
  could close an identical fresh one. The source reverts a reason-4 NACK (`PrematureExpiredNack`, retryable) until
  `pendingDeploymentCreatedAt + DEPLOYMENT_TTL` of the current request; later it is harmless (the request is expired
  anyway).
- Destination: an unconsumed ticket delivered at or after `expiresAt` is answered NACK reason 4 and not deployed; an
  occupied address is still NACK(1) first, and an already consumed ticket is still re-ACKed. The NACK does not emit a
  dedicated expiry event on CCIP; the source emits `DeploymentNack` with reason 4.
- Source: `cancelExpiredDeployment` is allowed strictly after `createdAt + DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN`
  (24 h; the destination clock may lag the source by up to the margin) for the factory owner and the executor's
  manager, and strictly after a further `DEPLOYMENT_CANCEL_GRACE` (3 days) for everyone else (IL-8637).
- Migration gate: `scheduledAssetCount[assetId]` counts unexecuted `scheduleAsset` commitments (decremented on
  `executeAsset` and on `cancelScheduledConfig`; re-scheduling an identical commitment counts once). A fresh ticket
  for an asset that is not frozen and has a non-zero count reverts `DestinationAssetMigrationScheduled` (retryable)
  before deploying. Runbook: before `executeAsset` on a CCIP destination, every unexecuted `CREATE_DISPATCHER` for
  that asset must be delivered or past its `expiresAt` (now also enforced by this gate for unexpired tickets).

#### Late ACK after a cancel (IL-8637)

- A deployment cancel never reaches the destination. A ticket delivered before its `expiresAt` can still deploy, and
  its DEPLOYMENT_ACK can arrive (manual execution) after the source cancelled.
- `cancelExpiredDeployment` records the dropped hash in `isCancelledDeploymentTicket[executor][chainId][hash]` and in
  `cancelledDeploymentTicket[executor][chainId]` (the last cancel only, for monitoring). A DEPLOYMENT_ACK whose hash
  is in the set is accepted while no other ticket is pending and the executor has no dispatcher on the chain; its
  entry and `cancelledDeploymentTicket` are cleared and `DeploymentLateAcked` is emitted (any other cancelled hash
  stays set but is inert: `hasDispatcher` refuses every further ACK). The slot was freed at cancel, so there is
  nothing to release. The normal ACK branch also deletes the record (defence in depth; `markDispatcherReady` and
  `initializeRoute` are idempotent).
- Every cancelled hash is kept in `isCancelledDeploymentTicket[executor][chainId][hash]` (IL-8637 R2), next to
  `cancelledDeploymentTicket` (the last one, for monitoring). A second cancel of a different ticket therefore no longer
  orphans the first ticket's late ACK. At most one of the cancelled hashes can ever be ACKed: the destination deploys
  one ticket per executor and answers NACK(1) to any other, and `hasDispatcher` refuses every ACK after the first.
- Cancel is exclusive to the factory owner and the executor's manager from `expiresAt + DEPLOYMENT_CANCEL_MARGIN`;
  third parties only after a further `DEPLOYMENT_CANCEL_GRACE`. A PlasmaVault that is the executor's manager cancels
  through the command fuse's `CANCEL_DEPLOYMENT` (IL-8637 R1), which is not recovery-marked (unlike the Stargate
  `CANCEL_DISPATCHER_REQUEST`): while NAV is fail-closed a batch holding only it reverts on the end-of-batch refresh,
  and the factory owner (or anyone after the grace) cancels instead; batched with a recovery-marked command such as
  `REFRESH_BALANCE` it goes through, which is harmless since a cancel moves no value.
- A ticket has no nonce (IL-8637 R3): a re-request with identical inputs has the hash of the cancelled ticket, and the
  NACK branch only checks that the pending hash equals the NACK's. A reason 1-3 NACK that answered the cancelled ticket
  and arrived after the cancel fails (`UnknownDeploymentAck`) and stays executable on the OffRamp; once the identical
  ticket is pending again, anyone can execute it and close the fresh ticket with the old reason. For reason 1 that is
  still true; for reasons 2 and 3 the fresh ticket may have been deployed, and its ACK still lands through the late
  path. Reason 4 is bound to the fresh request's own TTL (`PrematureExpiredNack`). Operations: treat a
  `DeploymentNack` whose hash is in `isCancelledDeploymentTicket(executor, chainId, hash)` as suspect, and before sending a
  new ticket check on the destination whether the dispatcher already exists (`consumedTicket(hash)` on the
  destination factory, or code at the dispatcher address).
- Deployment note: the factory gains the mappings `cancelledDeploymentTicket` and `isCancelledDeploymentTicket` and
  is not upgradeable, so redeploy it. The CCIP command fuse is redeployed and re-granted for `CANCEL_DEPLOYMENT` (an
  older fuse refuses command type 9 when decoding the enum). There is no wire change. The Stargate factory bytecode changes too (see its README), so both
  factories are redeployed.

### Events

Events declare no `indexed` parameters by design: every field is in the data section; filter by emitter address and topic0.

### Tracked-position set

Changes to the dispatcher's tracked-position set emit `VaultTracked(vault)` and `VaultUntracked(vault)`.
Removal is swap-and-pop, so every removal reorders `trackedVaults` and changes `trackedPositionSetHash()`.
Attesters must therefore read `observation()` at the observed block instead of replaying events. A
vault leaving the allowlist is swept (best-effort `redeem` into idle) and ALWAYS untracked in the same command
(IL-8784, below), so on CCIP the tracked set equals the allowlist.

### Removing a vault: sweep, always untrack (IL-8784, D-020 / D-028)

`UPDATE_VAULTS` (removal or replace) first flags the new allowlist, then, for every tracked vault that is no longer
allowed (reverse iteration), calls `CrosschainVaultActionLib.sweepShares(vault)` and untracks the vault; only then are
newly allowed vaults tracked (cap-checked). The whole thing runs in the gas-bounded self-call `runStoredCommand`; the
redeemed assets (measured as the ASSET balance delta, floored to shared decimals) are credited to `trackedIdle`, so
the move into idle is value-neutral and the ACK delta stays 0. Consequences:

- **Replace at the cap works (IL-8629).** Removal happens before adding, so a replacement list disjoint from 32 old
  vaults succeeds, and a failed sweep still frees the slot.
- **Sweep (best effort).** `redeem(min(balanceOf, maxRedeem), this, this)` is a low-level call that is given
  `min(VAULT_SWEEP_GAS, gasleft() - VAULT_SWEEP_RESERVE_GAS)` (2,000,000 and 300,000), D-065. The cap is a safety
  bound, not a promise: redeems served from idle cash measured on a mainnet fork cost 3-market PlasmaVault about
  1.40M, 12-market MetaMorpho about 0.52M, Morpho PlasmaVault about 0.22M (`VaultSweepIdleRedeemForkTest`, a lower
  bound), but a position that is allocated into markets needs more (a cold 100k USDC position in the Ethereum TESS
  USDC Optimiser redeemed at 3.11M uncapped), so the sweep ends as a residual. At most four bytes of revert
  data are copied. A vault failing is never a revert: it emits
  `TrackedVaultSweepResidual(vault, sharesLeft, reason, redeemError, untracked)` (`reason` 1 unreadable balance,
  2 `redeem` reverted or ran out of its cap, 3 partial redeem or `maxRedeem` 0, 4 dust skipped, 5 `redeem` failed
  or was skipped with less than `VAULT_SWEEP_GAS` forwarded; on a 3M lane every sweep is gas-limited, so ANY failed sweep, also a non-gas revert such as `AccountIsLocked` or `restricted`, reports 5: monitoring must read `redeemError`, non-zero = the vault's own revert) and the vault is
  untracked anyway. A clean redeem emits `TrackedVaultSwept(vault, sharesRedeemed, assetsLD)`.
- **Dust is skipped (D-061).** When the dispatcher's shares of the removed vault are worth at most 0.01 asset
  unit (about $30 on WETH, about $1,000 on an 8-decimal BTC-class asset; `10^(decimals - 2)`, read with two gas-capped views: the asset's `decimals()` and
  `convertToAssets(held)`), `redeem` is NOT called: the vault is untracked at once and the residual event is
  emitted with reason 4. A view that fails or is oversized counts as NOT dust (the normal capped path runs).
  Without this rule a 1-wei share donation would make the removal cost a full capped redeem and fail on a 3M lane.
  The cost of the rule is at most 0.01 asset unit of NAV per removed vault.
- **Gas: a RETRY cannot add gas on CCIP.** The route `messageGasLimit` is the hard lane limit (the send and any
  RETRY are clamped to the route policy, and the lane's `maxPerMsgGasLimit` is commonly 3M). The sweep
  therefore never reverts for lack of gas (D-065): it forwards `min(VAULT_SWEEP_GAS, gasleft() - reserve)` and
  keeps the 300,000 reserve for its own bookkeeping, so a single removal fits the lane. Measured cold over the
  real CCIP transport (`VaultRemovalDustForkTest`, Arbitrum IPOR USDC Prime, 3M route, router gas used): 1 wei
  donated 0.98M, ~0.0102 USDC donated (just above dust, redeemed from idle) 1.34M, both ACKed; an unredeemable 2M USDC
  position (about 8x the vault's TVL; exercises the residual path) 2.78M, ACKed, vault untracked, residual reason 5 and
  the whole position drops out of NAV. Realistic 100k to 200k USDC Prime positions are swept fully at 3M (0.84-1.04M
  redeem gas, ACK, nothing left).
  A real allocated position that needs more gas than the lane leaves is thus never swept on a 3M lane; several
  such vaults in one command each get what is left after the reserve, so later ones end as reason 5. The
  no-revert guarantee holds for ONE removal per command: on tight lanes send one removal per UPDATE_VAULTS and adds in
  a separate command (after a gas-limited sweep a later vault's reads can fail, which is a safe NACK: everything rolls
  back and a NACK means "split it"). Redeem to zero
  first (next point).
  On CCIP the COMMAND_ACK prices the tracked set (`_reportedBalance()`) after the self-call returns, outside its cap and catch, on the 400,000 `COMMAND_CATCH_RESERVE_GAS` plus what the self-call left (about 0.25M after a burned sweep), with one capped read per tracked vault and three for a vault with a position, each needing about 208k gas left; size the route for it, otherwise the message fails on the OffRamp and needs manual execution with a higher gas limit.
- **Mandatory procedure (D-060): ALPHA redeems or recalls the position to zero BEFORE removing a vault.** After
  that the removal costs only the dust path (reason 4 or no event at all). The sweep is best effort: a failed
  sweep drops a healthy residual out of NAV until the vault is allowlisted again (see below), so do not rely on it
  to move value. Legitimate redeem failures exist:
  `AccountIsLocked` inside the redemption delay after a DEPOSIT, `WithdrawManager` `canWithdrawFromUnallocated`,
  market illiquidity, `restricted`, `maxRedeem` below the balance, the withdraw fee. The residual shares stay on the
  dispatcher but drop out of NAV (and out of the IL-8556 rescue fence, because the vault is untracked) until the
  vault is allowlisted again; a large residual can push the next balance proposal outside the executor's
  `bigChangeBps` and anchor band. Allowlisting the vault again tracks it immediately (CCIP tracks on allowlisting).
  Alert on `TrackedVaultSweepResidual` and re-allowlist the vault to bring a healthy residual back into NAV.
- **Blocked chain.** A pure removal is allowed while the chain is blocked, but a re-add is refused and REDEEM /
  REQUEST_SHARES / REDEEM_FROM_REQUEST are gated on `isTrackedVault`. A residual created on a blocked chain has no
  command path until the chain is unblocked: never remove a vault that holds shares on a blocked chain; REDEEM first.
- **No force-untrack, no write-off timelock on CCIP.** Tracked == allowlisted, so `scheduleForceUntrack`,
  `executeForceUntrack` and the CCIP `TrackedVaultWrittenOff` event were removed: remove the vault from the allowlist
  instead (a vault whose reads revert is simply reported as residual reason 1 and untracked). A residual is no
  longer covered by the IL-8556 rescue fence (the vault is untracked), so a generic rescue may move it.
- **Deploy.** Dispatchers are not upgradeable and the factories pin their code hash: new `CcipDispatcherLib`,
  `CrosschainVaultActionLib`, dispatcher code and factory are needed; executors and fuses are unchanged.
- **Monitoring.** Alert on `TrackedVaultSweepResidual`.

## Deployment order

The scripts and the manifest template named in this section and in the test-system gate (`DeployCcipCore`,
`VerifyCcipReadiness`, `SyncCcipRoutePolicy`, `deployments/crosschain/ccip-test.template.json`) are not part of
this branch (dropped in IL-7802); the steps and variable lists below describe what they did.

1. Verify the Router, chain selectors and token support in the official CCIP
   Directory for every lane.
2. Deploy the common `CcipCreate3Deployer` anchor and factory on every chain
   with `DeployCcipCore`. Use exactly the same owner, CREATE2 deployer, anchor
   salt and factory salt. Require the reported factory address to be identical.
3. Configure the creation code stores (`configureCreationCodes`, one-shot) and the local asset mapping
   (`scheduleAsset`, then `executeAsset` after the 24-hour factory timelock).
4. Schedule authenticated factory routes in both directions, wait the 24-hour factory timelock, then execute.
5. Create an executor on the PlasmaVault chain.
6. Add the CCIP fuses and the executor and remote-vault substrates to the PlasmaVault. `registerExecutorRoute` and
   `requestDispatcher` are callable only by the executor's `MANAGER`, so a PlasmaVault manager sends steps 7 and 9
   through the command fuse (`REGISTER_ROUTE`, `CREATE_DISPATCHER`).
7. Register the executor-to-dispatcher route. Later policy changes are permissionlessly synchronized
   from the factory with `syncCcipRoutePolicy(app, chainId)`; callers cannot supply policy values.
8. Fund factory/executor/predicted-dispatcher fee budgets. A dispatcher must
   already have enough native/token fee budget when its first inbound call
   attempts to send an ACK.
9. Request dispatcher deployment and wait for authenticated ACK.
10. Run a small send/settle/recall/claim canary before raising limits.

Environment variables used by `DeployCcipCore.s.sol` contain public deployment
configuration only:

```text
CCIP_ROUTER
CCIP_FACTORY_OWNER
CCIP_ASSET_ID
CCIP_LOCAL_TOKEN
CCIP_CREATE2_DEPLOYER
CCIP_CREATE3_ANCHOR_SALT
CCIP_FACTORY_SALT
CCIP_OWNER_MNEMONIC_INDEX
```

Signing credentials remain external to the repository.

Route and manager-chain scripts additionally consume the reviewed values
`CCIP_FACTORY`, `CCIP_EXPECTED_COMMON_FACTORY`, `CCIP_REMOTE_CHAIN_ID`,
`CCIP_REMOTE_CHAIN_SELECTOR`, `CCIP_REMOTE_FACTORY`, `CCIP_FEE_TOKEN`,
`CCIP_MESSAGE_GAS_LIMIT`, `CCIP_TOKEN_GAS_LIMIT`, `CCIP_MAX_FEE`,
`CCIP_EXECUTOR`, `CCIP_REMOTE_VAULT`, and the relevant fuse/vault addresses.
Start from `deployments/crosschain/ccip-test.template.json`; replace every
`null` before broadcast. `VerifyCcipReadiness` is the mandatory read-only gate.

## Test-system gate

1. Dry-run `DeployCcipCore` against every selected RPC and compare the common
   factory address before any broadcast.
2. Broadcast core deployment and configure both directions of every factory
   lane. Run `VerifyCcipReadiness` on each chain.
3. Deploy CCIP fuses, create the source executor, append (do not replace) its
   executor and remote-vault substrates, and register executor routes. Route
   peer must equal the executor address.
4. Fund the source factory, executor, destination factory and predicted
   dispatcher. Request deployment and wait for the authenticated ACK.
5. Run the manager-chain readiness gate. Then canary: send a small amount,
   wait for settlement, refresh remote balance, recall, claim, and require all
   CCIP buckets and physical balances to be zero.

## REQUEST_SHARES fee ceiling (IL-8603)

`REQUEST_SHARES` carries a fourth action word, `maxFeeShares`, next to `withdrawManager`, `plasmaVault` and `shares`
(`CrosschainMessages.encodeRequestSharesAction`). All three share-valued words are SHARE units of the remote vault and
are never converted (`normalizeActionData` leaves REQUEST_SHARES untouched). The dispatcher snapshots its own
vault-share balance around `requestShares(shares)`; if the
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

## Observability: unpriced tracked vaults (IL-8602)

The valuation behind `observation()` and every response (`TRANSFER_SETTLED`, `RETURN_TRANSFER`, `COMMAND_ACK`,
`BALANCE_REPORT`) skips a tracked vault whose `balanceOf` or `convertToAssets` reverts or returns malformed data (or a
value above `type(uint128).max`, reported as reason 2), so a faulty vault can never block a token-bearing callback or a
recall, given route gas sized as below. The remote balance is then understated. The wire format has no spare field, so
the signal is out of band: `observation()` appends `unpricedCount` and `unpricedCodes` (2 bits per `trackedVaults`
index: 1 = `balanceOf`, 2 = `convertToAssets`, 3 = asset drift), and each response built while a vault is unpriced emits
`TrackedVaultUnpriced(vault, reason)`. Attesters gate on `observation().unpricedCount` and do not approve while it is
not 0; the response events are informational (see "Two `convertToAssets` budgets" below). The executor already fails
closed by staleness without a fresh approved observation.

Runbook for a vault that stays unpriceable: de-allowlist it with `UPDATE_VAULTS` (tracked == allowlisted on CCIP, IL-8784).
The removal sweeps and untracks it whatever the vault does (an unreadable balance is reported as residual reason 1 and
the vault is untracked). This WRITES OFF any remaining position from reports: lower the executor value with the
timelocked `scheduleChainRescue(FORCE_SET_SETTLED, ...)` when the drop exceeds `bigChangeBps` or the anchor band. The
shares stay in the dispatcher and, the vault being untracked, a generic rescue may move them later if it heals (the
IL-8555/8556 vault fence no longer applies). There is no CCIP force-untrack any more.

On the on-chain paths each vault read is capped at 200,000 gas (`TrackedVaultPricingLib.VAULT_READ_GAS`), so a
gas-burning vault cannot starve the response; a read that honestly needs more is reported unpriced (errs low, flagged).
A pre-check reverts with `InsufficientGasForVaultRead` when the caller supplied too little gas to honour the cap, so
size the CCIP route gas limits for the failures expected: about 205k per failed read, up to about 410k per vault
(`balanceOf` succeeds, `convertToAssets` burns), plus one more capped read per vault re-checked by `UPDATE_VAULTS`; if
the limit is short the message FAILS on the OffRamp and is re-run by manual execution with a higher gas limit. A
32-vault set with every first read failing costs about 6.5M (worst case about 13M; de-allowlisting all 32 up to about
19.5M), so the 6M reference limit covers about 27 failing vaults in a normal response. De-allowlisting in removal mode
skips the shape check (only adding validates it) and its untrack `balanceOf` read is failure-tolerant, so a vault that
reverts on every call can still be de-allowlisted; replace-mode `UPDATE_VAULTS` is the alternative de-allowlisting path.

**Two `convertToAssets` budgets (IL-8602 review G-1).** `balanceOf` and `asset()` always get `VAULT_READ_GAS`. For
`convertToAssets` the attestation views (`observation()`, `accountedBalance()`) get `VIEW_CONVERT_GAS` = 2,000,000: they
run as eth_call and block nothing on-chain, and a MetaMorpho V1 vault costs about 40k gas per market cold (about 1.25M
at its 30-market queue limit; honest 12-market vaults need about 460k). The responses (`_reportedBalance`) keep the 200k
budget so a gas-burning vault cannot make every delivery heavy. Consequences for operators:

- Attesters gate on `observation().unpricedCount`, not on events. `TrackedVaultUnpriced` emitted by a response is
  informational: a multi-market vault the view prices can be flagged there.
- Call `observation()` with an explicit high gas limit. Too little gas reverts with `InsufficientGasForVaultRead`; it
  never understates. Worst case is about `trackedVaults.length` x 2.45M (a convert-burner costs about 2.01M with the
  pre-check, plus up to 2 x 200k on `balanceOf` / `asset()`): about 64-77M at 32 vaults, so pass e.g. 80M (providers'
  caps vary; geth's default `--rpc.gascap` is 50M). If the view still reverts, find the burners with direct per-vault
  `convertToAssets` eth_calls over `trackedVaults(i)`, then de-allowlist them (the removal reads on the 200k
  budget, unaffected). This is not a new attestation DoS: one burner already sets `unpricedCount != 0`.
- For the same state, view and response values agree whenever both price a vault, except that responses exclude
  `queuedTokenAmount` while a return is queued (IL-8768); they also differ in which vaults get
  priced. A vault whose cold `convertToAssets` is between 200k and 2M is 0 in a cold response, and a COMMAND_ACK after a
  DEPOSIT / REDEEM on that vault in the same tx reads it warm and prices it, so `RemoteBalanceUpdated.remoteBalance` can
  be lower than `observation().accountedBalance`. Trust `observation()`.
- Allowlisting rule: before allowlisting a vault, measure its cold `convertToAssets` on a fork and accept it only at
  about 1M gas or less. A curator adding markets later can push it up, so re-check periodically.
- Procedure (full recall): the RETURN_TRANSFER response prices with the 200k budget. Before a full recall from a chain
  that holds a vault whose cold `convertToAssets` exceeds `VAULT_READ_GAS`, approve a current attestation first, so the
  recall does not empty `settled` and the IL-8606 residual rule never applies. Otherwise the residual anchor drops to 0
  and only a timelocked `FORCE_SET_SETTLED`, or a later bridge credit that brings the residual back within the anchor
  band, fixes it (no funds are lost). Pinned by
  `testKnownLimitationFullRecallWithOverCapVaultNeedsFreshAttestationFirst` and
  `testShouldKeepSettledNonZeroWhenAFreshAttestationIsApprovedBeforeAFullRecall`.

Gas (IL-8645): a priced vault with shares now costs up to three capped reads (`balanceOf`, `asset`,
`convertToAssets`), each bounded by `VAULT_READ_GAS` = 200,000 (about 205k consumed per capped read that burns its cap;
each read needs about 208k available, the pre-check). Because a read sequence stops at the first failure, the new
reason adds at most one more capped read per vault compared with the IL-8602 numbers above. Scaling the existing
per-read figure (about 205k): a 32-vault set with every first read failing is unchanged at about 6.5M; the worst case
in a normal response grows from about 13M (two capped reads per vault) to about 19.5M (three); the de-allowlisting path
(one more capped read per vault) grows from about 19.5M to about 26M. The 6M reference limit still covers about 27
failing-first-read vaults. These are derived by scaling, not re-measured on a 32-vault fork run.

`unpricedCodes` reasons (2 bits per tracked vault): 1 = `balanceOf` failed, 2 = `convertToAssets` failed or above
uint128, 3 = asset drift (`asset()` reverted, was malformed or is not `ASSET`) (IL-8645). `TrackedVaultUnpriced(vault,
reason)` carries the same code, so reason 3 is visible in the event and in `observation().unpricedCodes`.

**Vault `asset()` is re-asserted (IL-8645).** The allowlist update validates a remote vault once (`code.length != 0`
and `asset() == ASSET`). An upgradeable vault, or one with a mutable underlying, can change its `asset()` afterwards.
Two places now re-assert it:

- DEPOSIT: before any approval the dispatcher reads `IERC4626(vault).asset()`; a mismatch reverts with
  `VaultAssetDrifted(vault, actual)` and the command FAILS with a NACK (nothing approved, deposited or debited, the
  sequence does not advance). A vault whose `asset()` reverts also fails the deposit, which is intended: a deposit into
  a broken vault should fail.
- Pricing: a tracked vault that HOLDS shares is priced only while `asset() == ASSET` (read with the same capped
  `staticcall` and the same `VAULT_READ_GAS` pre-check as `balanceOf` / `convertToAssets`). Otherwise
  `convertToAssets` would be denominated in a different token, so the vault is reported unpriced instead of feeding
  its number into the NAV attestation. A zero-share position is worth zero whatever the asset and is not flagged.
  The asset read happens after `balanceOf` and before `convertToAssets`.

REDEEM, REQUEST_SHARES and REDEEM_FROM_REQUEST are deliberately NOT gated. They only move value out of the vault
(shares burned, ASSET received and measured as a balance delta), grant no approval and cannot be used to push funds
into a vault. Gating them would trap the position in exactly the vault that has become suspect. Exiting a drifted
vault therefore stays possible; if a redeem returns nothing it is the measured delta (`minAssets`) that fails it. Use
`minAssets > 0`: with 0, a drifted vault paying another token burns the shares and credits nothing (that token lands in
the dispatcher, recoverable only by rescue).

A drifted vault that cannot be exited stays flagged unpriced; removing it from the allowlist (`UPDATE_VAULTS`, IL-8784)
is the ejection path on CCIP: the sweep is best effort and the vault is untracked either way. No timelocked path remains.

While a faulty vault is tracked the generic rescue (`executeRescue`) is unavailable, because its share snapshot uses a
plain `balanceOf` (`RescueLogicLib`); it works again once the vault is removed. The `TrackedVaultSweepResidual` event
and `unpricedCount` dropping back to 0 are the attester's signals after the removal. A force-set of the executor value is needed only
when the drop exceeds `bigChangeBps` or the anchor band; otherwise normal attestation suffices.

## Recovery

Do not remove the executor substrate while any NAV bucket or pending record is
non-zero. Stop new CCIP supply, complete remote redeem, recall all tracked idle,
claim to PlasmaVault, verify every bucket is zero, and only then remove the
executor/fuses. Stargate remains independent throughout this procedure.

If a dispatcher FIFO head is above the stored fee ceiling, update the local factory route through its
24-hour timelock, synchronize that policy to the dispatcher, fund the current fee asset and retry
`flushResponse()`. Queued responses resolve delivery policy at retry time, so no skip or token rescue is
required. `chainSelector` and `peer` can never be changed by this process.

**Cached balance during a recovery batch (IL-8564 / IL-8638).** On a market with exactly one executor and the
scoped recovery marker armed by a recovery action (claim, supply exit, `CANCEL_RETURN` / `CANCEL_COMMAND`, a
redeem-type command or `REFRESH_BALANCE`), `CrosschainBalanceFuse.balanceOf` serves the
cached market value only when the executor's `getBalance()` reverts with one of its fail-closed errors
(`ChainBlocked`, `ObservationStale`, `TransferStale` on CCIP; `ChainBlocked`, `NavSettledStale`,
`NavTransferStale` on Stargate) and then emits `CrosschainCachedBalanceServed(marketId, executor, reason)`.
Out-of-gas, `Panic`, `Error(string)` and any other revert are rethrown with their original data (an out-of-gas
reaches the vault as `FailedInnerCall`). A future fail-closed error that is not in this list blocks recovery
batches until the fuse is updated, which is the fail-safe direction.

Cached-NAV fallback with several executors (TP-M-33, IL-8611). The balance fuse used to serve the recovery fallback
only when exactly one executor was granted to the market, because the cached value is one market-wide aggregate that
cannot be decomposed per executor. With two executors any stale or blocked getter therefore made the mandatory
post-execute market refresh revert and rolled back the very claim / recall / retry / cancel that repairs it. Both
executors expose `getBalanceUnchecked()`: the booked balance (`idle + sum(settled + in-flight buckets)`) WITHOUT the
staleness reverts of `getBalance()`. With several executors in the market the fuse substitutes, for the executor that
is recovery-marked in this transaction (`CrosschainRecoveryLib.isRecovery(market, executor)`) AND whose `getBalance()`
reverted with a STALENESS selector (`ObservationStale`, `TransferStale`), that executor's own `getBalanceUnchecked()`;
every sibling is still read with `getBalance()` and keeps its own verdict (an unmarked fail-closed sibling still
reverts), and the market cache is not used. `CrosschainUncheckedBalanceServed(marketId, executor, reason)` is emitted.
A market with a single executor behaves as before (cache fallback with the recovered-USD correction,
`CrosschainCachedBalanceServed`, `ChainBlocked` included). Only one executor can be marked per transaction.

A blocked chain is NOT substituted (follow-up to IL-8611, TP-M-33 review). A blocked chain means the books are
known-inconsistent until a rescue completes. The double count of `DROP_RETURN_METADATA_INCLUDED` is the Stargate
example (see the Stargate README); on CCIP the rule is conservative: it applies the same refusal to every blocked
chain that tracks value, without a CCIP-specific double count being claimed. So a `ChainBlocked` reason from the
marked executor is rethrown, and `getBalanceUnchecked()` itself reverts `ChainBlocked` exactly where `getBalance()`
does: a blocked chain with a non-zero chain total (`settled + outbound`; an empty blocked chain adds nothing, IL-8260)
(a staleness selector can surface first). Known limitation: in a multi-executor market, batches that read a market
whose executor has a blocked chain with value stay blocked until the rescue / force-set completes. The unchecked value
may still be stale for the staleness case; it is the state the fail-closed gate refused to price, it is never used to
size a new deposit (a DEPOSIT batch is `markNewExposure`-gated and cannot be recovery-marked), and it contains no
value a blocked chain double books. Recommended layout: one transport per market, with a multi-market NAV hook, so a
blocked chain on one transport does not hold the other transport's market. Against pre-IL-8611 executors (no
`getBalanceUnchecked`) multi-executor recovery batches still revert.

Operational rule for write-offs (documented risk, the fuses do not police grant / revoke consequences). In a
multi-executor market, FUSE_MANAGER can write an executor off (re-granting only the sibling) and later re-grant it
while it is still stale; a recovery batch then restores it at its stale booked value through `getBalanceUnchecked()`
(market 0 -> 60 and NAV 900 -> 1000 in the review PoC, whereas a single-executor market stays clamped by its zero
cache). Never re-grant a written-off executor in a multi-executor market before its `getBalance()` is live (a fresh
approved attestation). The unchecked value can carry value no live read priced, bounded only by the last approved
observation.

### Residue after a short return (TP-M-07, IL-8585)

The return leg debits `settled` by the amount the dispatcher declared it sent and the anchor pro rata. The
dispatcher pays every recall out of `trackedIdle` only, never out of the tracked ERC-4626 positions, so any
return smaller than the attested bucket (a partial recall, or a full recall while part of the bucket sits in a
vault) leaves a pro-rata residue that still carries the whole remote loss the attesters had not yet recognised.
Once that loss exceeds `ATTESTATION_ANCHOR_BAND_BPS` (20%) of the residue, the residue cannot be attested down
to its true value: `approve` holds every value within the band of the anchor, and the exact-zero exception
applies only at or below `ATTESTATION_ZERO_DUST_SD`. Example: `settled == anchor == 1,000,000`, 900,000 is idle
and 100,000 sits in a vault that lost all of it; a full recall returns the 900,000 and leaves 100,000 against a
true value of 0, and the band floor is 80,000. The recall creates no value; the overstatement equals the loss
that was already unrecognised before it (10% of the bucket before, 100% of the residue after).

1. Just before recalling, attest a fresh observation so every known remote loss is recognised. A recognised loss
   is already out of `settled`, so the recall debits only value that exists and the residue stays correct. A
   loss larger than one `bigChangeBps` step needs several approvals spaced by `MIN_UPDATE_INTERVAL`; a loss
   beyond the band needs the force-set below before the recall.
2. After a return shorter than the bucket, read the dispatcher's balance at `lastRemoteStateVersion(chainId)`
   and compare it with `settled`. Inside the band, attest normally. Below the band floor (and above
   `ATTESTATION_ZERO_DUST_SD`), block immediately (`rejectBalanceAndBlock`; the proposer submits the truthful
   figure, `propose` has no band check) instead of waiting for `BALANCE_STALENESS_MAX` to fail NAV closed. The
   block makes `totalAssets()` revert for the whole vault until the force-set executes.
3. Schedule `scheduleChainRescue(FORCE_SET_SETTLED, chainId, (observedStateVersion << 192) |
   (observedRemoteTimestamp << 128) | trueValueLD)` with the value read at `lastRemoteStateVersion(chainId)` (and
   its remote read time), and run `executeChainRescue` after `RESCUE_DELAY` (at
   least 24h). The observation time must be strictly later than `executor.lastValueMovingReceiptAt(chainId)`
   (executor-chain time), the same rule as attestation, else schedule reverts
   `ObservationPredatesValueMovingReceipt` (IL-8604 R1; checked at schedule only). Pause the vault for the force-set window: manager-triggered value-moving traffic (outbound
   transfers, recalls) voids a scheduled force-set; balance reports and command ACKs do not (IL-8257).

Command-lane realign (TP-M-08 / IL-8586). `scheduleChainRescue(REALIGN_COMMAND_LANE, chainId, arg)` takes
`arg = (expectedEpoch << 192) | (expectedSequence << 128) | (newEpoch << 64) | newSequence`, where the expected pair
is the executor's current `commandConfigEpoch` / `nextCommandSequence` mirrors and the new pair is the
dispatcher's observed counters. If an authenticated ACK moves the mirrors during `RESCUE_DELAY`, execute reverts
`RealignStateMoved` instead of rolling the lane back: re-read both sides and reschedule. Armed behind an
`ABANDON_COMMAND` in the same batch, the expected sequence is the post-abandon value (current + 1 if the abandon
declares the sequence consumed). An ACK that frees a slot occupied at schedule (the `CANCEL`-in-flight case) is
covered too, because every applied ACK strictly raises the sequence mirror. An argument in the pre-IL-8586 shape
(upper 128 bits zero) is refused at schedule with `RealignExpectedEpochZero`: off-chain tooling must pack the
expected pair. The Stargate realign carries the same binding since IL-8652 (its own packing, see the Stargate README).

Expired cancel and the `EXPIRED` receipt (TP-M-16 / IL-8594). A `CANCEL_COMMAND` delivered after its command's deadline
closes the command on the dispatcher without consuming the sequence: it emits `CancelCommandExpiredIgnored`, marks the
command CANCELLED (so a re-delivery is a no-op) and queues a `COMMAND_ACK` with resolution `EXPIRED` (2). The executor
honours that receipt only for the command that still owns the slot as FAILED: it sets the command CANCELLED, frees the
slot and emits `CommandExpiryReleased(chainId, commandId, sequence)`. The sequence and epoch mirrors never move, so the
next command reuses the sequence, which the dispatcher has not consumed. In every other state (the slot holds a
replacement, the command is not FAILED) the receipt is ignored (`CommandReceiptIgnored`, `ALREADY_RESOLVED`, or
`SEQUENCE_MISMATCH` for a receipt whose sequence is not the command's; it never reaches `_adoptLateReceipt`), so a
stale cancel cannot retire a replacement. This also ends
the stall of a FAILED command left until the deadline: the manager's post-TTL cancel frees the lane, no abandon needed. An old executor ignores resolution 2 (`INVALID_RESOLUTION`): upgrade executors before
dispatchers. `CancelCommandExpiredIgnored` is routine (every post-TTL manager cancel emits it: the command is closed and
answered `EXPIRED`); if the lane already passed the command's sequence no receipt is queued. The alert is the
executor's `LateReceiptRetiredPendingReplacement` (an adopted in-window receipt retired a replacement that was still
PENDING). The `EXPIRED` receipt is queued like any ACK, so a response queue at its neutral cap
(`ResponseQueueNeutralCapReached`) or full (`ResponseQueueFull`) reverts the expired cancel; it stays re-executable
on the OffRamp and succeeds once the queue head is flushed or skipped.

ABANDON runbook (IL-8594). The deadline fence compares the DISPATCHER chain's `block.timestamp` with the command
deadline, while the abandon compares the executor chain's clock. (1) Before executing `ABANDON_COMMAND` with
`consumed = false`, check that the dispatcher chain's latest safe block has a timestamp strictly greater than
`commandDeadline(commandId)`. The abandon already waits for deadline + `COMMAND_EXPIRY_MARGIN`, so only a dispatcher
clock lagging by MORE than the margin (e.g. Arbitrum `delaySeconds` plus an executor leading by `futureSeconds`, the
IL-8591 residual) defeats the fence: a retained cancel then still runs as an in-window one, consumes the sequence and
retires the replacement. (2) Read the dispatcher's `nextCommandSequence()` / `commandStatus` for the declaration only
after that deadline has passed there: a retained CANCEL or RETRY executed inside the window still consumes the
sequence. (3) After the deadline the cancel that executes first is answered `EXPIRED` and frees the slot, so a re-send
is worth its fee; a re-send to a command already closed is idempotent and queues no second receipt (the first one is in
the response queue: `flushResponse()` delivers it). A stored
command whose dispatcher status is CANCELLED while `nextCommandSequence()` still equals its sequence was closed by an
expired cancel: declare `consumed = false`.

Re-sending a cancel (IL-8579). A lost `CANCEL_COMMAND` can be sent again, but every send costs the executor a CCIP fee,
so repeats for the same command are metered: each re-send must be at least
`CrosschainConstants.CANCEL_COMMAND_COOLDOWN` (10 minutes) after the previous one, otherwise `cancelCommand` reverts
`CancelCooldown(chainId, commandId, nextAllowedAt)`. The cancel stays terminal: `retryCommand` keeps reverting
`CancelInFlight` for that command.

### Late receipt refreshes the config epoch after a CONSUMED abandon (IL-8632)

`ABANDON_COMMAND(true)` / `ABANDON_COMMAND_SEQUENCE_CONSUMED` advances the executor's command-sequence mirror but
cannot carry the dispatcher's `commandConfigEpoch`: an UPDATE_VAULTS that succeeded remotely advanced that epoch, and
the abandon is a declaration made from no observation. The delayed COMMAND_ACK is the only authenticated source of the
new epoch. A receipt for `nextCommandSequence - 1` (`CcipExecutorCommandLib._adoptLateReceipt`) therefore refreshes
the epoch mirror ONLY, and only when the receipt's epoch is newer than the mirror. It does so even when a command sent
after the abandon owns the slot: that command was stamped with the old epoch, the dispatcher NACKs it anyway
(`InvalidConfigEpoch`), and a receipt ignored at that point would never be delivered again. The slot is left alone, so
that command still needs its NACK and a `CANCEL_COMMAND` (answered CANCELLED before its deadline, EXPIRED after it;
either frees the slot, and the epoch is already right). The sequence mirror is not touched, the abandon's verdict on
the command stays CANCELLED (`commandStatus`), and `LateReceiptEpochAdopted(chainId, sequence, previousEpoch,
newEpoch)` is emitted (alert on it). Monitoring events around it: `CommandAcknowledged` is also emitted. Older
receipts, equal/older epochs and NACKs stay ignored as before.

Why it matters: every command is stamped with the executor's epoch mirror and the dispatcher rejects a mismatch (a
command, UPDATE_VAULTS included, must carry the dispatcher's current `commandConfigEpoch`, otherwise it is NACKed with
`InvalidConfigEpoch` in `runStoredCommand`), so a stale mirror blocks the whole lane (business commands too), until
a receipt or a timelocked `REALIGN_COMMAND_LANE` repairs it. Timelock-free repair: cancel the stale command before
its deadline; the CANCELLED ACK it returns carries the dispatcher's epoch, so the mirrors catch up. Past the deadline
the EXPIRED receipt frees the slot but not the epoch, so `REALIGN_COMMAND_LANE` is the fallback if the late receipt
never arrived.

Design choice: late adoption rather than letting `ABANDON_COMMAND(true)` carry an observed dispatcher epoch. The
abandon argument would be a second rescue-admin-supplied figure to get wrong (a wrong epoch bricks the lane until
realign), whereas the receipt is authenticated by the transport. If no receipt ever arrives, `REALIGN_COMMAND_LANE`
remains the fallback and takes both observed counters. The abandon does not refresh the epoch.

REALIGN interplay: a `REALIGN_COMMAND_LANE` armed for the stale epoch reverts `RealignStateMoved` once an adoption has
moved the mirror (expected; just do not execute it).

### Zero-amount RETURN_TRANSFER (IL-8635)

A standard CCIP 2.0 pool fee plus decimal downscaling can deliver a ZERO destination amount for a positive recall. The
executor treats an authenticated `RETURN_TRANSFER` that carries no token entry, or exactly one `ASSET` entry with
amount 0, as a valid finalization with `received == 0`: it debits `settled` by the declared `sentSD` (clamped as
usual), clears `activeReturn`, resolves a cancelled-recall clock, credits idle with 0 and emits
`ReturnBelowMinimumCredited` (when `received < minReturn`, i.e. any non-zero floor) and `ReturnFinalized` (or
`LateReturnFinalized` for a cancelled or late recall) with `received = 0`. The state version is consumed once, before
the handler continues. A message with more than one entry, or an entry for a foreign token, is still ignored with
reason `token`; it also consumes the state version and leaves the recall open, and recovery is cancel plus rescue.
That ignored case is pre-existing and unreachable from an honest dispatcher.

Monitoring: with `minReturn == 0` a zero delivery shows only as `ReturnFinalized(received = 0)`, so alert on
`received == 0` or `received << sentSD`.

Follow-up: there is no per-lane minimum config today (only the per-request `minReturn` / `minDelivered`), so a
send-time rejection of amounts that cannot survive fee + downscaling is not implemented; operators should size recalls
well above the pool fee and decimal step.

Outbound direction (IL-8635): the dispatcher's `_receiveOutbound` accepts a ZERO delivered amount (it still requires
exactly one entry for the asset token, else `InvalidTokenDelivery`). A zero delivery settles as a zero credit: the
operation is marked processed, the dispatcher's `stateVersion` is incremented once, `trackedIdle` grows by 0 and
`TRANSFER_SETTLED(op, 0)` is queued (sent when it reaches the queue head), so the executor consumes the version, closes
the outbound and emits `SettledCreditShortfall` (plus `SettledBelowMinDelivered` when `minDelivered` was set). For an
outbound already force-resolved, the zero settlement takes the late-credit path (`DROP_FROM_NAV`: a zero late credit)
or is ignored as credited (`DELIVERED_TO_SETTLED`: NAV stays high by the credited amount until the next attestation,
IL-8581 R1). A pool or token that reverts on a zero release still leaves the message FAILED; that is outside the
contract's control. Before the fix the dispatcher reverted, the OffRamp recorded FAILURE, the outbound stayed in
flight and `getBalance()` reverted `TransferStale` after `TRANSFER_STALENESS_MAX`. This only occurs on lanes where the
source token has more decimals than the destination and the pool fee is above zero; USDC 6/6 lanes are unaffected.
Deployment: the CCIP dispatcher creation code changes, so dispatchers must be redeployed through the factory.

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
so before this fix no value was approvable at all and NAV stayed fail-closed after `BALANCE_STALENESS_MAX`. Such a
settled is not a baseline, like zero (IL-8606), so the band alone bounds that one approval (at most `1.2 * anchor`; the
anchor grows only from authenticated credits, IL-8578). The relative check returns after the first band approval.
Example (`bigChangeBps` 20%): supply 100, approved loss of 10 (attest 90), yield back to 100 on the remote chain, recall of 90 gives (0, R = 10, N = 10); a top-up of 10 gives (10, 20), window [8; 12] against band [16; 24], and approving 20 passes after the fix. Executors deployed before this change keep the old behaviour; for them
attest the residual before any top-up (see the IL-8606 section below). Once frozen, recall the whole settled bucket or force-set.

Known limitation (FP-H-01, IL-8554): the band bounds the LEVEL of mispricing (+-20% of the anchor), not the
cumulative movement; a jointly compromised proposer/approver pair can walk `settled` between the band edges
repeatedly (about 9 approvals per full 0.8x -> 1.2x -> 0.8x cycle: 5 up, 4 down, at the reference
`bigChangeBps` of 1_000; 3 + 2 at 2_000). Accepted by design (it needs both attester keys); mitigation is
off-chain monitoring of `BalanceApproved` direction reversals.

Residual anchor after a full recall (TP-M-28, IL-8606). If the remote shares earn yield after the last attestation, an
ordinary `REDEEM` followed by a full recall of the last approved amount leaves that yield tracked on the dispatcher
while the recall drains `settled` to zero. The pro-rata debit used to drain the anchor with it, and a zero anchor
forbids every positive attestation (`UnanchoredAttestation`) and every further recall, orphaning the residual until a
timelocked `FORCE_SET_SETTLED`. `RETURN_TRANSFER` carries the dispatcher's authenticated post-debit reported balance
(`remoteBalance`, shared decimals). The balance carried by every response to the executor (`TRANSFER_SETTLED`,
`RETURN_TRANSFER`, `COMMAND_ACK`, `BALANCE_REPORT`) is the remote balance after all token responses queued on the dispatcher
have landed, so it excludes all of `queuedTokenAmount`: the executor applies responses strictly by version, and counting those
queued tokens again would double count them (IL-8768). `observation()` and `accountedBalance()` still include
`queuedTokenAmount`, because the tokens are physically on the dispatcher and remote-owned (audit M-8). When a return empties `settled` while that balance exceeds
`ATTESTATION_ZERO_DUST_SD`, `applyReturnDebit` now keeps `anchorPrincipal` at that residual. `settled` is NOT credited:
the residual enters NAV only once an ordinary attestation prices it, and that attestation is bounded by the anchor band
around the residual (`AttestationOutsideAnchorBand`), not by the relative limiter (meaningless at a zero baseline).
`approve` therefore keys its zero-baseline rule on the anchor: from `settled == 0` a positive attestation is admissible
iff `anchorPrincipal != 0` and inside the band; with no anchor the rule is unchanged (`UnanchoredAttestation`). A
zero-to-zero approval stays allowed and leaves the residual anchor in place. A residual at or below
`ATTESTATION_ZERO_DUST_SD` still zeroes the anchor (and is cleared with a zero attestation).

The residual is NOT recallable until it is attested (recall bounds use `settled`), so the order of operations matters.
Attest the residual before re-supplying: a credit that lands before the attestation caps the anchor at the credited
amount (`min(R + D, netPrincipal = D)`, see the anchor credit cap above), which drops the residual out of the band
(covered by `testCreditBeforeResidualAttestationShouldCapTheAnchorAtTheCredit`). The first attestation from the zero
baseline is bounded only by the anchor band, the relative limiter being skipped at a zero baseline, so a single step can
move `settled` from 0 to 1.2 R. The residual anchor is capped at the pre-debit anchor: an honest residual (yield since
the last attestation) never exceeds it, so a reported figure above it cannot raise the anchor, which stays
non-increasing under debits. Until the residual is attested NAV excludes it (it understates, never overstates), and a
zero attestation is allowed, so a lost residual needs no special exit; `rejectBalanceAndBlock` plus the timelocked
`FORCE_SET_SETTLED` is only needed to price a residual that has fallen out of the band.

Deployment note: `applyReturnDebit`'s signature changed, so the executor must be linked to the new
`CcipExecutorAttestationLib`; an executor still linked to the old library reverts in the `RETURN_TRANSFER` handler.

### Pricing window between propose and approve (TP-H-01 / IL-8577, TP-M-18 / IL-8596)

A positive `BalanceProposed` is public, but the live executor balance, the vault's cached NAV and the crosschain
pre-hook change only when the proposal is approved and the CROSSCHAIN market is refreshed. A depositor who enters
after the proposal and before the approval pays the old share price and captures part of the attested remote yield
once approve and refresh land (and the converse for an exit ahead of a negative proposal). This is inherent to a
cached, discretely attested NAV and is bounded to one attestation step (at most `BALANCE_STALENESS_MAX` of yield,
further capped by the per-approval relative limiter and the anchor band). Accepted by design: no hook blocks
share-price operations while a proposal is pending, because it would only narrow the window and would fail-close
user operations. Operational rule for the attester pair: submit propose + approve + `updateMarketsBalances`
(`[CROSSCHAIN]`) back-to-back in one block through a private submission channel, keep the attestation cadence well
below `BALANCE_STALENESS_MAX`, and rely on deposit/withdraw fees where remote yield is lumpy.

The CCIP executor never bumped the accounting epoch on an outbound send, so a pending proposal already survived it;
the Stargate executor now matches (TP-M-44 / IL-8622, see the Stargate README).

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

- The `FORCE_SET_SETTLED` (and `FORCE_SET_SETTLED_UNCHECKED`, the fifth `CcipChainRescue` member, value 4; see the
  clock bullet below) argument of `scheduleChainRescue` / `executeChainRescue` is `(observedStateVersion << 192) |
  (observedRemoteTimestamp << 128) | newSettledLD`; the balance occupies the low 128 bits (it was 192).
  `newSettledLD` is in local decimals but is booked in shared decimals, so it must be a multiple of
  the executor's `DECIMAL_CONVERSION_RATE`: a figure with a remainder is refused at schedule time with
  `AmountHasDust(newSettledLD)`
  (checked last, after the version, staleness and value-moving-receipt gates) instead of failing only at execute,
  after `RESCUE_DELAY`. Off-chain tooling must repack (an unpacked plain balance has timestamp 0 and is refused)
  and must assert `newSettledLD < 2^128` before packing: a larger balance would OR into the timestamp bits and be
  truncated silently if it still passed the freshness check (unreachable in practice: the dispatcher caps priced
  assets at uint128). Guardians decode all three fields from the schedule calldata.
- Schedule reverts `ObservationStale(chainId)` unless `0 < observedRemoteTimestamp <= block.timestamp` and
  `block.timestamp - observedRemoteTimestamp <= BALANCE_STALENESS_MAX`, and `AmountHasDust(newSettledLD)` unless
  `newSettledLD % DECIMAL_CONVERSION_RATE == 0` (the executor's rate, IL-9025).
- Staleness after execute (intended, conservative): the figure ages while it waits out `RESCUE_DELAY`. NAV is stale
  right after execute exactly when `executeTime - observedRemoteTimestamp > BALANCE_STALENESS_MAX` (`ObservationStale`).
  An observation older than `BALANCE_STALENESS_MAX - RESCUE_DELAY` at schedule is sufficient but not necessary (a late
  execution also ages it), and every force-set is stale on execute when `RESCUE_DELAY >= BALANCE_STALENESS_MAX`. The
  settled bucket, anchor and net principal are still rebased and the block is lifted. Take the observation as late as
  possible before scheduling.
- Cost: when NAV is stale on execute it stays stale for at least `MIN_UPDATE_INTERVAL` (`lastApprovalAt` takes the
  execute time), and also until an observation read after the execute is approved (`lastValueMovingReceiptAt` is
  armed at execute, so an earlier read is refused). If production `BALANCE_STALENESS_MAX <= RESCUE_DELAY`, every
  force-set is stale on execute, so the runbook plans an ordinary attestation right after it.
- Short remaining freshness (IL-8631 R1): nothing at execute checks how much freshness the committed observation has
  left. If it is still fresh at execute but has less than `MIN_UPDATE_INTERVAL` left, NAV reverts (`ObservationStale`)
  from `observedRemoteTimestamp + BALANCE_STALENESS_MAX` until `execute + MIN_UPDATE_INTERVAL`, because the limiter
  runs from the execute time and rejects even a fully fresh replacement (`MinUpdateIntervalNotMet`). A gate at execute
  would be the wrong fix (the force-set is the last-resort path and must not refuse). Procedure:
  - at schedule, check `observedRemoteTimestamp + BALANCE_STALENESS_MAX - (scheduleTime + RESCUE_DELAY) >=
    MIN_UPDATE_INTERVAL`; if not, plan the ordinary attestation as a fixed step after execute;
  - before unpausing, compute `lastApprovedObservedAt(chainId) + BALANCE_STALENESS_MAX - now`; if it is below
    `MIN_UPDATE_INTERVAL` or negative, keep the vault paused until the first ordinary attestation, possible from
    `execute + MIN_UPDATE_INTERVAL` and with an observation taken after the execute (IL-8604).
- The clock can move backwards only with `FORCE_SET_SETTLED_UNCHECKED` (IL-8648 R1). A strict `FORCE_SET_SETTLED`
  mirrors the ordinary approve gate: at execute, right before the rebase, it reverts
  `ForceSetOlderThanApproved(chainId, committedObservedAt, lastApprovedObservedAt)` when an ordinary approval with a
  newer observation landed during the rescue delay (equal passes; a chain with no approval yet, `lastApprovedObservedAt
  == 0`, passes). The settled figure and the clock are then kept, and the admin reschedules from a fresh read
  (`>= lastApprovedObservedAt`). `FORCE_SET_SETTLED_UNCHECKED` takes the same argument word and the same schedule-time
  checks and differs only in skipping that gate, so it re-stamps the older committed time (the clock ends earlier than
  before: more conservative, but the fresher attested figure is overwritten). Why an opt-out and not a hard gate: the
  attester pair can approve on a blocked chain, so a hostile pair could approve a fresh in-band observation in every
  rescue window and deny the last-resort path forever; with the opt-out the admin schedules UNCHECKED from the start,
  and because the kind is part of the rescue commitment, a strict schedule can never be executed as unchecked and the
  guardian sees the choice in the schedule calldata and can veto it. Runbook: before execute, still compare the
  committed time with `lastApprovedObservedAt(chainId)` and `cancelRescue` if an approval landed and the figure should
  be re-read; this is now enforced by default (the strict kind refuses), the comparison only tells you early.
  Honest attesters block it too (IL-8648 review): `propose`/`approve` do not check `chainBlocked`, so a keeper that keeps
  its normal cadence during `RESCUE_DELAY` makes every strict force-set revert, and each failed attempt keeps NAV
  closed for another delay. Halt ordinary attestation for the chain during the rescue window, or schedule UNCHECKED
  when that is not possible. A strict schedule whose committed time is already older than `lastApprovedObservedAt` is
  certain to fail at execute (an approval that predates the schedule refuses it too): re-read before scheduling. A
  refused strict rescue stays SCHEDULED (the revert undoes the consume), holds a `MAX_PENDING_RESCUES` slot and would
  become executable if an UNCHECKED force-set later lowered the clock: `cancelRescue` it. Off-chain guardian decoders
  must know kind 4.
- Interplay: the IL-8648 check `ObservationOlderThanApproved` compares against `lastApprovedObservedAt`; after a
  force-set that value is the committed remote timestamp, so the next ordinary observation must be `>=` it. The
  force-set itself is held to the same rule by `ForceSetOlderThanApproved` unless it is UNCHECKED. The IL-8631
  check `ObservationTooCloseToStale` is unchanged. A force-set bumps the IL-8619 `repairSettleSeq` and records its
  observed version in `repairSettleVersion`; the IL-8614 repair latch is unchanged.
- CCIP detail: `forceSetSettled` arms `lastValueMovingReceiptAt` at execute time (IL-8604), so the next ordinary
  observation must be strictly later than the force-set EXECUTION (a stricter bound than the stamped clock);
  `ObservationPredatesValueMovingReceipt` fires before `ObservationOlderThanApproved`.
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

### Lost TRANSFER_SETTLED (TP-M-36, IL-8614)

`ADVANCE_FRONTIER` skips the lost response but cannot touch the outbound record whose `TRANSFER_SETTLED` it was. The
record keeps the amount `A` in `outboundInFlight`, while the next attestation, read at the repaired frontier, already
contains the delivered `A` and writes `settled = S + A`: NAV = `S + 2A`.

The rescue itself is allowed (it is the only exit from a stuck frontier). Instead `approveBalance` reverts
`FrontierRepairBlockedByOpenTransfers(chainId, outboundInFlight)` while `frontierRepairPending(chainId)` is `true`
and `outboundInFlight(chainId) != 0`. The guard reads `outboundInFlight`, not the pending-slot count, because other
records (a cancelled recall) may be open for unrelated reasons. Procedure:

1. Execute `ADVANCE_FRONTIER`. The chain is blocked and the latch is armed, but only when the repair owns the block:
   the chain was not blocked before, or was blocked only by an earlier repair (IL-8620). A repair run over a foreign
   block (breaker reject, drop) leaves the latch off, so an ordinary approval cannot lift that older block; its exit
   stays the timelocked force-set.
2. If the `TRANSFER_SETTLED` is merely retained behind a lost version, re-execute it after the repair: the record
   closes and `settled` carries `A`.
3. If it is truly lost, establish whether the dispatcher credited the transfer and force-resolve the record with
   `scheduleForceResolveOutbound(operationId, creditToSettled)`: `true` if credited, `false` if it has not arrived
   (if it arrives later, its settlement is credited once, see below).
   Wait `RESCUE_DELAY`, then `executeForceResolveOutbound`.
4. Attest the dispatcher balance read at the repaired frontier. NAV equals the true remote balance.

Prefer `DROP_FROM_NAV` (`creditToSettled == false`) only when the transfer has not arrived. If its
`TRANSFER_SETTLED` can still be delivered, the late settlement is credited at most once (IL-8619): `repairSettleSeq`
per chain moves only on the frontier-repair latch-clearing approval and on `forceSetSettled`, and `repairSettleVersion`
records the state version that write was bound to. The late settlement is skipped
(`LateSettlementAlreadyAttested(chainId, operationId, stateVersion)`) only if such a write happened after the drop
and the settlement's `stateVersion` is not above that write's version: the write then already read the amount. This
happens only when `ADVANCE_FRONTIER` skipped a response that could still execute. A settlement with a higher version
reached the dispatcher after the write and is credited (IL-8619 review: skipping it left NAV understated by the
amount). A routine version-bound approval does not block the credit. Residual: an attestation or force-set whose
balance was read at a higher dispatcher version than it declares (attester or admin misconduct against this runbook)
double counts the late settlement; never add an in-transit amount to a force-set. Conversely, a write that declares
a higher version than it was read at (an overshot frontier) loses the late credit. Pinned by
`testDropFromNavThenAttestThenLateSettleIsNotCreditedAgain` (skip at the boundary) and
`CcipLateSettlementAfterRepairWriteTest` (a settlement above the write's version is credited, including after a
force-set). The other exits from the latch stay guarded: a settled force-set needs no pending transfers, and
`rejectBalanceAndBlock` clears the latch but leaves the chain blocked.

Pinned by `CcipFrontierRepairOpenOutboundTest`.

Deployment note (IL-8619): re-link `CcipExecutorTransferLib` and `CcipExecutorAttestationLib` and update their pinned
addresses in the `crosschain_deploy` `libraries` of `foundry.toml`. The `Outbound` record and the attestation state
changed (`repairSettleSeq`, `repairSettleVersion`), so the CCIP executor needs new creation code (new factory if the creation codes are
already configured).

### Attesting while the response queue is stalled (IL-8257)

The dispatcher sends responses from a strict FIFO queue that can stall (fee budget, paused pool, undeliverable
head). The attestation (`propose` / `approve`) requires `stateVersion == lastRemoteStateVersion(chainId)`, the
executor frontier. Only `TRANSFER_SETTLED` and `RETURN_TRANSFER` bump the dispatcher version and move the
frontier; a queue holding only value-neutral responses therefore does not block an honest attestation. Use this
checklist when the queue is not empty:

1. At one pinned block on the dispatcher chain read `observation()` (`accountedBalance`, `stateVersion`,
   `trackedPositionSetHash`) and decode the queue: every id from `responseQueueHead()` to `responseQueueTail()`
   through `queuedResponse(id)` (message type, and for `TRANSFER_SETTLED` the `amount`). On the executor chain
   read `lastRemoteStateVersion(chainId)`.
2. Version-delta check: `observation().stateVersion - lastRemoteStateVersion(chainId)` must equal the number of
   queued `TRANSFER_SETTLED` + `RETURN_TRANSFER` responses. `BALANCE_REPORT`, `COMMAND_ACK`, `COMMAND_NACK` and
   `RETURN_REJECTED` carry no bump and do not count. A surplus means a value response has left the queue and is
   in transit or FAILED on the destination OffRamp: deliver it first (manual execution of the failed message),
   do not attest and do not cancel a recall. The two chains are not read atomically, but every race makes the
   check fail ("stop"), never pass. After `executeSkipStuckResponse` dropped a versioned response the check can
   never pass again; the exit is the timelocked `ADVANCE_FRONTIER` rescue, which clears the cancelled-recall
   clock (`cancelledRecallCount` / `cancelledRecallPendingAt`) when executed after the reset guard window (item 6;
   an earlier advance keeps the clock): the dropped return's tokens are back in the
   dispatcher's `trackedIdle` and `settled` was never debited. The chain stays blocked until a fresh approved
   attestation at the new frontier.
3. Delta 0: attest normally with the `observation()` values (`STATE_VERSION = observation().stateVersion`,
   `SETTLED_BALANCE = accountedBalance * <executor>.DECIMAL_CONVERSION_RATE()`, read on the executor chain; the
   dispatcher's own rate differs when the chains' local decimals differ). `accountedBalance` is in shared decimals
   while `proposeBalance` takes local decimals, so convert it; the two units coincide only when the executor
   asset's local decimals equal the shared decimals (e.g. 6/6). Queued value-neutral responses no longer block it.
4. Delta greater than 0 and equal to the queued count: use `STATE_VERSION = lastRemoteStateVersion(chainId)` and
   `SETTLED_BALANCE = (accountedBalance - sum(amount of the queued TRANSFER_SETTLED responses)) *
   <executor>.DECIMAL_CONVERSION_RATE()` (the executor's rate; both terms are in shared decimals, the result is
   passed in local decimals): every queued
   `TRANSFER_SETTLED` is credited when it lands, either from `outboundInFlight` or, for an outbound force-resolved
   without credit (`DROP_FROM_NAV`), as its late credit (IL-8619), so subtract it in both cases. A queued `RETURN_TRANSFER` needs no correction: its tokens
   are in `queuedTokenAmount` and the executor still counts them in settled.
5. Approve before anyone calls the permissionless `flushResponse()`. A delivered value response moves the
   frontier and voids the proposal (`ProposalVersionMismatch` at approve); propose again from step 1.
6. Cancel a recall (`cancelPendingReturn` / `cancelStalePendingReturn`; the manager path is capped at 4 unresolved
   cancelled recalls per chain, see "Response queue capacity") only while its `RETURN_TRANSFER` is still
   visible in `queuedResponse`. If it has already left the queue, deliver it and attest afterwards: attesting and
   cancelling and then delivering it late debits the recall twice. Cancelling no longer drops the recall's clock
   (IL-8590): `cancelledRecallPendingAt[chainId]` keeps the oldest cancelled recall's `createdAt`, and `getBalance`
   reverts `TransferStale(chainId, createdAt)` once `TRANSFER_STALENESS_MAX` has passed, until the late
   `RETURN_TRANSFER` or a `RETURN_REJECTED` of every cancelled recall has landed (`cancelledRecallCount`), or a
   `FORCE_SET_SETTLED` or an `ADVANCE_FRONTIER` executed after the reset guard window (below) resets it (an answer to a recall cancelled before the
   reset is ignored, `cancelledRecallGeneration`). A new recall may be opened meanwhile (but see the IL-8768 caveat below); the cancelled clock stays
   separate and is not re-anchored when only some of several cancelled recalls resolve. CCIP 2.0 delivery is
   unordered (IL-8496), so a cancelled recall's return can land at any time. After cancelling a recall whose
   `RETURN_TRANSFER` is still queued on the dispatcher, do not open a new recall before `flushResponse` has drained
   the queue. This applies to dispatchers deployed before IL-8768, which report the balance with the earlier queued
   return counted a second time, leaving a phantom residual anchor once the later return empties settled; newer
   dispatchers report the balance net of `queuedTokenAmount`.
   Stargate carries the same cancelled-recall clock (IL-8621); it additionally clears on an approval bound to a
   dispatcher version past the cancel-time one.
   Request deadline and reset guard (IL-8590). Message format version 2 appends a `deadline` word to
   `RETURN_REQUEST`: `createdAt + TRANSFER_STALENESS_MAX` (the constructor refuses a zero window). The dispatcher
   rejects a request executed after it (the deadline itself is still honoured) with `RETURN_REJECTED(EXPIRED)`
   before any value moves: `trackedIdle` and `stateVersion` stay, the operation is consumed. Keeper: reason
   `EXPIRED` means "request again"; a still-active recall is freed by the rejection, a cancelled one resolves its
   clock (in the same generation). Because a stuck request can no longer move value after its deadline, forgetting
   a cancelled recall's clock is safe only once every cancelled request has expired. `cancelledRecallLatestAt` is
   the NEWEST cancelled `createdAt` (meaningful only while `cancelledRecallCount != 0`, never cleared), and
   `refusedUntil = cancelledRecallLatestAt + TRANSFER_STALENESS_MAX + RECALL_DEADLINE_SKEW_MARGIN` (15 minutes) is
   the last second at which a reset is still refused. The two rescues treat the guard differently at EXECUTE time
   (a recall can open after scheduling):
   - `FORCE_SET_SETTLED` reverts `CancelledRecallNotExpired(chainId, refusedUntil)` while `cancelledRecallCount != 0`
     and `block.timestamp <= refusedUntil`; retry once `refusedUntil` has passed.
   - `ADVANCE_FRONTIER` never reverts on the guard (else the manager could postpone it forever with recall ->
     cancel loops). Inside the window it SKIPS the clock reset: the frontier advances, the chain stays blocked and
     the repair latch armed, but `cancelledRecallCount`, `cancelledRecallPendingAt`, `cancelledRecallLatestAt` and
     `cancelledRecallGeneration` are unchanged, so `getBalance` stays `TransferStale`-gated by the kept clock. The
     kept clock is later cleared by the cancelled recalls' answers (an expired request comes back `EXPIRED` in the
     same generation) or by `FORCE_SET_SETTLED`, whose guard is then bounded because the blocked chain refuses new
     recalls. Executed after `refusedUntil` the advance resets the clock as before.
   Skip-valve exit ORDER: skip -> cancel -> `ADVANCE_FRONTIER` -> approve. The skip drops the answer, so nothing
   resolves the cancelled recall's clock: for the advance to clear it, it must be executed after `refusedUntil`
   (`createdAt + TRANSFER_STALENESS_MAX + 15 minutes` of the newest cancelled recall). With a long
   `TRANSFER_STALENESS_MAX` this can push the repair past `FRONTIER_REPAIR_DELAY`; an earlier advance still unblocks
   the frontier but leaves the clock, and then only `FORCE_SET_SETTLED` (after `refusedUntil`) clears it. If the
   recall is cancelled only after the advance, the advance had nothing to clear and only `FORCE_SET_SETTLED`
   clears that clock. A `RETURN_REJECTED` dropped by the skip valve carries no version, so there is no gap:
   an advance to the unchanged frontier is refused (`InvalidFrontierAdvance`), one past it would overshoot, and only
   `FORCE_SET_SETTLED` clears the clock.
   `ADVANCE_FRONTIER` has no active-recall guard (unlike `FORCE_SET_SETTLED`'s `PendingTransfersExist`).
   The 15-minute margin is an ASSUMPTION, not a guarantee: it assumes the two chains' `block.timestamp` differ by
   less than 15 minutes (honest-sequencer assumption; e.g. an Arbitrum sequencer may stamp blocks up to ~24 h behind
   L1). If the skew exceeds it, a reset can still precede a late honoured request.
   `TRANSFER_STALENESS_MAX` now also bounds recall liveness: if it is shorter than the lane's worst-case CCIP
   delivery (source finality + execution, or a manual re-execution), every recall comes back `EXPIRED`. Set it well
   above that worst case.
   Pairs deployed before version 2 have no deadline: before any reset read the dispatcher's
   `processedOperation(operationId)` for each recall cancelled since the last reset: `false` means the request
   can still be executed and move value, so do not reset; reset only when every one is `true` and its answer has
   landed or been dropped by the skip valve.
7. `TRANSFER_STALENESS_MAX` is not ordered against `BALANCE_STALENESS_MAX`; do not rely on `TransferStale`
   fail-closing NAV before the attestation goes stale.
8. Observation binding (applies to every attestation, queue stalled or not; IL-8604 / IL-8584): the executor
   records the local time of every value-moving receipt (`TRANSFER_SETTLED` credit, late credit, `RETURN_TRANSFER`,
   outbound force-resolve, settled force-set) and both `propose` and `approve` revert
   `ObservationPredatesValueMovingReceipt(chainId, remoteTimestamp, receiptAt)` unless the proposal's
   `remoteTimestamp` is strictly greater than `lastValueMovingReceiptAt(chainId)` (executor-chain time). A queued
   `RETURN_TRANSFER` is versioned when it is enqueued, so an observation taken before it was flushed shares the
   `stateVersion` of the post-flush state yet still counts the returned tokens; the epoch bump alone does not stop
   such an observation from being proposed after the credit.
   After any value-moving receipt, take a fresh observation (its timestamp strictly greater than the receipt time)
   and propose again. Cost: a remote clock that lags the executor chain delays acceptance by the lag.
   The rule protects only against a lagging remote clock: a remote clock that LEADS the executor clock by more than
   the CCIP delivery time lets a stale read through, so attesters and admins should read only after the receipt is
   visible on the executor. `scheduleChainRescue(FORCE_SET_SETTLED)` applies the same rule.
   `remoteTimestamp` is declared by the proposer, so this protects an honest attester from a stale observation; it
   is not a defence against a malicious proposer.

### Response queue capacity (IL-8583)

The dispatcher keeps at most `MAX_QUEUED_RESPONSES` (64) live responses, and every state-changing inbound message
queues one, so a full queue used to revert every authenticated message at once (token deliveries, recalls and the
NACK of a failed command included) while an undeliverable head kept it full.

- **Reserved band.** The value-neutral responses `BALANCE_REPORT` and `COMMAND_ACK` may occupy at most
  `MAX_QUEUED_RESPONSES - RESERVED_FOR_VALUE_MOVING` = 56 slots; past that they revert
  `ResponseQueueNeutralCapReached(live, cap)` (the inbound message is retried after a drain). `TRANSFER_SETTLED`,
  `RETURN_TRANSFER`, `RETURN_REJECTED` and `COMMAND_NACK` may use all 64. The band is only 8 deep: past 56 neutral
  entries just 8 more `TRANSFER_SETTLED` / `RETURN_TRANSFER` / `RETURN_REJECTED` / `COMMAND_NACK` responses fit
  before `ResponseQueueFull`, so a stalled head should be repaired or skipped (timelocked `executeSkipStuckResponse`)
  before that. The hard cap does not presume a dead lane: one stalled head plus recall traffic was enough before
  the recall cancel cap below. Design note: the CANCELLED ACK of `CANCEL_COMMAND` and the SUCCEEDED ACK of
  `RETRY_COMMAND` count as neutral too, so at the soft cap unblocking the command lane waits for a drain.
- **Recall cancel cap.** Manager `cancelPendingReturn` refuses `CancelledRecallCapReached(chainId, 4)` while 4
  cancelled recalls of the chain are unresolved (`cancelledRecallCount`). Each cancel frees the recall slot at once
  and leaves one `RETURN_TRANSFER` (or `RETURN_REJECTED`) in the dispatcher queue, so an unmetered recall -> cancel
  loop could otherwise fill the 64 slots. `cancelStalePendingReturn` (after `TRANSFER_STALENESS_MAX`) is not capped,
  so a dead return lane can still be cleared and `FORCE_SET_SETTLED` stays reachable. With the cap, manager traffic
  tops out near 24 live responses (16 transfer settles, 5 recall answers, 1 NACK, 1 report, 1 ACK), under the
  neutral cap of 56; every further slot costs one `TRANSFER_STALENESS_MAX` wait. The count releases when a cancelled
  recall resolves, a `FORCE_SET_SETTLED` resets the chain, or an `ADVANCE_FRONTIER` executed after the reset guard
  window does (an earlier advance keeps the count).
- **Coalescing.** While a `BALANCE_REPORT` is queued and not yet dispatched, a new `BALANCE_REQUEST` rewrites its
  payload (current balance and `stateVersion`) and emits `ResponseCoalesced(responseId)` instead of appending. The
  entry keeps its id and FIFO slot. Both carry no version bump, so a refreshed report is safe.
- **Draining.** `flushResponse()` sends the head; `flushResponse(maxCount)` sends up to `maxCount` responses in
  order and returns the number sent. The first send reverts with its cause like `flushResponse()`; a later failure
  just stops the loop and keeps what was already sent.

### What a generic rescue may not target (IL-8555 / IL-8556 / IL-8770)

`scheduleRescue` (queue shared by the executor and dispatcher, fenced in `RescueLogicLib`) refuses: the host's
factory (IL-8261); non-`transfer` calls on the tracked asset; every call to the CCIP router (`CCIP_ROUTER`);
and, on a dispatcher, any call to a tracked vault (checked at schedule and again at execute, because
UPDATE_VAULTS can change the set during the timelock). Why: the router authenticates the host by bare
`msg.sender`, and executor and dispatcher are same-address twins, so a rescue `ccipSend` would forge a
peer-authenticated message (e.g. UPDATE_VAULTS + DEPOSIT) that moves value on the other chain, where no floor
runs; and tracked-vault shares are in NAV but outside the ASSET floor, so `approve`/`redeem` on a share token
would drain a position unseen. `executeRescue` also reverts `RescueTrackedSharesReduced` if any tracked
vault's share balance fell during the call (bounds what a rescue may move; the target ban bounds what it may
authorise). Path and route configuration stay with the factory's timelocked registration.

One further fence (IL-8770). The CCIP factory has no rescue module, so the Stargate-only
executor-callback fence (IL-8763) does not apply here. No call may carry the ContextManager
`runWithContext` selector, on any target and on every host. A vault's ContextManager has no role gate on `runWithContext` and makes its `msg.sender` (here the rescue host) the context
sender, so `runWithContext({vault.approve(ADMIN, max)})` would grant the rescue admin a share allowance that neither
the vault ban (the target is the ContextManager) nor the share snapshot (the balance is unchanged) sees, and the admin
could redeem outside the timelock. Checked at schedule, where the calldata is committed. Residual: a non-Fusion vault
behind a signature-less ERC-2771 trusted forwarder lets the forwarder pick the sender; no such vault is among the
remote vaults we know, and the vault ban plus the share snapshot still apply to direct calls.

A rescue cannot leave a tracked vault's share balance lower than before the call: shares can only leave a tracked vault
through business REDEEM / REDEEM_FROM_REQUEST commands (and a REQUEST_SHARES fee, capped by `maxFeeShares`). Since
IL-8784 a vault can also be untracked by removing it from the allowlist even while it holds shares (D-020/D-028);
the residual is then outside the IL-8556 fence and rescuable, which is accepted: removal needs the ALPHA
`UPDATE_VAULTS` command and emits `TrackedVaultSweepResidual`. If a tracked vault's `balanceOf` reverts, every generic
rescue on that dispatcher reverts (`observation()` reports the vault unpriced, IL-8602; de-allowlist it first).

Residual (accepted, documented limitation): the CCIP dispatcher tracks a vault when `UPDATE_VAULTS` allowlists it.
A vault approved via rescue while it is NOT allowlisted is not caught: before it is ever allowlisted, or after an
`UPDATE_VAULTS` removal that left a residual (IL-8784: the vault is then neither allowlisted nor tracked). If such an
`approve` executes while the vault is out, the allowance survives a later re-allowlisting, which tracks the residual
again, and the spender can move those shares, and the shares of later deposits, outside any timelock. A rescue
scheduled while the vault was out but executed after the re-add is refused at execute. Before re-allowlisting a
removed vault, revoke any share allowance the dispatcher granted (a rescue `approve(spender, 0)` while the vault is
still out; after the re-add every rescue on it is refused). We accept this rather than banning approve-family
selectors on every target.

### Rescue post-condition is non-worsening (IL-8640)

After every generic rescue (`executeRescue`) each host (both executors, both dispatchers) checks its ASSET balance
against its tracked ledger. The check is non-worsening: the host snapshots `ASSET.balanceOf(this)` before the
rescue call (`_beforeRescueExecuted`; the `RescueModule` default is `type(uint256).max`, which keeps the absolute
rule for a host that overrides only the after-hook) and `_afterRescueExecuted` requires
`balanceAfter >= min(balanceBefore, ledger)`.

- A rescue can never lower a sufficient balance below the ledger.
- A rescue can never lower an already-insufficient balance any further.
- If an issuer-side adjustment (for example Tether `destroyBlackFunds`, a negative rebase) leaves the host's ASSET
  balance below its ledger, rescues that do not touch ASSET still work: native-balance recovery, unrelated-token
  sweeps and ERC-4626 share recoveries (there is no LayerZero endpoint on CCIP hosts).
- The donation remedy stays available: transferring ASSET to the host restores the backing. A partial donation
  raises the floor for later rescues (the next snapshot is the higher balance, so `min(balanceBefore, ledger)`
  grows with it); once the balance is back at or above the ledger the absolute rule applies again.
- The revert keeps its existing per-host error (`UnbackedIdleCredit` on the executor, `InsufficientTrackedIdle` on
  the dispatcher), now reported as `(balanceAfter, min(balanceBefore, ledger))`.

Ledger used as the floor, per host:

| Host | Ledger used as the floor |
| --- | --- |
| Executor | `idleLedger` |
| Dispatcher | `trackedIdle + queuedTokenAmount` |

Residual (accepted): a rescue never repairs a shortfall. While a host is short (balance below its ledger), no ASSET
at all can leave through a generic rescue. The shortfall is closed by a donation (transfer ASSET to the host), or
value is moved by the admin recall / force-resolve paths.

The admin recall (`scheduleAdminRecall` / `executeAdminRecall`) pays only the immutable `ADMIN()`: if the ASSET issuer
blocklists `ADMIN` on the dispatcher's chain, the outcome depends on the token. A token that checks the recipient (USDC,
`isBlacklisted`) makes `executeAdminRecall` revert, so tracked idle has no on-chain exit until the lane recovers or the
block is lifted. A token that checks only the sender (USDT, `isBlackListed` on Ethereum; USDT0, `isBlocked` on Arbitrum)
lets the transfer succeed and the tokens are frozen at `ADMIN` (IL-8807). Either way, check the issuer's blocklist for
`ADMIN` before relying on it.

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
