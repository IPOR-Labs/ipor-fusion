// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    Origin,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {StargateOAppBase} from "./base/StargateOAppBase.sol";
import {ICrosschainExecutor, BalanceObservation} from "../interfaces/ICrosschainExecutor.sol";
import {ICrosschainFactory, ExecutorInitParams} from "../interfaces/ICrosschainFactory.sol";
import {CrosschainErrors} from "../lib/CrosschainErrors.sol";
import {
    MsgType,
    DeploymentStatus,
    ResolveOutcome,
    CommandStatus,
    CrosschainConstants
} from "../lib/CrosschainConstants.sol";
import {CrosschainMessages, Command, OutboundTransfer} from "../lib/CrosschainMessages.sol";
import {
    StargateExecutorState,
    ActiveCommand,
    OutboundRecord,
    ReturnRecord,
    Proposal,
    MAX_PENDING_TRANSFERS_PER_CHAIN_SLOTS
} from "./lib/StargateExecutorState.sol";
import {IStargateExecutorLibraryAbi} from "./IStargateExecutorLibraryAbi.sol";
import {StargateExecutorAccountingLib} from "./lib/StargateExecutorAccountingLib.sol";
import {StargateExecutorAttestationLib} from "./lib/StargateExecutorAttestationLib.sol";
import {StargateExecutorCommandLib} from "./lib/StargateExecutorCommandLib.sol";
import {StargateExecutorDeploymentLib, DeploymentRequestRecord} from "./lib/StargateExecutorDeploymentLib.sol";

/// @title StargateCrosschainExecutor
/// @notice Source-chain half of the crosschain POC (spec §9). Lives next to a PlasmaVault
///         (`MANAGER`), bridges assets/commands to remote same-address dispatchers, tracks per-chain NAV
///         in four mutually-exclusive buckets and exposes a fail-closed `getBalance()` for the balance
///         fuse. Deployed by the factory via CREATE3; the factory is injected as an explicit
///         constructor argument (not `msg.sender`, which is the ephemeral CREATE3 proxy).
/// @dev Concrete `StargateOAppBase`: implements the inbound message/compose hooks and overrides
///      `_beforeRescueExecuted` / `_afterRescueExecuted` for the tracked-ledger invariant. All NAV buckets are
///      stored in SHARED decimals; conversion to local ASSET decimals happens only at the API surface (`_toLD`).
///      NAV NEVER reads raw `ASSET.balanceOf(this)`.
///
///      To fit the EIP-170 runtime limit, the stateful NAV accounting, two-step attestation and command-lane
///      builder bodies are extracted into the external linked libraries `StargateExecutorAccountingLib` /
///      `StargateExecutorAttestationLib` / `StargateExecutorCommandLib`, which operate on the aggregate
///      `StargateExecutorState` storage by reference (delegatecall); the dispatcher-deployment bookkeeping and
///      the `registerChain` checks live in `StargateExecutorDeploymentLib`. This is a pure code relocation —
///      access control stays here, and the observable
///      behavior/storage semantics are identical to the inlined version (spec §12).
/// @author IPOR Labs
contract StargateCrosschainExecutor is StargateOAppBase, ICrosschainExecutor, IStargateExecutorLibraryAbi {
    using StargateExecutorAccountingLib for StargateExecutorState;
    using StargateExecutorAttestationLib for StargateExecutorState;
    using StargateExecutorCommandLib for StargateExecutorState;

    /// @notice Enforced-options key for plain LayerZero sends (commands and the recall lane).
    uint16 internal constant MSG_OPTION_TYPE = 1;

    /// @dev `CommandSent.action` value for an allowlist (UPDATE_VAULTS) command; outside the `BusinessAction`
    ///      range so the two command kinds are distinguishable.
    uint8 private constant UPDATE_VAULTS_COMMAND_ACTION = type(uint8).max;

    // ============================================================
    // Immutables (§9)
    // ============================================================

    /// @notice The factory that deployed this executor (CREATE3); source of the frozen path table.
    ICrosschainFactory public immutable FACTORY;

    /// @notice The PlasmaVault allowed to drive this executor (immutable).
    address public immutable MANAGER;

    /// @notice Chain-independent asset identity (e.g. `keccak256("USDC")`).
    bytes32 public immutable ASSET_ID;

    /// @notice Two-step attestation proposer (immutable, `!= BALANCE_APPROVER`).
    address public immutable BALANCE_PROPOSER;

    /// @notice Two-step attestation approver (immutable, `!= BALANCE_PROPOSER`).
    address public immutable BALANCE_APPROVER;

    /// @notice Max observation age before NAV blocks (seconds).
    uint256 public immutable STALENESS_MAX;

    /// @notice Big-change threshold in basis points for absolute settled overwrites.
    uint256 public immutable BIG_CHANGE_BPS;

    /// @notice Minimum interval between approved attestations for a chain (seconds).
    uint256 public immutable MIN_UPDATE_INTERVAL;

    /// @notice Seconds after which a dispatcher deployment ticket raised by this executor becomes
    ///         cancellable. Not read by the executor itself: the factory reads it through
    ///         `IExecutorDeploymentTtl` at `requestDispatcher` and stores it per ticket;
    ///         `cancelDispatcherRequest` forwards to the factory, which enforces it. Bounded at
    ///         construction to `[MIN_DEPLOYMENT_TTL, MAX_DEPLOYMENT_TTL]`.
    uint256 public immutable DEPLOYMENT_TTL;

    /// @notice Max in-flight transfer record age before NAV blocks (seconds).
    uint256 public immutable TRANSFER_STALENESS_MAX;

    /// @notice The executor's local chain id (`block.chainid` at construction).
    uint256 public immutable LOCAL_CHAIN_ID;

    // ============================================================
    // Aggregate mutable accounting/attestation state (§9)
    // ============================================================

    /// @notice All NAV buckets, transfer/return records, command slots and attestation proposals,
    ///         grouped so the accounting/attestation/command logic can live in linked libraries. Most fields are
    ///         re-exposed below through explicit getters; those deliberately not exposed (their getters do not
    ///         fit the EIP-170 headroom, e.g. `outboundTransfers`, `returnRecords`, `activeReturnRequest`,
    ///         `netPrincipal`) are listed, with the events to reconstruct them from, on `StargateExecutorState`.
    ///         Bucket amounts are in SHARED decimals (§9).
    StargateExecutorState internal _s;

    // ============================================================
    // Path / deployment bookkeeping (resident-only; keep auto-getters)
    // ============================================================

    /// @notice The chains that have (or had) a dispatcher; the iteration set for `getBalance()`.
    uint256[] public dispatcherChainIds;

    /// @notice Whether a ready dispatcher exists on a chain.
    mapping(uint256 chainId => bool ready) public hasDispatcher;

    /// @notice Number of registered path chains (bounded by `MAX_DISPATCHER_CHAINS`).
    uint256 public registeredChainCount;

    /// @notice Monotonic proposal id allocator.
    uint256 public proposalCount;

    /// @notice The pending request id per chain (blocks duplicate createDispatcher).
    mapping(uint256 chainId => uint256 requestId) public pendingRequestByChain;

    /// @notice Monotonic nonce for command id derivation.
    uint256 private _commandNonce;

    /// @notice Monotonic nonce for transfer/return id derivation.
    uint256 private _transferNonce;

    /// @notice Deployment request records by request id (factory-local).
    mapping(uint256 requestId => DeploymentRequestRecord record) internal _deploymentRequests;

    // ============================================================
    // Public getters reproducing the former storage auto-getters (§9)
    // ============================================================

    /// @notice Settled remote balance per chain (attestable, absolute-overwritable), shared decimals.
    function settledRemoteBalance(uint256 chainId_) external view returns (uint256) {
        return _s.settledRemoteBalance[chainId_];
    }

    /// @notice Outbound-in-flight per chain (bridged, awaiting destination compose ACK), shared decimals.
    function outboundInFlight(uint256 chainId_) external view returns (uint256) {
        return _s.outboundInFlight[chainId_];
    }

    /// @notice Return-in-flight per chain (recalled, awaiting delivery compose), shared decimals.
    function returnInFlight(uint256 chainId_) external view returns (uint256) {
        return _s.returnInFlight[chainId_];
    }

    /// @notice Attestation anchor per chain: the principal the ±band of `approveBalance` is measured against,
    ///         shared decimals. Mirrors `CcipCrosschainExecutor.attestationAnchorPrincipal`.
    function attestationAnchorPrincipal(uint256 chainId_) external view returns (uint256) {
        return _s.anchorPrincipal[chainId_];
    }

    /// @notice Frontier-repair latch per chain: set by ADVANCE_STATE_FRONTIER unless a block raised for another
    ///         reason already stands (IL-8620), cleared by every other block-raising site; while set, the next
    ///         approved attestation also lifts the chain block (`ChainUnblockedByApproval`). Mirrors the public
    ///         `CcipCrosschainExecutor.frontierRepairPending` mapping.
    function frontierRepairPending(uint256 chainId_) external view returns (bool) {
        return _s.frontierRepairPending[chainId_];
    }

    /// @notice Idle ledger — reconciled tokens physically held and attributable to NAV, shared decimals.
    function idleLedger() external view returns (uint256) {
        return _s.idleLedger;
    }

    /// @notice Tokens physically credited for compose-first returns but not yet reconciled into idle.
    function pendingArrivalReserve() external view returns (uint256) {
        return _s.pendingArrivalReserve;
    }

    /// @notice Oldest UNRESOLVED transfer/recall record timestamp for a chain (0 when none) — the
    ///         transfer-staleness clock. Repurposed from the former bucket-transition marker so a pending
    ///         recall whose value still sits in `settled` also ages this clock (§9 P2). Kept under the
    ///         same name for monitoring-tool compatibility. The cancelled-recall clock that NAV also gates on
    ///         (IL-8621) is read through `cancelledRecallClock`.
    function inFlightSince(uint256 chainId_) external view returns (uint64) {
        return StargateExecutorAccountingLib.oldestUnresolvedTransferAt(_s, chainId_);
    }

    /// @notice Per-chain contiguous acknowledged remote state version (version frontier, §9).
    function acknowledgedRemoteStateVersion(uint256 chainId_) external view returns (uint64) {
        return _s.acknowledgedRemoteStateVersion[chainId_];
    }

    /// @notice Per-chain accounting epoch; bumped when attested value lands or is re-attributed (not on an
    ///         outbound send or a rejected recall, IL-8622).
    function accountingEpoch(uint256 chainId_) external view returns (uint64) {
        return _s.accountingEpoch[chainId_];
    }

    /// @notice Whether a chain is blocked (fail-closed). Raised by a rejected proposal, `ADVANCE_STATE_FRONTIER`,
    ///         `DROP_RETURN_METADATA_INCLUDED`, a return leg booked without a staleness slot or a return rejection
    ///         after a value leg. Lifted by the timelocked `forceSetSettled`, by an approval while the
    ///         frontier-repair latch is set (`ChainUnblockedByApproval`), or by the finalization of the last
    ///         unclocked return when that return alone raised it (`NoClockReturnBlockLifted`, IL-8624).
    /// @dev A blocked chain gates `getBalance()` only while it tracks value (IL-8260).
    function chainBlocked(uint256 chainId_) external view returns (bool) {
        return _s.chainBlocked[chainId_];
    }

    /// @notice Number of open return records that own value but hold no staleness slot (IL-8618). While it is
    ///         non-zero `getBalance` is blocked for the chain and `forceSetSettled` reverts `UnclockedReturnOpen`.
    function noClockReturnCount(uint256 chainId_) external view returns (uint32) {
        return _s.noClockReturnCount[chainId_];
    }

    /// @notice Cancelled-recall clock of a chain (IL-8621): number of cancelled return requests whose legs are
    ///         still unresolved, the oldest one's `createdAt` (0 = no clock), the reset generation and the
    ///         acknowledged state version at the latest cancel (an approval bound past it clears the clock).
    function cancelledRecallClock(uint256 chainId_)
        external
        view
        returns (uint32 count, uint64 pendingAt, uint32 generation, uint64 cancelVersion)
    {
        return (
            _s.cancelledRecallCount[chainId_],
            _s.cancelledRecallPendingAt[chainId_],
            _s.cancelledRecallGeneration[chainId_],
            _s.cancelledRecallVersion[chainId_]
        );
    }

    /// @notice Active business command per chain.
    function activeCommand(uint256 chainId_)
        external
        view
        returns (
            bool active,
            bool isConfigUpdate,
            bool awaitingCancel,
            CommandStatus status,
            bytes32 commandId,
            uint64 sequence,
            uint64 newConfigEpoch
        )
    {
        ActiveCommand storage c = _s.activeCommand[chainId_];
        return (c.active, c.isConfigUpdate, c.awaitingCancel, c.status, c.commandId, c.sequence, c.newConfigEpoch);
    }

    /// @notice Business action of the active command on `chainId_` (0 if none or a config update).
    /// @dev Read by `StargateCrosschainCommandFuse` to gate `RETRY_COMMAND` exactly like `SEND_COMMAND` (IL-8600).
    function activeCommandAction(uint256 chainId_) external view returns (uint8) {
        return _s.activeCommand[chainId_].action;
    }

    /// @notice Target vault of the active command on `chainId_` when it is a DEPOSIT (0 otherwise).
    /// @dev Read by `StargateCrosschainCommandFuse` to re-check a retried DEPOSIT's target against the REMOTE_VAULT
    ///      substrates (IL-8600 follow-up). Written by `buildBusinessCommand` in `StargateExecutorCommandLib`.
    function activeCommandTarget(uint256 chainId_) external view returns (address) {
        return _s.activeCommand[chainId_].target;
    }

    /// @notice Next sequence to allocate for a new business command per chain (lockstep with dispatcher).
    function nextSequenceToSend(uint256 chainId_) external view returns (uint64) {
        return _s.nextSequenceToSend[chainId_];
    }

    /// @notice The executor's config epoch mirror per chain (advanced on UPDATE_VAULTS ACK).
    function chainConfigEpoch(uint256 chainId_) external view returns (uint64) {
        return _s.chainConfigEpoch[chainId_];
    }

    /// @notice Pending transfer count per chain (outbound + return).
    function pendingTransferCount(uint256 chainId_) external view returns (uint256) {
        return _s.pendingTransferCount[chainId_];
    }

    /// @notice Proposal records by proposal id.
    function proposals(uint256 proposalId_)
        external
        view
        returns (
            uint256 chainId,
            uint256 settledSD,
            uint64 stateVersion,
            uint64 remoteBlock,
            uint64 remoteTimestamp,
            uint64 expiry,
            bytes32 trackedPositionSetHash,
            uint64 accountingEpochSnapshot,
            uint8 status
        )
    {
        Proposal storage p = _s.proposals[proposalId_];
        return (
            p.chainId,
            p.settledSD,
            p.stateVersion,
            p.remoteBlock,
            p.remoteTimestamp,
            p.expiry,
            p.trackedPositionSetHash,
            p.accountingEpochSnapshot,
            p.status
        );
    }

    /// @notice The active proposal id per chain (0 = none).
    function activeProposalId(uint256 chainId_) external view returns (uint256) {
        return _s.activeProposalId[chainId_];
    }

    /// @notice REMOTE observation timestamp of the last approved proposal per chain (the NAV settled
    ///         freshness marker — settled becomes stale relative to this, not the local approval time, §9 P1).
    function lastApprovedObservedAt(uint256 chainId_) external view returns (uint64) {
        return _s.lastApprovedObservedAt[chainId_];
    }

    /// @notice LOCAL timestamp of the last approval per chain (the MIN_UPDATE_INTERVAL rate-limit marker).
    function lastApprovalAt(uint256 chainId_) external view returns (uint64) {
        return _s.lastApprovalAt[chainId_];
    }

    // ============================================================
    // Events
    // ============================================================

    event AssetSentToDispatcher(uint256 dstChainId, bytes32 transferId, bytes32 guid, uint256 amountSD);
    /// @dev Amounts in shared decimals; semantics of `sentSD` / `creditedSD` are documented on
    ///      `StargateExecutorAccountingLib.TransferSettledInbound`.
    event TransferSettledInbound(
        uint256 srcChainId,
        bytes32 transferId,
        bytes32 guid,
        uint256 sentSD,
        uint256 creditedSD,
        uint64 stateVersion
    );
    event ReturnRequested(uint256 dstChainId, bytes32 requestId, uint256 amountSD, uint256 maxAccountedSD);
    /// @dev See `StargateExecutorAccountingLib.ReturnMetadataApplied` for the field definitions.
    event ReturnMetadataApplied(
        uint256 srcChainId,
        bytes32 requestId,
        bytes32 guid,
        uint256 amountSentSD,
        uint256 debitedSD,
        uint256 inFlightCreditSD,
        uint64 stateVersion
    );
    event ReturnFinalized(uint256 srcChainId, bytes32 requestId, uint256 idleCreditSD);
    event ReturnRejectedByDispatcher(uint256 srcChainId, bytes32 requestId, uint8 reason);
    event ReturnRequestCancelled(uint256 chainId, bytes32 requestId);
    event ReturnDebitExceededAccountingBound(
        uint256 srcChainId,
        bytes32 requestId,
        uint256 amountSentSD,
        uint256 accountedDebitSD,
        uint256 unaccountedDebitSD
    );
    event LateReturnMetadataConsumedWithoutDebit(uint256 srcChainId, bytes32 requestId, uint64 stateVersion);
    /// @notice A command was sent to the dispatcher.
    /// @dev `action` is the `BusinessAction` of a business command (1-4), or `type(uint8).max` (0xFF) for an
    ///      allowlist update, whose vault list is in the `VaultsUpdateRequested` event with the same `commandId`.
    event CommandSent(uint256 dstChainId, bytes32 commandId, uint64 sequence, uint8 action);
    event CommandAcknowledged(
        uint256 srcChainId, bytes32 commandId, uint64 stateVersion, int256 valueDeltaSD, uint8 resolution
    );
    event CommandFailed(uint256 srcChainId, bytes32 commandId);
    event ConfigEpochResynced(uint256 srcChainId, uint64 expectedEpoch, uint64 dispatcherEpoch);
    event LateReceiptEpochAdopted(uint256 srcChainId, uint64 sequence, uint64 previousEpoch, uint64 newEpoch);
    event CommandAbandoned(uint256 chainId, bytes32 commandId, uint64 sequence, bool sequenceConsumed);
    event CommandReceiptConsumedWithoutCommand(uint256 srcChainId, bytes32 commandId, uint64 stateVersion);
    event CommandReceiptAdopted(
        uint256 srcChainId,
        bytes32 commandId,
        uint64 sequence,
        uint64 dispatcherConfigEpoch,
        bytes32 supersededCommandId
    );
    event CommandLaneRealigned(
        uint256 chainId, uint64 previousSequence, uint64 newSequence, uint64 previousEpoch, uint64 newEpoch
    );
    event TransferSettlementConsumedWithoutAccounting(uint256 srcChainId, bytes32 transferId, uint64 stateVersion);
    event CommandRetried(uint256 dstChainId, bytes32 commandId);
    event CommandCancelRequested(uint256 dstChainId, bytes32 commandId);
    event AssetClaimed(address manager, uint256 amount);
    event ChainRegistered(uint256 chainId, uint32 eid);
    event DispatcherRequested(uint256 dstChainId, uint256 requestId);
    event DispatcherReady(uint256 dstChainId, uint256 requestId);
    event DispatcherRequestResolved(uint256 requestId, uint8 status);
    event BalanceProposed(
        uint256 proposalId,
        uint256 chainId,
        uint256 settledSD,
        uint64 stateVersion,
        uint64 remoteBlock,
        uint64 remoteTimestamp,
        uint64 expiry,
        bytes32 trackedPositionSetHash
    );
    event BalanceApproved(uint256 proposalId, uint256 chainId, uint256 settledSD, uint64 remoteTimestamp);
    event BalanceRejectedAndBlocked(uint256 proposalId, uint256 chainId);
    event SettledBalanceForceSet(uint256 chainId, uint256 settledSD);
    event TransferForceResolved(bytes32 id, uint8 outcome);

    // ============================================================
    // Modifiers
    // ============================================================

    /// @notice Restricts a function to the immutable manager (the PlasmaVault).
    modifier onlyManager() {
        _checkManager();
        _;
    }

    /// @notice Restricts a callback to the deploying factory.
    modifier onlyFactory() {
        _checkFactory();
        _;
    }

    modifier onlyBalanceApprover() {
        _checkApprover();
        _;
    }

    /// @param endpoint_ LayerZero V2 endpoint.
    /// @param asset_ Local ERC20 asset (resolved by the factory from `assetId_`).
    /// @param stargatePool_ Local Stargate pool for `asset_`.
    /// @param assetId_ Chain-independent asset identity.
    /// @param factory_ The deploying factory, injected explicitly (Solady CREATE3 deploys through an
    ///        ephemeral proxy, so `msg.sender` here would be that proxy — not the factory).
    /// @param p_ Immutable executor configuration (manager, roles, timelock/freshness params).
    constructor(
        address endpoint_,
        address asset_,
        address stargatePool_,
        bytes32 assetId_,
        address factory_,
        ExecutorInitParams memory p_
    ) StargateOAppBase(endpoint_, p_.admin, p_.admin, p_.rescueGuardian, p_.rescueDelay, asset_, stargatePool_) {
        if (p_.manager == address(0)) revert CrosschainErrors.ZeroAddress();
        if (p_.balanceProposer == address(0) || p_.balanceApprover == address(0)) {
            revert CrosschainErrors.ZeroAddress();
        }
        if (p_.balanceProposer == p_.balanceApprover) revert CrosschainErrors.ProposerEqualsApprover();
        if (factory_ == address(0)) revert CrosschainErrors.ZeroAddress();
        // The unresolved-transfer staleness pool is a fixed-size array that MUST match the per-chain
        // concurrent-record cap; a mismatch would let the cap gate admit a record with no free slot (§9 P2).
        if (MAX_PENDING_TRANSFERS_PER_CHAIN_SLOTS != CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN) {
            revert CrosschainErrors.ZeroAddress();
        }
        // Config sanity (§8 P3, IL-8049). Every value below is immutable on a non-upgradeable contract, so a
        // legal-but-degenerate value can never be corrected; reject the boundaries that disable a named guard.
        // The relative big-change step must be nonzero (zero admits only zero-delta approvals and pins NAV)
        // and must not exceed the anchor band, so that a single compliant relative step from `anchorPrincipal`
        // can never be rejected by the band alone. This is a deliberate tightening, not the removal of dead
        // configuration: the band confines `newSettled` to [0.8P, 1.2P], which still permits a 50% relative
        // step, so the relative gate keeps binding on its own below 5_000 bps (at 5_000 the band alone binds).
        if (p_.bigChangeBps == 0 || p_.bigChangeBps > CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS) {
            revert CrosschainErrors.InvalidBigChangeBps(p_.bigChangeBps);
        }
        // Zero staleness windows would block NAV permanently; windows above the ceiling make the fail-closed
        // staleness gates unreachable. The endpoint is validated in the transport base.
        if (p_.stalenessMax == 0 || p_.transferStalenessMax == 0) revert CrosschainErrors.InvalidTimingParameter();
        if (
            p_.stalenessMax > CrosschainConstants.MAX_STALENESS_WINDOW
                || p_.transferStalenessMax > CrosschainConstants.MAX_STALENESS_WINDOW
        ) revert CrosschainErrors.InvalidTimingParameter();
        // The mandated minimum approval window must fit inside the freshness window, otherwise every aged
        // observation would be unapprovable and the window guarantee would be a dead letter (V2-02).
        if (p_.stalenessMax < CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW) {
            revert CrosschainErrors.InvalidTimingParameter();
        }
        // A zero cadence interval lets the attester pair approve repeatedly inside one transaction. An interval
        // at or above the freshness window collides the cadence gate with the NAV freshness gate: strictly
        // above it, every pair of approvals is separated by a NavSettledStale gap; exactly at it, the next
        // approval still lands inside the window only on the knife-edge where the observation timestamp equals
        // the approval block timestamp (freshness is `>` against `lastApprovedObservedAt`, cadence is `<`
        // against `lastApprovalAt`), so any real observation lag freezes NAV. Reject the endpoint too — the
        // value is immutable and cannot be corrected afterwards.
        if (p_.minUpdateInterval == 0 || p_.minUpdateInterval >= p_.stalenessMax) {
            revert CrosschainErrors.InvalidTimingParameter();
        }
        // The deployment TTL is consumed by the factory per ticket (see DEPLOYMENT_TTL); both ends are unsafe.
        if (
            p_.deploymentTtl < CrosschainConstants.MIN_DEPLOYMENT_TTL
                || p_.deploymentTtl > CrosschainConstants.MAX_DEPLOYMENT_TTL
        ) {
            revert CrosschainErrors.InvalidDeploymentTtl(
                p_.deploymentTtl, CrosschainConstants.MIN_DEPLOYMENT_TTL, CrosschainConstants.MAX_DEPLOYMENT_TTL
            );
        }

        // The factory is injected EXPLICITLY (not `msg.sender`): Solady CREATE3 deploys through an
        // ephemeral proxy, so `msg.sender` in this constructor is that proxy, not the factory. Using
        // `factory_` does not affect the CREATE3 address (which depends only on salt + deployer).
        FACTORY = ICrosschainFactory(factory_);
        MANAGER = p_.manager;
        ASSET_ID = assetId_;
        BALANCE_PROPOSER = p_.balanceProposer;
        BALANCE_APPROVER = p_.balanceApprover;
        STALENESS_MAX = p_.stalenessMax;
        BIG_CHANGE_BPS = p_.bigChangeBps;
        MIN_UPDATE_INTERVAL = p_.minUpdateInterval;
        DEPLOYMENT_TTL = p_.deploymentTtl;
        TRANSFER_STALENESS_MAX = p_.transferStalenessMax;
        LOCAL_CHAIN_ID = block.chainid;

        // Seal ownership last: no runtime owner is needed (config flows via manager/messages, and the
        // base already neutralized setPeer/setEnforcedOptions/setDelegate and cleared the delegate). (spec §8)
        _transferOwnership(address(0));
    }

    // ============================================================
    // Manager actions (§9)
    // ============================================================

    /// @inheritdoc ICrosschainExecutor
    function claimAsset(uint256 amount_) external override onlyManager nonReentrant {
        StargateExecutorAccountingLib.claimAsset(_s, ASSET, MANAGER, amount_, _decimalConversionRate);
    }

    /// @inheritdoc ICrosschainExecutor
    function registerChain(uint256 chainId_, uint32 eid_, bytes calldata enforcedOptions_)
        external
        override
        onlyManager
    {
        // Cap, factory path equality and command-lane options are checked in the linked library
        // (IL-8296); the base write below re-decodes the same bytes.
        _s.commandLaneReceiveGas[chainId_] = StargateExecutorDeploymentLib.validateRegistration(
            _factory(), registeredChainCount, chainId_, eid_, MSG_OPTION_TYPE, enforcedOptions_
        );
        _registerPath(chainId_, eid_, enforcedOptions_);
        unchecked {
            ++registeredChainCount;
        }
        emit ChainRegistered(chainId_, eid_);
    }

    /// @inheritdoc ICrosschainExecutor
    function createDispatcher(uint256 dstChainId_, address[] calldata plasmaVaults_) external override onlyManager {
        if (_chainToEid[dstChainId_] == 0) revert CrosschainErrors.UnknownChain(dstChainId_);
        if (hasDispatcher[dstChainId_]) revert CrosschainErrors.DispatcherAlreadyExists(dstChainId_);
        if (pendingRequestByChain[dstChainId_] != 0) revert CrosschainErrors.DispatcherRequestPending(dstChainId_);
        StargateExecutorAccountingLib.validateVaultShape(plasmaVaults_);

        StargateExecutorDeploymentLib.request(
            pendingRequestByChain,
            _deploymentRequests,
            _factory(),
            StargateExecutorDeploymentLib.RequestParams({
                assetId: ASSET_ID,
                admin: ADMIN,
                guardian: RESCUE_GUARDIAN,
                rescueDelay: RESCUE_DELAY,
                srcChainId: LOCAL_CHAIN_ID,
                dstChainId: dstChainId_
            }),
            plasmaVaults_
        );
    }

    /// @inheritdoc ICrosschainExecutor
    function cancelDispatcherRequest(uint256 requestId_) external override onlyManager {
        if (_deploymentRequests[requestId_].status != DeploymentStatus.PENDING) {
            revert CrosschainErrors.DeploymentRequestInvalid(requestId_);
        }
        // Factory enforces the TTL and calls back `onDispatcherRequestCancelled` locally.
        _factory().cancelPendingDeployment(requestId_);
    }

    /// @inheritdoc ICrosschainExecutor
    function updatePlasmaVaults(uint256 dstChainId_, address[] calldata vaults_) external override onlyManager {
        _requireReady(dstChainId_);
        if (_s.activeCommand[dstChainId_].active) revert CrosschainErrors.ActiveCommandExists(dstChainId_);
        StargateExecutorAccountingLib.validateVaultShape(vaults_);
        _sendUpdateVaults(dstChainId_, vaults_);
    }

    /// @inheritdoc ICrosschainExecutor
    function sendAssetToDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 minAmountLD_,
        bytes calldata lzOptions_
    ) external override onlyManager nonReentrant {
        _validateTransferRequest(dstChainId_, amount_);

        // Source-of-funds guard (invariant #4): only fresh untracked tokens may be bridged.
        StargateExecutorAccountingLib.validateSourceOfFunds(_s, ASSET, amount_, _decimalConversionRate);

        bytes32 transferId = keccak256(abi.encode(address(this), dstChainId_, _transferNonce++));
        bytes memory composeMsg = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: transferId}));
        (bytes32 guid,, uint256 amountReceivedLD) =
            _sendAsset(dstChainId_, amount_, minAmountLD_, composeMsg, lzOptions_);

        uint256 receivedSD = _toSD(amountReceivedLD);
        // Post-send accounting (record + outbound-in-flight + slot; no epoch bump, IL-8622) runs in the linked
        // library.
        _s.recordOutbound(dstChainId_, transferId, guid, receivedSD);
        emit AssetSentToDispatcher(dstChainId_, transferId, guid, receivedSD);
    }

    /// @inheritdoc ICrosschainExecutor
    function requestAssetsFromDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 minReturn_,
        bytes calldata lzOptions_
    ) external override onlyManager nonReentrant {
        _validateTransferRequest(dstChainId_, amount_);

        uint256 amountSD = _toSD(amount_);
        // Bind the accounted upper bound so un-attested yield cannot underflow source accounting.
        uint256 maxAccountedSD = amountSD;
        uint256 settled = _s.settledRemoteBalance[dstChainId_];
        if (maxAccountedSD > settled) maxAccountedSD = settled;
        uint256 minReturnSD = _toSD(minReturn_);

        bytes32 requestId = keccak256(abi.encode(address(this), dstChainId_, "RETURN", _transferNonce++));
        // Record the pending return and build the RETURN_ASSETS_REQUEST envelope in the linked library.
        bytes memory payload = _s.buildReturnRequest(dstChainId_, requestId, amountSD, maxAccountedSD, minReturnSD);
        _sendLzMessage(dstChainId_, payload, MSG_OPTION_TYPE, lzOptions_);
        emit ReturnRequested(dstChainId_, requestId, amountSD, maxAccountedSD);
    }

    /// @notice Permissionless liveness escape for a recall whose authenticated metadata never arrived.
    ///         A late authenticated return is still processed exactly once and cannot clear a newer recall.
    /// @dev Deliberately permissionless, and safe to be so because it is accounting-neutral: it only
    ///      applies to a recall on which nothing has moved between NAV buckets (no `RETURN_STARTED`, no
    ///      delivery compose), where the value is still counted — and gated for freshness — in
    ///      `settledRemoteBalance`. Once metadata or the compose has landed, the record owns value whose
    ///      only staleness clock is its unresolved-transfer slot; the library then reverts
    ///      `ReturnRequestValueMoved` and the terminal exit is the timelocked
    ///      `scheduleForceResolveTransfer`/`executeForceResolveTransfer` rescue, which also removes the
    ///      value from the NAV buckets. A delivery compose that lands AFTER this cancel released the
    ///      slot (IL-7966) is not left unsignalled WHILE THE RECORD IS STILL OPEN: `handleReturnCompose`
    ///      re-arms a fresh slot on the reopened record, or fails the chain closed via `chainBlocked` if
    ///      none is free. If the record was already force-resolved in the meantime, the tombstone rule
    ///      applies instead and the tokens are untracked surplus recoverable through the generic rescue.
    ///      The cancel does NOT disarm the NAV gate: it keeps the per-chain cancelled-recall clock armed
    ///      (IL-8621), so `getBalance` keeps reverting `NavTransferStale` until a leg, a rejection, an
    ///      approval bound past the cancel-time state version or a reset clears it.
    ///      There is deliberately no manager-only cancel without the staleness precondition (unlike CCIP's
    ///      `cancelPendingReturn`); see `contracts/crosschain/stargate/README.md`.
    function cancelStaleReturnRequest(uint256 chainId_) external nonReentrant {
        // The library emits `ReturnRequestCancelled` (EIP-170).
        _s.cancelStaleReturn(chainId_, TRANSFER_STALENESS_MAX);
    }

    /// @inheritdoc ICrosschainExecutor
    function sendCommandToDispatcher(uint256 dstChainId_, Command calldata cmd_) external override onlyManager {
        _requireReady(dstChainId_);

        // The executor allocates the authoritative id/sequence/commandConfigEpoch (in the library); only
        // `action`/`actionData` come from the manager-supplied `cmd_`. The library enforces the
        // one-active-command-per-chain slot and returns the encoded COMMAND envelope.
        // IL-8625: `cmd_.minExecutionGas` is an optional gas top-up (0 = the lane budget, at most
        // `MAX_COMMAND_EXECUTION_GAS`); above the lane budget the library returns the extra `lzReceive` option.
        (bytes memory payload, bytes32 commandId, uint64 sequence, bytes memory extraOptions) =
            _s.buildBusinessCommand(dstChainId_, cmd_.action, cmd_.actionData, ++_commandNonce, cmd_.minExecutionGas);
        _sendLzMessage(dstChainId_, payload, MSG_OPTION_TYPE, extraOptions);
        emit CommandSent(dstChainId_, commandId, sequence, cmd_.action);
    }

    /// @notice Retry a FAILED business command on the recall lane (same id, dispatcher re-executes).
    /// @dev Declared by `ICrosschainExecutor` (spec §9 recall lane). Manager only. Reverts `CommandExpired` past
    ///      the command's deadline (IL-8625): cancel it instead.
    /// @param dstChainId_ The chain whose FAILED command should be retried.
    function retryCommand(uint256 dstChainId_) external onlyManager {
        _retry(dstChainId_, 0);
    }

    /// @notice Retry a FAILED business command with a raised gas budget (IL-8625): the dispatcher runs
    ///         `max(stored, raised)` and persists it; the retry is sent with the extra `lzReceive` gas the budget
    ///         needs. A raise below the stored budget changes nothing (a retry can only raise). Reverts
    ///         `CommandBudgetAboveMax` above `MAX_COMMAND_EXECUTION_GAS`.
    /// @param dstChainId_ The chain whose FAILED command should be retried.
    /// @param minExecutionGas_ The raised budget, 0 = keep the stored one.
    function retryCommandWithBudget(uint256 dstChainId_, uint64 minExecutionGas_) external onlyManager {
        _retry(dstChainId_, minExecutionGas_);
    }

    function _retry(uint256 dstChainId_, uint256 budget_) private {
        (bytes memory payload, bytes32 commandId, bytes memory extraOptions) = _s.buildRetry(dstChainId_, budget_);
        _sendLzMessage(dstChainId_, payload, MSG_OPTION_TYPE, extraOptions);
        emit CommandRetried(dstChainId_, commandId);
    }

    /// @notice Cancel a FAILED business command on the recall lane; frees the slot on the ACK.
    /// @dev Declared by `ICrosschainExecutor` (spec §9 recall lane). Manager only. A repeat reverts
    ///      `CancelCooldown` until `CANCEL_COMMAND_COOLDOWN` has passed since the previous send (IL-8579).
    /// @param dstChainId_ The chain whose FAILED command should be cancelled.
    function cancelCommand(uint256 dstChainId_) external onlyManager {
        (bytes memory payload, bytes32 commandId) = _s.buildCancel(dstChainId_);
        _sendLzMessage(dstChainId_, payload, MSG_OPTION_TYPE, "");
        emit CommandCancelRequested(dstChainId_, commandId);
    }

    // ============================================================
    // Attestation (two-step, §9)
    // ============================================================

    /// @inheritdoc ICrosschainExecutor
    function proposeBalance(BalanceObservation calldata observation_) external override {
        if (msg.sender != BALANCE_PROPOSER) revert CrosschainErrors.UnauthorizedProposer(msg.sender);
        uint256 chainId = observation_.chainId;
        _requireReady(chainId);

        // Access + dispatcher gating stay here; the proposal body (version/expiry/staleness checks +
        // record creation) runs in the linked attestation library. `proposalId` is allocated here so the
        // monotonic `proposalCount` getter stays a resident auto-getter.
        uint256 proposalId = ++proposalCount;
        _s.propose(
            chainId,
            _toSD(observation_.settledBalance),
            observation_.stateVersion,
            observation_.remoteBlock,
            observation_.remoteTimestamp,
            observation_.expiry,
            observation_.trackedPositionSetHash,
            _stalenessMax(),
            proposalId
        );
    }

    /// @inheritdoc ICrosschainExecutor
    function approveBalance(uint256 proposalId_) external override onlyBalanceApprover {
        _s.approve(proposalId_, BIG_CHANGE_BPS, MIN_UPDATE_INTERVAL, _stalenessMax());
    }

    /// @inheritdoc ICrosschainExecutor
    function rejectAndBlockProposal(uint256 proposalId_) external override onlyBalanceApprover {
        _s.reject(proposalId_);
    }

    // ============================================================
    // Views (local ASSET decimals, §9)
    // ============================================================

    /// @inheritdoc ICrosschainExecutor
    function getBalance() external view override returns (uint256) {
        // Fail-closed NAV summation (shared decimals) runs in the linked library; convert to local here.
        return _toLD(_s.computeNavSD(dispatcherChainIds, _stalenessMax(), TRANSFER_STALENESS_MAX));
    }

    /// @inheritdoc ICrosschainExecutor
    /// @dev Booked balance without the staleness gates. Reverts `ChainBlocked` exactly where `getBalance()` does: a
    ///      blocked chain that still tracks value (`settled + outbound + return != 0`, IL-8260), or a chain with a
    ///      return record without a staleness slot (`noClockReturnCount != 0`, IL-8618). Such a chain means the books
    ///      are known-inconsistent until a rescue completes (e.g. `DROP_RETURN_METADATA_INCLUDED` credits
    ///      `idleLedger` while `settledRemoteBalance` still holds the same value). It is checked here, not only by
    ///      the caller, since `getBalance()` may surface a staleness selector first while such a chain exists.
    function getBalanceUnchecked() external view override returns (uint256 total) {
        // Booked summation without the staleness gates (shared decimals) runs in the linked library.
        total = _toLD(_s.computeBookedSD(dispatcherChainIds));
    }

    /// @inheritdoc ICrosschainExecutor
    function getBalanceByChain(uint256 chainId_) external view override returns (uint256) {
        return _toLD(_s.settledRemoteBalance[chainId_] + _s.outboundInFlight[chainId_] + _s.returnInFlight[chainId_]);
    }

    /// @inheritdoc ICrosschainExecutor
    function isDispatcherReady(uint256 chainId_) external view override returns (bool) {
        return hasDispatcher[chainId_];
    }

    /// @inheritdoc ICrosschainExecutor
    function deploymentStatus(uint256 requestId_) external view override returns (DeploymentStatus) {
        return _deploymentRequests[requestId_].status;
    }

    /// @notice The persisted initial vault list for a pending/completed deployment request.
    /// @param requestId_ The request id.
    /// @return dstChainId The destination chain.
    /// @return vaults The persisted initial allowlist.
    function deploymentRequestInfo(uint256 requestId_)
        external
        view
        returns (uint256 dstChainId, address[] memory vaults)
    {
        DeploymentRequestRecord storage rec = _deploymentRequests[requestId_];
        return (rec.dstChainId, rec.vaults);
    }

    // ============================================================
    // Factory-only callbacks (local, NOT lzReceive) (§9 #14)
    // ============================================================

    /// @inheritdoc ICrosschainExecutor
    function onDispatcherCreated(uint256 requestId_, uint256 dstChainId_, address dispatcher_)
        external
        override
        onlyFactory
    {
        address[] memory vaults = StargateExecutorDeploymentLib.markReady(
            pendingRequestByChain,
            _deploymentRequests,
            hasDispatcher,
            dispatcherChainIds,
            requestId_,
            dstChainId_,
            dispatcher_
        );

        // Auto-send the persisted initial allowlist as the first sequenced UPDATE_VAULTS command; the
        // business-command slot is necessarily free at this moment. If quoting/payment fails, this
        // reverts and the factory ACK delivery is retried.
        _sendUpdateVaults(dstChainId_, vaults);
    }

    /// @inheritdoc ICrosschainExecutor
    function onDispatcherRequestFailed(uint256 requestId_) external override onlyFactory {
        StargateExecutorDeploymentLib.resolve(
            pendingRequestByChain, _deploymentRequests, requestId_, DeploymentStatus.FAILED
        );
    }

    /// @inheritdoc ICrosschainExecutor
    function onDispatcherRequestCancelled(uint256 requestId_) external override onlyFactory {
        StargateExecutorDeploymentLib.resolve(
            pendingRequestByChain, _deploymentRequests, requestId_, DeploymentStatus.CANCELLED
        );
    }

    // ============================================================
    // Rescue exits (admin, timelocked + guardian veto) (§9 #9/#15)
    // ============================================================

    /// @notice Schedule a timelocked settled-balance overwrite (unblocks a rejected/blocked chain, §9).
    /// @dev Reverts `DispatcherNotReady` when the target chain has no ready dispatcher (IL-8113), and
    ///      `ForceSetStateVersionMismatch` when `observedStateVersion_` is BEHIND the acknowledged frontier:
    ///      the frontier never moves backwards, so such an observation could never execute. An observation
    ///      AHEAD of the frontier stays schedulable — the frontier may catch up during the delay.
    /// @param chainId_ The chain to force-set.
    /// @param newSettledLD_ The new settled balance in local ASSET decimals.
    /// @param observedStateVersion_ The dispatcher `stateVersion()` at which the balance was read. Execute
    ///        reverts unless it equals `acknowledgedRemoteStateVersion(chainId_)` then (IL-8264).
    /// @param observedRemoteTimestamp_ The remote (dispatcher chain) timestamp at which the balance was read
    ///        (IL-8646 / TP-L-18). Committed in the schedule-time hash; execute stamps it as the NAV freshness
    ///        clock (`lastApprovedObservedAt`) instead of the execute time. Reverts `ObservationStale` unless
    ///        `block.timestamp - STALENESS_MAX <= observedRemoteTimestamp_ <= block.timestamp` (and non-zero).
    ///        NAV is stale right after execute exactly when `executeTime - observedRemoteTimestamp_ >
    ///        STALENESS_MAX`: an observation older than `STALENESS_MAX - RESCUE_DELAY` at schedule is sufficient
    ///        but not necessary (a late execution also ages it), and always stale if `RESCUE_DELAY >= STALENESS_MAX`.
    /// @param allowOlderThanApproved_ IL-8648 R1: `false` (the default choice) makes execute revert
    ///        `ForceSetOlderThanApproved` when `lastApprovedObservedAt` is then newer than `observedRemoteTimestamp_`
    ///        (e.g. an ordinary approval of a fresher observation landed during the delay), so the NAV freshness
    ///        clock never moves backwards silently. `true` opts out on purpose (e.g. a hostile attester pair
    ///        approving a fresh observation in every rescue window, or ordinary attestation that cannot be halted
    ///        for the delay). The flag is part of the commitment, so the guardian sees it in the schedule
    ///        calldata and a strict schedule cannot be executed as unchecked.
    /// @return rescueId The scheduled force-resolve id.
    function scheduleForceSetSettledBalance(
        uint256 chainId_,
        uint256 newSettledLD_,
        uint64 observedStateVersion_,
        uint64 observedRemoteTimestamp_,
        bool allowOlderThanApproved_
    ) external onlyRescueAdmin returns (uint256 rescueId) {
        _requireReady(chainId_);
        // Schedule-time gates (version not behind the frontier, plausible fresh observation time) run in the
        // linked library (EIP-170).
        _s.checkForceSetSchedule(chainId_, observedStateVersion_, observedRemoteTimestamp_, _stalenessMax());
        return _scheduleForceResolve(
            keccak256(
                abi.encode(
                    "SETTLED",
                    chainId_,
                    newSettledLD_,
                    observedStateVersion_,
                    observedRemoteTimestamp_,
                    allowOlderThanApproved_
                )
            )
        );
    }

    /// @notice Execute a scheduled settled-balance overwrite after the rescue delay.
    /// @param rescueId_ The scheduled id.
    /// @param chainId_ The chain to force-set.
    /// @param newSettledLD_ The new settled balance in local ASSET decimals.
    /// @param observedStateVersion_ The dispatcher state version the balance was read at.
    /// @param observedRemoteTimestamp_ The remote observation timestamp committed at schedule time (IL-8646).
    /// @param allowOlderThanApproved_ As scheduled (IL-8648 R1); bound by the commitment.
    function executeForceSetSettledBalance(
        uint256 rescueId_,
        uint256 chainId_,
        uint256 newSettledLD_,
        uint64 observedStateVersion_,
        uint64 observedRemoteTimestamp_,
        bool allowOlderThanApproved_
    ) external onlyRescueAdmin {
        _consumeForceResolve(
            rescueId_,
            keccak256(
                abi.encode(
                    "SETTLED",
                    chainId_,
                    newSettledLD_,
                    observedStateVersion_,
                    observedRemoteTimestamp_,
                    allowOlderThanApproved_
                )
            )
        );
        _s.forceSetSettled(
            hasDispatcher,
            chainId_,
            _toSD(newSettledLD_),
            observedStateVersion_,
            observedRemoteTimestamp_,
            allowOlderThanApproved_
        );
    }

    /// @notice Schedule a timelocked terminal resolution of a permanently stuck in-flight record (§9 #15).
    /// @dev Reverts `DispatcherNotReady` when `outcome_` is `ADVANCE_STATE_FRONTIER` and the chain decoded
    ///      from `transferId_` has no ready dispatcher (IL-8113).
    /// @dev `REALIGN_COMMAND_LANE` (IL-8652) packs `(uint64 chainId << 192) | (uint48 expectedEpoch << 144) |
    ///      (uint48 expectedSequence << 96) | (uint48 newEpoch << 48) | uint48 newSequence`, where the expected
    ///      pair is this executor's own `chainConfigEpoch` / `nextSequenceToSend` mirrors. Schedule reverts
    ///      `DispatcherNotReady` when the decoded chain has no ready dispatcher (a mis-packed id). A zero
    ///      expected epoch is a valid declaration and is not refused: on Stargate the epoch mirror is 0 until the
    ///      first UPDATE_VAULTS ACK (CCIP differs because its route initialisation sets the epoch to 1).
    ///      The pair itself is checked at EXECUTE time: it reverts `RealignStateMoved` if an ACK moved the mirrors
    ///      during the delay, and the free-slot requirement is also execute-time so an abandon and the realign can
    ///      be armed together. Re-decode `id >> 192` yourself first; only the commitment hash is stored.
    /// @dev Reverts `ForceResolveWrongState` for `RETURNED_TO_IDLE`: the outcome is reserved and no record
    ///      state can execute it (unreachable since H-01), so it is refused before the delay is spent and
    ///      a pending-rescue slot is taken (IL-8484).
    /// @param transferId_ The outbound transfer id or return request id.
    /// @param outcome_ The declared terminal outcome.
    /// @return rescueId The scheduled force-resolve id.
    function scheduleForceResolveTransfer(bytes32 transferId_, ResolveOutcome outcome_)
        external
        onlyRescueAdmin
        returns (uint256 rescueId)
    {
        bytes32 commitment = keccak256(abi.encode(transferId_, uint8(outcome_)));
        if (outcome_ == ResolveOutcome.RETURNED_TO_IDLE) revert CrosschainErrors.ForceResolveWrongState(transferId_);
        if (outcome_ == ResolveOutcome.ADVANCE_STATE_FRONTIER) {
            // The repair id packs `(chainId << 64) | newVersion`; a mis-packed id decodes to an unrelated chain.
            // Fail here, before the timelock is spent (IL-8113); the library re-checks at execute time.
            _requireReady(uint256(transferId_) >> 64);
            return _scheduleFrontierRepair(commitment);
        }
        if (outcome_ == ResolveOutcome.REALIGN_COMMAND_LANE) {
            _requireReady(uint256(transferId_) >> 192);
        }
        return _scheduleForceResolve(commitment);
    }

    /// @notice Execute a scheduled force-resolve after the rescue delay, applying the declared outcome.
    /// @param rescueId_ The scheduled id.
    /// @param transferId_ The outbound transfer id or return request id.
    /// @param outcome_ The declared terminal outcome.
    function executeForceResolveTransfer(uint256 rescueId_, bytes32 transferId_, ResolveOutcome outcome_)
        external
        onlyRescueAdmin
    {
        _consumeForceResolve(rescueId_, keccak256(abi.encode(transferId_, uint8(outcome_))));
        _s.applyForceResolve(hasDispatcher, transferId_, outcome_);
        emit TransferForceResolved(transferId_, uint8(outcome_));
    }

    // ============================================================
    // Inbound handlers (§9) — decode + auth stay here, bodies in the library
    // ============================================================

    /// @inheritdoc StargateOAppBase
    function _handleCompose(uint256 srcChainId_, bytes32 guid_, uint256 amountLD_, MsgType msgType_, bytes memory data_)
        internal
        override
    {
        // On the executor, an inbound compose is a returned-asset delivery. It reuses the
        // OUTBOUND_TRANSFER envelope carrying the return `requestId` in `transferId`.
        if (msgType_ != MsgType.OUTBOUND_TRANSFER) revert CrosschainErrors.UnexpectedMessageType(uint8(msgType_));
        // Convert the destination-credited amount to shared decimals here (the executor owns the rate);
        // the library decodes the return `requestId` and applies the compose accounting.
        _s.handleReturnCompose(srcChainId_, data_, guid_, _toSD(amountLD_));
    }

    /// @notice Handle a decoded, authenticated inbound plain message (peer already verified by the base).
    /// @dev Routes command receipts (ACK/NACK), outbound settlements, return metadata and return rejections
    ///      (spec §9).
    function _handleLzMessage(MsgType msgType_, uint256 srcChainId_, Origin calldata, bytes memory data_)
        internal
        override
    {
        _s.handleInboundMessage(msgType_, srcChainId_, data_);
    }

    /// @dev Pre-call ASSET snapshot for the non-worsening floor (IL-8640).
    function _beforeRescueExecuted() internal view override returns (uint256) {
        return IERC20(ASSET).balanceOf(address(this));
    }

    /// @notice Enforce the tracked-ledger invariant after a generic rescue (invariant #12).
    /// @dev Rescue may take untracked surplus ONLY; tracked value must stay funded.
    function _afterRescueExecuted(uint256 balanceBefore_) internal override {
        // Rescue may take untracked surplus only (invariant #12): tracked value must remain funded, and an
        // already-underfunded balance must not drop further (IL-8640).
        // Body in the linked library (EIP-170).
        StargateExecutorAccountingLib.checkRescueLedger(_s, ASSET, balanceBefore_, _decimalConversionRate);
    }

    // ============================================================
    // Resident internal helpers
    // ============================================================

    /// @dev Allocate a sequenced UPDATE_VAULTS command and send it (shared by manager + factory callback).
    function _sendUpdateVaults(uint256 chainId_, address[] memory vaults_) private {
        (bytes memory payload, bytes32 commandId, uint64 sequence) =
            _s.buildUpdateVaults(chainId_, vaults_, ++_commandNonce);
        _sendLzMessage(chainId_, payload, MSG_OPTION_TYPE, "");
        emit CommandSent(chainId_, commandId, sequence, UPDATE_VAULTS_COMMAND_ACTION);
    }

    /// @dev The `hasDispatcher` gate in one place: folded from the four sites that carried it inline
    ///      (`updatePlasmaVaults`, `sendCommandToDispatcher`, `proposeBalance`, `_validateTransferRequest`)
    ///      and reused by the two rescue schedule paths IL-8113 added (force-set, `ADVANCE_STATE_FRONTIER`) and
    ///      the `REALIGN_COMMAND_LANE` schedule (IL-8652). The fold is what paid for their bytes.
    ///      It is NOT a blanket gate on every chain-keyed entry point: several are keyed by their own state
    ///      instead (e.g. `retryCommand` / `cancelCommand` by the active-command slot), and the two `execute*`
    ///      rescue paths re-check the flag library-side rather than here.
    function _requireReady(uint256 chainId_) private view {
        if (!hasDispatcher[chainId_]) revert CrosschainErrors.DispatcherNotReady(chainId_);
    }

    function _validateTransferRequest(uint256 chainId_, uint256 amount_) private view {
        _requireReady(chainId_);
        if (amount_ == 0) revert CrosschainErrors.ZeroAmount();
        if (_toLD(_toSD(amount_)) != amount_) revert CrosschainErrors.AmountBelowSharedDecimals(amount_);
        if (_s.pendingTransferCount[chainId_] >= CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN) {
            revert CrosschainErrors.PendingTransfersCapReached(
                chainId_, CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN
            );
        }
    }

    /// @dev Reads `FACTORY` through one shared JUMP target instead of inlining the immutable (EIP-170).
    function _factory() private view returns (ICrosschainFactory) {
        return FACTORY;
    }

    /// @dev Reads `STALENESS_MAX` through one shared JUMP target instead of inlining the immutable (EIP-170).
    function _stalenessMax() private view returns (uint256) {
        return STALENESS_MAX;
    }

    /// @dev Approver check shared by its call sites (EIP-170).
    function _checkApprover() private view {
        if (msg.sender != BALANCE_APPROVER) revert CrosschainErrors.UnauthorizedApprover(msg.sender);
    }

    /// @dev Factory check shared by its call sites (EIP-170).
    function _checkFactory() private view {
        if (msg.sender != address(_factory())) revert CrosschainErrors.UnauthorizedFactory(msg.sender);
    }

    /// @dev Modifier body as one internal call instead of an inlined copy per use (EIP-170).
    function _checkManager() private view {
        if (msg.sender != MANAGER) revert CrosschainErrors.UnauthorizedManager(msg.sender);
    }
}
