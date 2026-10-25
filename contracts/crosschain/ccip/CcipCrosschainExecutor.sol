// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CcipAppBase} from "./base/CcipAppBase.sol";
import {CcipClient} from "./interfaces/CcipClient.sol";
import {CcipRouteConfig, ICcipCrosschainExecutor} from "./interfaces/ICcipCrosschain.sol";
import {CcipMessages, CcipMsgType} from "./lib/CcipMessages.sol";
import {Command} from "../lib/CrosschainMessages.sol";
import {CrosschainTransportKind} from "../common/CrosschainTransportTypes.sol";
import {ICrosschainExecutorMetadata} from "../common/ICrosschainExecutorMetadata.sol";
import {RescueModule} from "../lib/RescueModule.sol";
import {ICcipExecutorLibraryAbi} from "./ICcipExecutorLibraryAbi.sol";
import {CrosschainConstants, CommandStatus, CcipChainRescue} from "../lib/CrosschainConstants.sol";
import {CcipExecutorCommandLib, CcipExecutorCommandState, ReceiptIgnoreReason} from "./lib/CcipExecutorCommandLib.sol";
import {CcipExecutorAttestationLib, CcipAttestationState} from "./lib/CcipExecutorAttestationLib.sol";
import {CcipDecimalsLib} from "./lib/CcipDecimalsLib.sol";
import {CcipSendLib} from "./lib/CcipSendLib.sol";
import {CcipExecutorTransferLib, Outbound, PendingReturn, ReturnStatus} from "./lib/CcipExecutorTransferLib.sol";

contract CcipCrosschainExecutor is
    CcipAppBase,
    RescueModule,
    ICcipCrosschainExecutor,
    ICrosschainExecutorMetadata,
    ICcipExecutorLibraryAbi
{
    using CcipExecutorCommandLib for CcipExecutorCommandState;
    using CcipExecutorAttestationLib for CcipAttestationState;

    error TooManyVaults(uint256 supplied, uint256 maximum);
    error InvalidVaultAddress(address vault);
    error DuplicateVault(address vault);

    struct SafetyConfig {
        address rescueAdmin;
        address rescueGuardian;
        /// Nonzero and distinct from `balanceApprover`, enforced at construction.
        address balanceProposer;
        /// Nonzero and distinct from `balanceProposer`, enforced at construction.
        address balanceApprover;
        /// At least `MIN_RESCUE_DELAY`: `RescueModule` reverts `InvalidRescueDelay` below it.
        uint256 rescueDelay;
        /// Bounded to `[MIN_PROPOSAL_APPROVAL_WINDOW, MAX_STALENESS_WINDOW]` at construction (IL-8058).
        uint256 balanceStalenessMax;
        /// Bounded to `[1, ATTESTATION_ANCHOR_BAND_BPS]` at construction (IL-8058).
        uint256 bigChangeBps;
        /// Bounded to `[1, balanceStalenessMax)` at construction (IL-8058).
        uint256 minUpdateInterval;
        /// Bounded to `[1, MAX_STALENESS_WINDOW]` at construction (IL-8058).
        uint256 transferStalenessMax;
    }

    error InvalidDecimals(uint8 localDecimals, uint8 sharedDecimals);
    /// @notice `localDecimals - sharedDecimals` exceeds 18 (conversion rate would exceed 1e18).
    error DecimalsGapTooLarge(uint8 localDecimals, uint8 sharedDecimals);
    error OnlyManager();
    /// @notice A `BALANCE_REQUEST` to `chainId` is still awaiting its report (sent at `requestedAt`).
    error BalanceRequestOutstanding(uint256 chainId, uint64 requestedAt);
    /// @notice The previous `BALANCE_REQUEST` to `chainId` is younger than `BALANCE_REQUEST_COOLDOWN`.
    error BalanceRequestCooldown(uint256 chainId, uint256 nextAllowedAt);
    error OnlyFactory();
    error DispatcherNotReady(uint256 chainId);
    error InvalidAmount();
    error InsufficientFreshFunds(uint256 balance, uint256 tracked, uint256 requested);
    error ActiveReturnExists(uint256 chainId, bytes32 operationId);
    error ZeroAccountedReturn(uint256 chainId);
    error InvalidMinimumReturn(uint256 minimum, uint256 maximum);
    error InvalidMinDelivered(uint256 minDelivered, uint256 amount);
    error NoActiveReturn(uint256 chainId);
    error ReturnNotStale(uint256 chainId, uint256 createdAt);
    error AssetCannotPayCcipFees();
    error OnlyBalanceProposer();
    error OnlyBalanceApprover();
    error InvalidSafetyConfig();
    /// @notice Thrown when a generic rescue leaves ASSET below the idle ledger (non-worsening floor, IL-8640).
    /// @param balance The post-call ASSET balance of the executor.
    /// @param required min(pre-rescue ASSET balance, tracked ledger in LD).
    error UnbackedIdleCredit(uint256 balance, uint256 required);
    error InvalidFrontierAdvance(uint64 current, uint64 proposed);
    /// @dev `REALIGN_COMMAND_LANE` argument in the pre-IL-8586 shape: no expected epoch packed in the upper bits.
    error RealignExpectedEpochZero(uint256 chainId);
    /// @notice Thrown when `executeChainRescue` is handed a `CcipChainRescue` member it has no branch for.
    error UnknownChainRescue(uint8 kind);
    /// @notice Thrown when a `FORCE_SET_SETTLED` balance was observed at a dispatcher state version other than
    ///         the acknowledged frontier (IL-8294). Raised by `CcipExecutorAttestationLib`; declared here so the
    ///         executor's ABI decodes it.
    error ForceSetStateVersionMismatch(uint256 chainId, uint64 acknowledged, uint64 observed);
    /// @notice Thrown by `approveBalance` when the observation's remaining freshness is shorter than
    ///         `minUpdateInterval` (IL-8631). Raised by `CcipExecutorAttestationLib`; declared here for the ABI.
    error ObservationTooCloseToStale(uint256 chainId, uint64 remoteTimestamp);
    /// @notice Thrown by `approveBalance` when the observation is older than the last approved one (IL-8648).
    ///         Raised by `CcipExecutorAttestationLib`; declared here for the ABI.
    error ObservationOlderThanApproved(uint256 chainId, uint64 remoteTimestamp, uint64 lastApprovedObservedAt);
    /// @notice Thrown by `executeChainRescue` for a strict `FORCE_SET_SETTLED` whose committed observation time is
    ///         older than the last approved one (IL-8648 R1). Raised by `CcipExecutorAttestationLib`; declared
    ///         here for the ABI.
    error ForceSetOlderThanApproved(uint256 chainId, uint64 committedObservedAt, uint64 lastApprovedObservedAt);
    /// @notice Thrown when a dispatcher response arrives ahead of the next expected state version (IL-8496). The
    ///         OffRamp then records the message as FAILURE; re-execute it once the missing version has landed.
    ///         Raised by `CcipExecutorCommandLib`; declared here so the executor's ABI decodes it.
    error StateVersionGap(uint256 chainId, uint64 expected, uint64 got);

    address public immutable MANAGER;
    address public immutable ASSET;
    bytes32 public immutable ASSET_ID;
    address public immutable FACTORY;
    uint256 public immutable TRANSFER_STALENESS_MAX;
    address public immutable BALANCE_PROPOSER;
    address public immutable BALANCE_APPROVER;
    uint256 public immutable BALANCE_STALENESS_MAX;
    uint256 public immutable BIG_CHANGE_BPS;
    uint256 public immutable MIN_UPDATE_INTERVAL;
    uint8 public immutable LOCAL_DECIMALS;
    uint8 public immutable SHARED_DECIMALS;
    uint256 public immutable DECIMAL_CONVERSION_RATE;

    /// @notice Tokens held by the executor that the manager can still send or claim, in SHARED decimals. Not
    ///         local asset decimals: on a pair with `LOCAL_DECIMALS > SHARED_DECIMALS` this is
    ///         `DECIMAL_CONVERSION_RATE` times smaller than the token balance it stands for. `getBalance()` returns
    ///         the converted total.
    uint256 public idleLedger;
    /// @notice Value the executor books as placed on and held by the remote dispatcher of a chain, in SHARED
    ///         decimals. Moved by settled transfers, recalls, attested balances and rescues.
    mapping(uint256 => uint256) public settledRemoteBalance;
    /// @notice Tokens sent to a chain's dispatcher whose settlement has not arrived yet, in SHARED decimals.
    mapping(uint256 => uint256) public outboundInFlight;
    /// @notice True once the factory has acknowledged that the chain's dispatcher is deployed and ready.
    mapping(uint256 => bool) public hasDispatcher;
    mapping(bytes32 => Outbound) private outboundTransfers;
    mapping(bytes32 => PendingReturn) private pendingReturns;
    /// @notice Operation id of the chain's recall (return) in flight, or zero when there is none.
    mapping(uint256 => bytes32) public activeReturn;
    /// @notice Oldest `createdAt` among the chain's pending outbound transfers, or zero when
    ///         none is pending. Anchor of the `TRANSFER_STALENESS_MAX` gate.
    mapping(uint256 => uint64) public oldestPendingAt;
    mapping(uint256 => uint64[16]) private _pendingCreatedAt;
    /// @notice Number of the chain's pending outbound transfers (at most 16).
    mapping(uint256 => uint8) public pendingTransferCount;
    /// @notice The chain's acknowledged remote state version: the dispatcher `stateVersion` up to which every
    ///         value-moving response has been applied (or skipped by an `ADVANCE_FRONTIER` rescue).
    mapping(uint256 => uint64) public lastRemoteStateVersion;
    CcipExecutorCommandState private _commandState;
    /// @notice Chains whose dispatcher is ready, in the order they became ready; `getBalance()` sums over them.
    uint256[] public dispatcherChainIds;
    uint256 private _nonce;
    /// @notice True while the chain is blocked: raised by `rejectBalanceAndBlock` and by an `ADVANCE_FRONTIER`
    ///         repair; lifted by either `FORCE_SET_SETTLED` kind, or by the approval that consumes an
    ///         `ADVANCE_FRONTIER` repair latch (`frontierRepairPending`). A block raised by `rejectBalanceAndBlock`
    ///         is lifted only by a force-set. A blocked chain refuses new recalls (`requestAssetsFromDispatcher`),
    ///         not sends. `getBalance()` reverts `ChainBlocked` for it while its settled plus outbound total is
    ///         non-zero, so a send to an empty blocked chain makes NAV revert.
    mapping(uint256 => bool) public chainBlocked;
    /// @dev Belongs to the block `ADVANCE_FRONTIER` armed it with: consumed by the approval or force-set
    ///      that lifts that block, discarded by every other site that raises `chainBlocked` (reject). A
    ///      version gap raises no block since IL-8496. Any new block-raising path must do the same.
    mapping(uint256 => bool) public frontierRepairPending;
    CcipAttestationState private _attestationState;
    /// @notice Timestamp of the last `requestRemoteBalance` sent to a chain (IL-8579). Never cleared: it anchors
    ///         `BALANCE_REQUEST_COOLDOWN`.
    mapping(uint256 => uint64) public lastBalanceRequestAt;
    /// @notice True while a `BALANCE_REQUEST` to a chain awaits its `BALANCE_REPORT` (IL-8579). Cleared when a
    ///         report from that chain is handled; a request older than `BALANCE_STALENESS_MAX` no longer blocks.
    mapping(uint256 => bool) public balanceRequestOutstanding;
    /// @notice Number of the chain's cancelled recalls not yet resolved by a late `RETURN_TRANSFER` or a
    ///         `RETURN_REJECTED` (IL-8590). `FORCE_SET_SETTLED` and `ADVANCE_FRONTIER` reset it only past the reset
    ///         guard's `refusedUntil` (`_resetCancelledRecall`); before it the force-set reverts and the advance
    ///         keeps the clock. A new recall may open meanwhile.
    mapping(uint256 => uint32) public cancelledRecallCount;
    /// @notice Oldest `createdAt` among those recalls: the staleness anchor `balanceByChain` keeps enforcing
    ///         while the count is nonzero (IL-8590). It is not re-anchored when only some of them resolve.
    mapping(uint256 => uint64) public cancelledRecallPendingAt;
    /// @notice Per-chain reset generation of the cancelled-recall clock, bumped whenever `FORCE_SET_SETTLED` or
    ///         `ADVANCE_FRONTIER` resets that clock (IL-8590). An answer to a recall cancelled in an older generation
    ///         is ignored.
    mapping(uint256 => uint32) public cancelledRecallGeneration;
    /// @notice The `cancelledRecallGeneration` in force when a recall was cancelled.
    mapping(bytes32 => uint32) public cancelledRecallGenerationOf;
    /// @notice NEWEST `createdAt` among the chain's cancelled recalls (IL-8590). Meaningful only while
    ///         `cancelledRecallCount != 0`; it is never cleared (only one recall is active at a time, so a cancelled
    ///         `createdAt` never decreases, and the value is read only while the count is nonzero). The reset guard
    ///         waits for `latest + TRANSFER_STALENESS_MAX + RECALL_DEADLINE_SKEW_MARGIN`, i.e. until the deadline of
    ///         every such recall's `RETURN_REQUEST` has passed on the dispatcher.
    mapping(uint256 => uint64) public cancelledRecallLatestAt;

    event DispatcherReady(uint256 chainId);
    /// @notice Emitted by `claimAsset` with the amount sent to the MANAGER, in local asset decimals.
    /// @dev Mirrors the Stargate executor's event (same signature, so one topic0 covers both transports).
    event AssetClaimed(address manager, uint256 amount);
    /// @notice Emitted when `sendAssetToDispatcher` hands tokens to the transport.
    /// @param amount The sent amount in SHARED decimals (the booked amount; `AssetClaimed` is in local decimals).
    event AssetSent(uint256 chainId, bytes32 operationId, bytes32 messageId, uint256 amount);
    /// @notice Emitted when the dispatcher confirms an outbound transfer.
    /// @param received The amount credited to `settledRemoteBalance` in SHARED decimals, as booked (not the
    ///        amount sent; a shortfall is reported by `SettledCreditShortfall`).
    event AssetSettled(uint256 chainId, bytes32 operationId, uint256 received);
    /// @notice Emitted when a recall is sent to the dispatcher.
    /// @param amount NOT the requested amount: the accounted bound `maxAccounted = min(requestedSD, settled)` in
    ///        SHARED decimals, i.e. the request clamped to the chain's settled balance.
    event ReturnRequested(uint256 chainId, bytes32 operationId, uint256 amount);
    /// @notice A recall finished. `sentSD` is the amount the dispatcher declared, `received` the amount
    ///         credited to idle and `debitedSD` the amount actually debited from `settled` (equal to `sentSD`
    ///         unless the debit was clamped to `min(maxAccounted, settled)`, which also emits
    ///         `ReturnDebitExceededAccountingBound`); `sentSD - received` is the transport fee (IL-8497).
    event ReturnFinalized(uint256 chainId, bytes32 operationId, uint256 sentSD, uint256 received, uint256 debitedSD);
    event ReturnRejected(uint256 chainId, bytes32 operationId, uint8 reason);
    event ReturnCancelled(uint256 chainId, bytes32 operationId);
    /// @notice Same fields as `ReturnFinalized`, for a recall that is no longer the chain's active one.
    event LateReturnFinalized(
        uint256 chainId,
        bytes32 operationId,
        uint256 sentSD,
        uint256 received,
        uint256 debitedSD
    );
    event CommandFailed(uint256 chainId, bytes32 commandId, uint64 sequence);
    event CommandCancelRequested(uint256 chainId, bytes32 commandId);
    event RemoteBalanceUpdated(uint256 chainId, uint256 balance, uint64 stateVersion);
    event StaleRemoteBalanceIgnored(uint256 chainId, uint64 currentVersion, uint64 receivedVersion);
    /// @notice A remote-balance proposal was recorded. `balance` is in shared decimals, floored from the
    ///         proposer's local-decimals input (same units as `BalanceApproved` and the stored proposal).
    event BalanceProposed(
        uint256 proposalId,
        uint256 chainId,
        uint256 balance,
        uint64 stateVersion,
        bytes32 trackedPositionSetHash
    );
    event BalanceApproved(uint256 proposalId, uint256 chainId, uint256 balance);
    event BalanceRejectedAndBlocked(uint256 proposalId, uint256 chainId);
    /// @notice An approval lifted the fail-closed chain block raised by the `ADVANCE_FRONTIER` rescue (the
    ///         frontier-repair latch). Emitted in the same transaction as `BalanceApproved`.
    event ChainUnblockedByApproval(uint256 chainId, uint256 proposalId);
    event OutboundForceResolved(bytes32 operationId, uint256 chainId, bool creditedToSettled);
    event StateFrontierAdvanced(uint256 chainId, uint64 oldVersion, uint64 newVersion);
    event InboundMessageIgnored(uint256 chainId, uint8 messageType, bytes32 reason);
    event CommandReceiptIgnored(uint256 chainId, bytes32 commandId, uint8 messageType, uint8 reason);
    event ReturnBelowMinimumCredited(uint256 chainId, bytes32 operationId, uint256 received, uint256 minimum);
    /// @notice `FORCE_SET_SETTLED` overwrote the settled balance (shared decimals). Emitted by
    ///         `CcipExecutorAttestationLib`; declared here so the executor's ABI decodes it.
    event SettledBalanceForceSet(uint256 chainId, uint256 newSettled);

    modifier onlyManager() {
        _checkManager();
        _;
    }

    modifier onlyFactory() {
        _checkFactory();
        _;
    }

    constructor(
        address router_,
        address factory_,
        address manager_,
        address asset_,
        bytes32 assetId_,
        uint8 sharedDecimals_,
        SafetyConfig memory safety_
    ) CcipAppBase(router_) RescueModule(safety_.rescueAdmin, safety_.rescueGuardian, safety_.rescueDelay) {
        if (factory_ == address(0) || manager_ == address(0) || asset_ == address(0)) {
            revert CcipZeroAddress();
        }
        FACTORY = factory_;
        MANAGER = manager_;
        ASSET = asset_;
        ASSET_ID = assetId_;
        uint8 localDecimals = IERC20Metadata(asset_).decimals();
        if (sharedDecimals_ > localDecimals) revert InvalidDecimals(localDecimals, sharedDecimals_);
        if (localDecimals - sharedDecimals_ > 18) revert DecimalsGapTooLarge(localDecimals, sharedDecimals_);
        LOCAL_DECIMALS = localDecimals;
        SHARED_DECIMALS = sharedDecimals_;
        DECIMAL_CONVERSION_RATE = 10 ** (localDecimals - sharedDecimals_);
        if (
            safety_.balanceProposer == address(0) ||
            safety_.balanceApprover == address(0) ||
            safety_.balanceProposer == safety_.balanceApprover ||
            safety_.balanceStalenessMax == 0 ||
            safety_.transferStalenessMax == 0 ||
            safety_.balanceStalenessMax < CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW
        ) revert InvalidSafetyConfig();
        // Boundary sanity (IL-8058; mirror of IL-8049 on the Stargate executor). Every value below is
        // immutable on a non-upgradeable, factory-deployed contract, so a legal-but-degenerate value can never
        // be corrected. The relative big-change step must be nonzero — at zero only zero-delta approvals pass,
        // and those still refresh `lastApprovedObservedAt`, so NAV reads fresh while pinned — and must not
        // exceed the anchor band: `CcipExecutorAttestationLib.approve` applies the relative gate
        // (`BigChangeExceeded`) before the band (`AttestationOutsideAnchorBand`). For a step from the anchor
        // (`settled == anchorPrincipal`) the band is the tighter of the two, so a `bigChangeBps` above it adds
        // no rejection the band does not already make, while still being the revert that fires (as
        // `BigChangeExceeded`) once the step exceeds `bigChangeBps` itself. Away from the anchor the two gates
        // measure against different bases (`settled` vs `anchorPrincipal`) and neither rejection set contains
        // the other, so raising `bigChangeBps` past the band cannot tighten the from-anchor case and only widens
        // what the relative gate admits elsewhere. Capping it at the band keeps the two bounds ordered on every
        // path.
        if (safety_.bigChangeBps == 0 || safety_.bigChangeBps > CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS) {
            revert InvalidSafetyConfig();
        }
        // Windows above the ceiling make the fail-closed staleness gates in
        // `CcipExecutorTransferLib.balanceByChain` and the permissionless `cancelStalePendingReturn` unreachable.
        if (
            safety_.balanceStalenessMax > CrosschainConstants.MAX_STALENESS_WINDOW ||
            safety_.transferStalenessMax > CrosschainConstants.MAX_STALENESS_WINDOW
        ) revert InvalidSafetyConfig();
        // A zero cadence interval lets the attester pair approve repeatedly inside one transaction. An interval
        // at or above the freshness window collides the cadence gate (`<` against `lastApprovalAt`) with the
        // freshness gate (`>` against `lastApprovedObservedAt`): strictly above it, every pair of approvals on
        // a non-zero bucket is separated by an `ObservationStale` gap; exactly at it, the next approval lands
        // inside the window only when the observation timestamp equals the approval block timestamp. The value
        // is immutable, so the endpoint is rejected too.
        if (safety_.minUpdateInterval == 0 || safety_.minUpdateInterval >= safety_.balanceStalenessMax) {
            revert InvalidSafetyConfig();
        }
        BALANCE_PROPOSER = safety_.balanceProposer;
        BALANCE_APPROVER = safety_.balanceApprover;
        BALANCE_STALENESS_MAX = safety_.balanceStalenessMax;
        BIG_CHANGE_BPS = safety_.bigChangeBps;
        MIN_UPDATE_INTERVAL = safety_.minUpdateInterval;
        TRANSFER_STALENESS_MAX = safety_.transferStalenessMax;
    }

    /// @notice The transport this executor uses: always `CHAINLINK_CCIP`.
    function transportKind() external pure returns (CrosschainTransportKind) {
        return CrosschainTransportKind.CHAINLINK_CCIP;
    }

    /// @notice Revision of this executor's external interface, `7` for this release. Off-chain tooling and
    ///         integrators read it to tell which executor surface they are talking to (`ICrosschainExecutorMetadata`;
    ///         the Stargate executor does not implement it). It is a constant: nothing in the contract reads it.
    function executorInterfaceVersion() external pure returns (uint32) {
        return 7;
    }

    /// @notice Registers the CCIP route to `chainId_` (factory only). The fee token must not be the vault asset.
    function registerRoute(uint256 chainId_, CcipRouteConfig calldata route_) external onlyFactory {
        if (route_.feeToken == _asset()) revert AssetCannotPayCcipFees();
        _registerCcipRoute(chainId_, route_);
    }

    /// @notice Updates the route's fee token, gas limits and flags, and maximum fee (factory only). The fee
    ///         token must not be the vault asset.
    function syncRoutePolicy(
        uint256 chainId_,
        address feeToken_,
        uint256 gasLimitsAndFlags_,
        uint256 maxFee_
    ) external onlyFactory {
        if (feeToken_ == _asset()) revert AssetCannotPayCcipFees();
        _updateCcipRoutePolicy(chainId_, feeToken_, gasLimitsAndFlags_, maxFee_);
    }

    /// @notice Marks the chain's dispatcher ready once the factory has configured its allowlist (factory only).
    function markDispatcherReady(uint256 chainId_) external onlyFactory {
        // Factory configures the initial allowlist before acknowledging readiness. Body (chain list, ready flag,
        // command-lane epoch, `DispatcherReady`) lives in the linked library for EIP-170 headroom.
        _commandState.markDispatcherReady(hasDispatcher, dispatcherChainIds, chainId_);
    }

    /// @notice Whether the chain's dispatcher has been marked ready (`hasDispatcher`).
    function isDispatcherReady(uint256 chainId_) external view returns (bool) {
        return hasDispatcher[chainId_];
    }

    /// @notice Send `amount_` to the destination dispatcher with no delivered-amount floor.
    /// @param gasLimit_ Destination gas limit: 0 = route policy; above policy is clamped; below policy reverts.
    function sendAssetToDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external onlyManager returns (bytes32 messageId) {
        return _sendAssetToDispatcher(dstChainId_, amount_, maxFee_, feeToken_, gasLimit_, 0);
    }

    /// @notice Send `amount_` to the destination dispatcher and record a delivered-amount floor (IL-8581).
    /// @dev A CCIP token pool may charge a fee or apply a haircut, so the destination can receive less than
    ///      `amount_`. At settlement `SettledCreditShortfall` reports any shortfall and `SettledBelowMinDelivered`
    ///      reports a miss of `minDelivered_`; the credit that arrived is booked either way and the chain is NOT
    ///      blocked. The pool owner is a trusted external party: the floor is observability, not protection.
    /// @param gasLimit_ Destination gas limit: 0 = route policy; above policy is clamped; below policy reverts.
    /// @param minDelivered_ Floor on the tokens the destination must receive, local asset decimals, at most
    ///        `amount_`; 0 = no floor.
    function sendAssetToDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_,
        uint256 minDelivered_
    ) external onlyManager returns (bytes32 messageId) {
        return _sendAssetToDispatcher(dstChainId_, amount_, maxFee_, feeToken_, gasLimit_, minDelivered_);
    }

    function _sendAssetToDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_,
        uint256 minDelivered_
    ) private returns (bytes32 messageId) {
        _requireReady(dstChainId_);
        if (amount_ == 0) revert InvalidAmount();
        if (minDelivered_ > amount_) revert InvalidMinDelivered(minDelivered_, amount_);
        uint256 amountSD = _toSDExact(amount_);
        uint256 tracked = idleLedger;
        uint256 balance = IERC20(_asset()).balanceOf(address(this));
        uint256 trackedLD = _toLD(tracked);
        if (balance < trackedLD + amount_) revert InsufficientFreshFunds(balance, trackedLD, amount_);
        bytes32 operationId = keccak256(abi.encode(address(this), dstChainId_, ++_nonce));
        uint8 slot = _armStaleness(dstChainId_);
        outboundTransfers[operationId] = Outbound({
            chainId: dstChainId_,
            amount: amountSD,
            createdAt: uint64(block.timestamp),
            settled: false,
            forceResolved: false,
            remoteCreditAccounted: false,
            stalenessSlot: slot,
            resolveRepairSeq: 0,
            minDeliveredSD: _toSDExact(minDelivered_)
        });
        outboundInFlight[dstChainId_] += amountSD;
        (messageId, ) = _sendCcip(
            dstChainId_,
            CcipMessages.encode(CcipMsgType.OUTBOUND_TRANSFER, abi.encode(operationId)),
            _asset(),
            amount_,
            maxFee_,
            feeToken_,
            gasLimit_
        );
        emit AssetSent(dstChainId_, operationId, messageId, amountSD);
    }

    /// @param gasLimit_ Destination gas limit: 0 = route policy; above policy is clamped; below policy reverts.
    /// @param minReturn_ Enforced by the dispatcher on the GROSS amount it sends, before any CCIP token-pool fee
    ///        on the return leg; the net tokens received can be lower. `ReturnFinalized` carries `sentSD` and
    ///        `received`, so the pool fee is `sentSD - received` (shared decimals), already booked as a NAV loss.
    function requestAssetsFromDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 minReturn_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external onlyManager returns (bytes32 messageId) {
        _requireReady(dstChainId_);
        // A blocked chain's exit is the timelocked FORCE_SET_SETTLED rescue, which refuses to run while a
        // recall is active. Opening one here would let the manager hold that exit shut (IL-8292).
        if (chainBlocked[dstChainId_]) revert CcipExecutorTransferLib.ChainBlocked(dstChainId_);
        if (amount_ == 0) revert InvalidAmount();
        uint256 requestedSD = _toSDExact(amount_);
        uint256 minReturnSD = _toSDExact(minReturn_);
        bytes32 operationId = keccak256(abi.encode(address(this), dstChainId_, "RETURN", _nonce + 1));
        // One active recall per chain, bounded by `settled`; body in the linked library for EIP-170 headroom. The
        // nonce is stored only once those checks have passed, so a refused request pays no nonce write.
        uint256 maxAccounted = CcipExecutorTransferLib.openReturn(
            activeReturn,
            pendingReturns,
            settledRemoteBalance,
            dstChainId_,
            operationId,
            requestedSD,
            minReturnSD
        );
        ++_nonce;
        // The fifth word is the request deadline: the instant the recall turns stale (`createdAt +
        // TRANSFER_STALENESS_MAX`, never zero, see the constructor). The dispatcher rejects a later execution with
        // `EXPIRED`, so a request stuck on the OffRamp cannot move value after `cancelStalePendingReturn` and a
        // reset have made the executor forget the recall (IL-8590).
        (messageId, ) = _sendCcip(
            dstChainId_,
            CcipMessages.encode(
                CcipMsgType.RETURN_REQUEST,
                abi.encode(
                    operationId,
                    requestedSD,
                    maxAccounted,
                    minReturnSD,
                    block.timestamp + _transferStalenessMax()
                )
            ),
            address(0),
            0,
            maxFee_,
            feeToken_,
            gasLimit_
        );
        emit ReturnRequested(dstChainId_, operationId, maxAccounted);
    }

    /// @notice Locally cancel an uncompleted recall. CCIP 2.0 delivery is unordered and permissionless
    ///         (IL-8496), so the dispatcher may already have debited and dispatched the `RETURN_TRANSFER`. The
    ///         terminal tombstone keeps a later authenticated return creditable, and the recall's staleness
    ///         clock is carried in `cancelledRecallPendingAt` so NAV stays fail-closed until that return, a
    ///         rejection, `FORCE_SET_SETTLED` or `ADVANCE_FRONTIER` resolves it (IL-8590). Cancel only while the
    ///         return is still visible in the dispatcher's `queuedResponse`. Refuses with `CancelledRecallCapReached`
    ///         while `MAX_CANCELLED_RECALLS_PER_CHAIN` cancelled recalls of the chain are unresolved; the
    ///         permissionless stale path is not capped (IL-8583).
    function cancelPendingReturn(uint256 chainId_) external onlyManager {
        _cancelReturn(chainId_, 0, false);
    }

    /// @notice Permissionless liveness escape once the same timeout that blocks NAV has elapsed.
    ///         It only frees the recall slot: cancellation changes no accounting, late authenticated token
    ///         delivery remains accepted, and NAV stays fail-closed until the cancelled recall resolves
    ///         (late return, rejection, `FORCE_SET_SETTLED` or `ADVANCE_FRONTIER`, IL-8590).
    function cancelStalePendingReturn(uint256 chainId_) external {
        _cancelReturn(chainId_, _transferStalenessMax(), true);
    }

    /// @param gasLimit_ Destination gas limit: 0 = route policy; above policy is clamped; below policy reverts.
    function sendCommandToDispatcher(
        uint256 dstChainId_,
        Command calldata command_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external onlyManager returns (bytes32 messageId) {
        _requireReady(dstChainId_);
        bytes memory normalized = CcipDecimalsLib.normalizeActionData(command_.action, command_.actionData, _rate());
        Command memory command = _buildCommand(
            CcipExecutorCommandLib.BuildParams({
                executor: address(this),
                chainId: dstChainId_,
                action: command_.action,
                actionData: normalized,
                advancesConfig: false,
                nonce: 0,
                laneGas: 0,
                extra: bytes(""),
                requestedBudget: command_.minExecutionGas
            }),
            gasLimit_
        );
        (messageId, ) = _sendCcip(
            dstChainId_,
            CcipMessages.encode(CcipMsgType.COMMAND, abi.encode(CcipMsgType.COMMAND, command, bytes(""))),
            address(0),
            0,
            maxFee_,
            feeToken_,
            gasLimit_
        );
    }

    /// @param replace_ When true the remote allowlist is REPLACED by `vaults_` (the Stargate
    ///        `UPDATE_VAULTS` semantics); when false the call adds or removes just the listed vaults.
    ///        Every vault that leaves the allowlist (removal or replacement) is swept on the dispatcher
    ///        (best-effort capped `redeem` of its whole position into idle; dust is skipped) and ALWAYS untracked
    ///        (IL-8784). A position the sweep could not redeem stays on the dispatcher OUTSIDE NAV until the
    ///        vault is allowlisted again, so ALPHA must redeem or recall it to zero BEFORE removing the vault. A
    ///        sweep `redeem` gets `min(VAULT_SWEEP_GAS, gasleft() - reserve)` and never reverts for
    ///        lack of gas (D-065); a CCIP RETRY cannot add gas, so a position needing more than the lane leaves ends
    ///        as a reported residual.
    /// @param gasLimit_ Destination gas limit: 0 = route policy; above policy is clamped; below policy reverts.
    function updateVaults(
        uint256 dstChainId_,
        address[] calldata vaults_,
        bool allowed_,
        bool replace_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external onlyManager returns (bytes32 messageId) {
        _requireReady(dstChainId_);
        // Shape validation lives in the linked library purely for EIP-170 headroom; the errors are still
        // declared here so the executor's ABI is unchanged.
        CcipExecutorCommandLib.validateVaultShape(vaults_);
        bytes memory extra = abi.encode(vaults_, allowed_, replace_);
        Command memory command = _buildCommand(
            CcipExecutorCommandLib.BuildParams({
                executor: address(this),
                chainId: dstChainId_,
                action: 0,
                actionData: "",
                advancesConfig: true,
                nonce: 0,
                laneGas: 0,
                extra: extra,
                requestedBudget: 0
            }),
            gasLimit_
        );
        (messageId, ) = _sendCcip(
            dstChainId_,
            CcipMessages.encode(CcipMsgType.UPDATE_VAULTS, abi.encode(CcipMsgType.UPDATE_VAULTS, command, extra)),
            address(0),
            0,
            maxFee_,
            feeToken_,
            gasLimit_
        );
    }

    /// @param gasLimit_ Destination gas limit: 0 = route policy; above policy is clamped; below policy reverts.
    function retryCommand(
        uint256 dstChainId_,
        bytes32 commandId_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external onlyManager returns (bytes32 messageId) {
        _commandState.requireFailed(dstChainId_, commandId_, false);
        // IL-8625: the retry re-runs the stored budget, so its delivery gas must still cover it.
        // Then re-arm to PENDING so a retry that fails again yields a NACK the executor can apply
        // instead of a duplicate that used to revert and brick the response lane (audit C-1).
        _commandState.requireRetryGasAndMarkRetrying(
            _commandPayloadWords,
            commandId_,
            CcipSendLib.commandGasLimit(_ccipRoutes, dstChainId_, gasLimit_)
        );
        (messageId, ) = _sendCcip(
            dstChainId_,
            CcipMessages.encode(CcipMsgType.RETRY_COMMAND, abi.encode(commandId_)),
            address(0),
            0,
            maxFee_,
            feeToken_,
            gasLimit_
        );
    }

    /// @dev A repeat for the same command reverts `CancelCooldown` within `CANCEL_COMMAND_COOLDOWN` (IL-8579).
    /// @param gasLimit_ Destination gas limit: 0 = route policy; above policy is clamped; below policy reverts.
    function cancelCommand(
        uint256 dstChainId_,
        bytes32 commandId_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external onlyManager returns (bytes32 messageId) {
        _commandState.requireFailed(dstChainId_, commandId_, true);
        (messageId, ) = _sendCcip(
            dstChainId_,
            CcipMessages.encode(CcipMsgType.CANCEL_COMMAND, abi.encode(commandId_)),
            address(0),
            0,
            maxFee_,
            feeToken_,
            gasLimit_
        );
        emit CommandCancelRequested(dstChainId_, commandId_);
    }

    function commandStatus(bytes32 id_) external view returns (CommandStatus) {
        return _commandState.status[id_];
    }

    function activeCommand(uint256 chainId_) external view returns (bytes32) {
        return _commandState.active[chainId_];
    }

    /// @notice Business action stored with command `id_` (0 for an unknown id or a config update).
    /// @dev Read by `CcipCrosschainCommandFuse` to gate `RETRY_COMMAND` like a fresh send of the stored action; a
    ///      stored config update (0) is refused on a blocked chain like a vault-adding `UPDATE_VAULTS`, but its list
    ///      is not stored, so its substrates are not re-checked (IL-8600).
    function commandAction(bytes32 id_) external view returns (uint8) {
        return _commandState.commands[id_].action;
    }

    /// @notice Target vault of the DEPOSIT stored as command `id_` (0 for any other action or an unknown id).
    /// @dev Read by `CcipCrosschainCommandFuse` to re-check a retried DEPOSIT's target against the REMOTE_VAULT
    ///      substrates (IL-8600 follow-up). Decoded in the linked library for EIP-170 headroom: returning the stored
    ///      `actionData` from here would push this executor over the limit.
    function commandDepositTarget(bytes32 id_) external view returns (address) {
        return _commandState.depositTarget(id_);
    }

    function nextCommandSequence(uint256 chainId_) external view returns (uint64) {
        return _commandState.nextCommandSequence[chainId_];
    }

    function commandConfigEpoch(uint256 chainId_) external view returns (uint64) {
        return _commandState.commandConfigEpoch[chainId_];
    }

    /// @dev IL-8625: the command's gas budget is derived from the SAME effective gas limit `CcipSendLib.send` then
    ///      sends with (route policy, resolved by `commandGasLimit`) and from the stored payload size: see
    ///      `CrosschainMessages.commandGasBudget`. Refused below `COMMAND_EXECUTION_MIN_GAS` (`CommandLaneGasTooLow`)
    ///      and above `MAX_COMMAND_EXECUTION_GAS` (`CommandBudgetAboveMax`). A manager-supplied
    ///      `p_.requestedBudget` (`Command.minExecutionGas`) is checked against it, never stamped.
    function _buildCommand(
        CcipExecutorCommandLib.BuildParams memory p_,
        uint256 gasLimit_
    ) private returns (Command memory command_) {
        p_.nonce = ++_nonce;
        p_.laneGas = CcipSendLib.commandGasLimit(_ccipRoutes, p_.chainId, gasLimit_);
        command_ = _commandState.build(_commandPayloadWords, p_);
    }

    /// @notice Ask the dispatcher on `dstChainId_` for a `BALANCE_REPORT`.
    /// @dev Metered per destination chain (IL-8579) because every call costs a CCIP fee here and queues one
    ///      response in the dispatcher's bounded FIFO: at most one request may be outstanding (cleared by any
    ///      BALANCE_REPORT from that chain, reports being evidence only; the flag expires after the executor's
    ///      immutable `BALANCE_STALENESS_MAX`, bounded by `MAX_STALENESS_WINDOW` = 7 days, so a lost report
    ///      cannot wedge the function; reverts `BalanceRequestOutstanding`) and two requests must be
    ///      `CrosschainConstants.BALANCE_REQUEST_COOLDOWN` (10 minutes) apart (reverts `BalanceRequestCooldown`).
    /// @param gasLimit_ Destination gas limit: 0 = route policy; above policy is clamped; below policy reverts.
    function requestRemoteBalance(
        uint256 dstChainId_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external onlyManager returns (bytes32 messageId) {
        _requireReady(dstChainId_);
        CcipExecutorCommandLib.meterBalanceRequest(
            lastBalanceRequestAt,
            balanceRequestOutstanding,
            dstChainId_,
            _balanceStalenessMax()
        );
        (messageId, ) = _sendCcip(
            dstChainId_,
            CcipMessages.encode(CcipMsgType.BALANCE_REQUEST, ""),
            address(0),
            0,
            maxFee_,
            feeToken_,
            gasLimit_
        );
    }

    function claimAsset(uint256 amount_) external onlyManager nonReentrant {
        // Claim is a "give me up to X" recovery primitive: floor like the Stargate executor does
        // instead of reverting on dust the caller cannot control (audit L-1/consistency).
        uint256 requestedSD = amount_ == type(uint256).max ? type(uint256).max : _toSDFloor(amount_);
        uint256 claimSD = requestedSD > idleLedger ? idleLedger : requestedSD;
        idleLedger -= claimSD;
        CcipExecutorTransferLib.payOut(_asset(), MANAGER, _toLD(claimSD));
    }

    /// @param balance_ The observed remote balance in LOCAL decimals of the executor's asset; it is floored to
    ///        shared decimals before it is recorded (`BalanceProposed` reports the floored value). The dispatcher's
    ///        `observation().accountedBalance` is in SHARED decimals: multiply it by this executor's
    ///        `DECIMAL_CONVERSION_RATE` (read it on the executor chain; the dispatcher's getter of the same name
    ///        differs when the two chains' local decimals differ) before proposing it.
    /// @param trackedPositionSetHash_ The remote dispatcher's `trackedPositionSetHash()` at observation
    ///        time. Persisted and emitted so the approver — a role distinct from the proposer — has an
    ///        on-chain handle for the position set the number was read against, exactly as the Stargate
    ///        executor does. Not checkable on-chain (the set lives on the remote chain), so it is an
    ///        off-chain verification commitment, never an authority (audit M-1).
    function proposeBalance(
        uint256 chainId_,
        uint256 balance_,
        uint64 stateVersion_,
        uint64 remoteBlock_,
        uint64 remoteTimestamp_,
        uint64 expiry_,
        bytes32 trackedPositionSetHash_
    ) external returns (uint256 proposalId) {
        if (msg.sender != BALANCE_PROPOSER) revert OnlyBalanceProposer();
        _requireReady(chainId_);
        // An observed remote balance is an EXTERNAL value and routinely carries sub-precision dust;
        // flooring keeps it proposable at all (audit C-2).
        uint256 balanceSD = _toSDFloor(balance_);
        proposalId = _attestationState.propose(
            lastRemoteStateVersion,
            _balanceStalenessMax(),
            chainId_,
            balanceSD,
            stateVersion_,
            remoteBlock_,
            remoteTimestamp_,
            expiry_,
            trackedPositionSetHash_
        );
        emit BalanceProposed(proposalId, chainId_, balanceSD, stateVersion_, trackedPositionSetHash_);
    }

    function approveBalance(uint256 proposalId_) external {
        _checkApprover();
        _attestationState.approveWithRepair(
            lastRemoteStateVersion,
            settledRemoteBalance,
            frontierRepairPending,
            chainBlocked,
            outboundInFlight,
            proposalId_,
            _balanceStalenessMax(),
            BIG_CHANGE_BPS,
            MIN_UPDATE_INTERVAL
        );
    }

    function rejectBalanceAndBlock(uint256 proposalId_) external {
        _checkApprover();
        // Body (block the chain, discard the frontier-repair latch, `BalanceRejectedAndBlocked`) lives in the
        // linked library for EIP-170 headroom.
        _attestationState.rejectAndBlock(chainBlocked, frontierRepairPending, proposalId_);
    }

    function scheduleForceResolveOutbound(
        bytes32 operationId_,
        bool creditToSettled_
    ) external onlyRescueAdmin returns (uint256 rescueId) {
        Outbound storage transfer = outboundTransfers[operationId_];
        if (transfer.createdAt == 0 || transfer.settled) {
            revert CcipExecutorTransferLib.ForceResolveWrongState(operationId_);
        }
        rescueId = _scheduleForceResolve(_outboundCommitment(operationId_, creditToSettled_));
    }

    /// @notice Schedule a timelocked, chain-scoped rescue.
    /// @dev One tagged pair for every chain-scoped rescue, mirroring Stargate's `ResolveOutcome`-tagged
    ///      force-resolve. It absorbed the bespoke `scheduleAbandonCommand`/`executeAbandonCommand` and
    ///      `scheduleAdvanceStateFrontier`/`executeAdvanceStateFrontier` pairs when the settled-overwrite
    ///      rescue was added: a fourth near-identical schedule/execute pair put this executor 420 bytes
    ///      over EIP-170, and the consolidation is what bought the room back.
    ///
    ///      `ADVANCE_FRONTIER` keeps its own, shorter timelock (`_scheduleFrontierRepair`,
    ///      `FRONTIER_REPAIR_DELAY` rather than `RESCUE_DELAY`): it moves no value and leaves the chain blocked
    ///      until a fresh approved attestation (a block left by an earlier rejection still needs the force-set,
    ///      IL-8620), so a lost state version can be repaired sooner than the value-moving rescues allow.
    /// @dev Every kind is keyed by `chainId_`, so both `scheduleChainRescue` and `executeChainRescue` require
    ///      `hasDispatcher[chainId_]` (IL-8113). For `FORCE_SET_SETTLED` and `ADVANCE_FRONTIER` that is the
    ///      substance of the guard: without it, a rescue for a chain not yet in `dispatcherChainIds` pre-seeds
    ///      per-chain state that surfaces the moment that chain goes live. `ABANDON_COMMAND` writes nothing for
    ///      such a chain either way — `abandon` reverts `NoStuckCommand` on the empty slot — so there the guard
    ///      only brings the rejection forward to schedule time, before a `RESCUE_DELAY` has been spent.
    /// @param kind_ Which rescue to arm.
    /// @param chainId_ The chain the rescue targets.
    /// @param arg_ `ABANDON_COMMAND`: non-zero iff the dispatcher resolved the command and advanced its
    ///        sequence. `FORCE_SET_SETTLED` and `FORCE_SET_SETTLED_UNCHECKED` (same argument word, same schedule
    ///        checks; IL-8648 R1: the strict kind refuses at execute with `ForceSetOlderThanApproved` when an ordinary
    ///        approval with a NEWER observation than the committed one landed during the delay, the unchecked kind
    ///        may move the NAV freshness clock backwards on purpose; the kind is inside the commitment):
    ///        `(observedStateVersion << 192) | (observedRemoteTimestamp << 128) | newSettledLD` — the new settled
    ///        balance in local ASSET decimals in the low 128 bits (it must be a multiple of
    ///        the executor's `DECIMAL_CONVERSION_RATE`, else schedule reverts `AmountHasDust`, IL-9025: pack
    ///        `observation().accountedBalance * <executor>.DECIMAL_CONVERSION_RATE()`), in bits 128..191
    ///        the remote (dispatcher chain)
    ///        timestamp at which it was read (IL-8646 / TP-L-18: execute stamps it as the NAV freshness clock
    ///        instead of the execute time; schedule reverts `ObservationStale` unless
    ///        `block.timestamp - BALANCE_STALENESS_MAX <= timestamp <= block.timestamp` and non-zero; IL-8604 R1:
    ///        it must also be strictly later than `lastValueMovingReceiptAt(chainId_)`, else
    ///        `ObservationPredatesValueMovingReceipt`, as in attestation: a read taken while a `RETURN_TRANSFER`
    ///        was still queued shares the post-return version but counts its tokens. Checked at schedule only; a
    ///        value-moving response during the delay voids the rescue by version), and in the
    ///        upper 64 bits the dispatcher
    ///        `stateVersion` (`CcipCrosschainDispatcher.stateVersion`) at which that balance was read. Tooling
    ///        must assert `newSettledLD < 2^128` and `newSettledLD % DECIMAL_CONVERSION_RATE == 0`
    ///        (the executor's rate) before
    ///        packing: a larger balance would OR into the timestamp
    ///        bits and be truncated silently if it still passed the freshness check (unreachable in practice, the
    ///        dispatcher caps priced assets at uint128); guardians decode all three fields from the schedule
    ///        calldata. Execute
    ///        reverts `ForceSetStateVersionMismatch` unless the version then equals
    ///        `lastRemoteStateVersion(chainId_)`: wait for every queued dispatcher response to land and
    ///        reschedule, or repair a lost one with `ADVANCE_FRONTIER` first (IL-8294). Schedule already
    ///        rejects any version other than the current frontier: one below can never match, and one above
    ///        it would only match once a queued response lands during the delay, after the observation
    ///        already excluded that response's effect. Any versioned (value-moving:
    ///        `TRANSFER_SETTLED` / `RETURN_TRANSFER`) response that lands after the observation still voids
    ///        the rescue, including ones the manager can trigger (outbound transfers, recalls): pause the
    ///        vault for the rescue window. Value-neutral traffic (`requestRemoteBalance`, command traffic)
    ///        no longer bumps the version (IL-8257).
    ///        `ADVANCE_FRONTIER`: the new remote state version. `REALIGN_COMMAND_LANE`:
    ///        `(expectedEpoch << 192) | (expectedSequence << 128) | (newEpoch << 64) | newSequence`. The
    ///        expected pair is the executor's own `commandConfigEpoch` / `nextCommandSequence` mirrors that the
    ///        realign is armed against; execute reverts `RealignStateMoved` if they changed during the delay
    ///        (a late ACK), so the stale rescue cannot roll the lane back — reschedule from the new state. With an
    ///        `ABANDON_COMMAND` armed in the same batch, give the state after it (sequence + 1 if it declares
    ///        the sequence consumed). Schedule refuses an argument whose expected epoch is zero
    ///        (`RealignExpectedEpochZero`): the pre-IL-8586 shape, with the upper 128 bits unset, so off-chain
    ///        tooling must pack the expected pair. Neither the expected sequence nor the free-slot requirement
    ///        is checked here, so an `ABANDON_COMMAND` and a `REALIGN_COMMAND_LANE` can be scheduled in the same
    ///        block and executed back to back, and chained realigns may arm against a lower future state.
    /// @return rescueId The scheduled force-resolve id.
    function scheduleChainRescue(
        CcipChainRescue kind_,
        uint256 chainId_,
        uint256 arg_
    ) external onlyRescueAdmin returns (uint256 rescueId) {
        _requireReady(chainId_);
        if (kind_ == CcipChainRescue.FORCE_SET_SETTLED || kind_ == CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED) {
            // Schedule-time gates of the packed argument (frontier version, fresh observation time, after the
            // last value-moving receipt); body in the linked library for EIP-170 headroom.
            _attestationState.checkForceSetSchedule(
                lastRemoteStateVersion,
                chainId_,
                arg_,
                _balanceStalenessMax(),
                _rate()
            );
        }
        if (kind_ == CcipChainRescue.REALIGN_COMMAND_LANE && uint64(arg_ >> 192) == 0) {
            revert RealignExpectedEpochZero(chainId_);
        }
        bytes32 commitment = _chainRescueCommitment(kind_, chainId_, arg_);
        if (kind_ == CcipChainRescue.ADVANCE_FRONTIER) {
            _requireFrontierAdvance(chainId_, arg_);
            return _scheduleFrontierRepair(commitment);
        }
        rescueId = _scheduleForceResolve(commitment);
    }

    /// @dev A frontier advance must strictly move forward AND may skip at most `MAX_FRONTIER_JUMP`
    ///      versions; checked at both schedule and execute time so a version that landed during the
    ///      timelock cannot be silently overwritten.
    /// @dev The upper bound is not cosmetic. The write is irreversible (this frontier is monotonic in
    ///      every writer) and an overshoot makes `acceptRemoteStateVersion` discard every subsequent
    ///      genuine dispatcher response as stale — the anti-replay defence goes permanently inert and
    ///      `propose` is satisfiable forever with one frozen version, on a non-upgradeable contract
    ///      (audit `unbounded_one_way_frontier_advance_permanently_disables_version_check`). It also
    ///      closes the truncation hole below: without a bound, `arg_ = 2**64 + n` passes the
    ///      strictly-greater check as a `uint256` and then stores `uint64(arg_) == n`, silently moving the
    ///      frontier BACKWARDS. `current + MAX_FRONTIER_JUMP` cannot reach `type(uint64).max`, so every
    ///      accepted value now round-trips through the cast unchanged.
    /// @dev Undershoot has its own cost. A response carrying a version greater than `newVersion_ + 1` keeps
    ///      failing on the OffRamp (`StateVersionGap`, IL-8496), so the chain stays blocked until another
    ///      timelocked rescue — one more `FRONTIER_REPAIR_DELAY` with NAV fail-closed throughout. Size
    ///      `newVersion_` to the version just below the first response that can still be delivered, read
    ///      from the dispatcher's `stateVersion` and its response queue on the source chain, then re-execute
    ///      the responses that failed on the gap through `OffRamp.execute`.
    function _requireFrontierAdvance(uint256 chainId_, uint256 newVersion_) private view returns (uint64 current) {
        current = lastRemoteStateVersion[chainId_];
        if (newVersion_ <= current || newVersion_ > uint256(current) + CrosschainConstants.MAX_FRONTIER_JUMP) {
            revert InvalidFrontierAdvance(current, uint64(newVersion_));
        }
    }

    /// @dev A `bytes32` domain tag rather than a string literal: identical separation, fewer bytes on a
    ///      contract that sits close to the EIP-170 limit.
    function _chainRescueCommitment(
        CcipChainRescue kind_,
        uint256 chainId_,
        uint256 arg_
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(bytes32("CCIP_CHAIN_RESCUE"), kind_, chainId_, arg_));
    }

    /// @notice Execute a scheduled chain-scoped rescue after the rescue delay.
    /// @param rescueId_ The scheduled id.
    /// @param kind_ Which rescue to apply; must match what was scheduled.
    /// @param chainId_ The chain the rescue targets.
    /// @param arg_ As passed to `scheduleChainRescue`.
    function executeChainRescue(
        uint256 rescueId_,
        CcipChainRescue kind_,
        uint256 chainId_,
        uint256 arg_
    ) external onlyRescueAdmin {
        _requireReady(chainId_);
        _consumeForceResolve(rescueId_, _chainRescueCommitment(kind_, chainId_, arg_));
        if (kind_ == CcipChainRescue.ABANDON_COMMAND) {
            _commandState.abandon(chainId_, arg_ != 0);
            _bumpAccountingEpoch(chainId_);
        } else if (kind_ == CcipChainRescue.ADVANCE_FRONTIER) {
            uint64 current = _requireFrontierAdvance(chainId_, arg_);
            lastRemoteStateVersion[chainId_] = uint64(arg_);
            // IL-8620: arm the latch only when this repair owns the block (no block before, or only an earlier
            // repair's). A foreign block already standing must still need the timelocked force-set.
            frontierRepairPending[chainId_] = !chainBlocked[chainId_] || frontierRepairPending[chainId_];
            chainBlocked[chainId_] = true;
            // After a skip-valve drop the dropped return's tokens are back in the dispatcher's trackedIdle and
            // `settled` was never debited, so the cancelled-recall clock guards nothing. The chain is blocked and
            // the repair latch forces a fresh approved attestation at the new frontier before NAV reopens.
            // Any other cancelled recall still queued is covered by that attestation, since `accountedBalance`
            // counts queued returns.
            // Reset guard (IL-8590): the advance NEVER reverts on it (else the manager could postpone it forever
            // with recall -> cancel loops). While a cancelled recall's request may still be honoured the clock is
            // kept (count, anchors, generation unchanged); the frontier still advances, the chain stays blocked and
            // the latch armed. A kept clock is cleared later by the cancelled recalls' answers (an expired request
            // comes back EXPIRED in the same generation) or by FORCE_SET_SETTLED, whose guard is then bounded
            // because the blocked chain refuses new recalls. If the dropped answer never arrives (skip valve),
            // execute the advance after `refusedUntil` so it clears the clock; otherwise only FORCE_SET_SETTLED does.
            _resetCancelledRecall(chainId_, false);
            _bumpAccountingEpoch(chainId_);
            emit StateFrontierAdvanced(chainId_, current, uint64(arg_));
        } else if (kind_ == CcipChainRescue.REALIGN_COMMAND_LANE) {
            // Must come BEFORE the `else`: that branch is the settled-balance overwrite and would read a
            // packed realign argument as a balance (IL-7970).
            _commandState.realign(chainId_, arg_);
            _bumpAccountingEpoch(chainId_);
        } else if (kind_ != CcipChainRescue.FORCE_SET_SETTLED && kind_ != CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED) {
            // Exhaustive by construction: the five members of `CcipChainRescue` each have a branch, and
            // this one refuses anything else instead of falling through to the settled overwrite below.
            // A member added to the enum without a branch here would otherwise be executed as a
            // `forceSetSettled` with that kind's argument read as a balance (IL-7970).
            revert UnknownChainRescue(uint8(kind_));
        } else {
            // Settled overwrite: also lifts a NAV block and bumps the epoch. `arg_` packs the observed
            // dispatcher state version and the remote observation time above the balance (IL-8294, IL-8646). See
            // `CcipExecutorAttestationLib.forceSetSettled`.
            _attestationState.forceSetSettled(
                settledRemoteBalance,
                chainBlocked,
                frontierRepairPending,
                pendingTransferCount,
                activeReturn,
                lastRemoteStateVersion,
                chainId_,
                _toSDExact(uint128(arg_)),
                arg_,
                kind_ == CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED
            );
            // The overwrite supersedes the cancelled recall's value, so its clock goes too (IL-8590); strict guard.
            _resetCancelledRecall(chainId_, true);
        }
    }

    function executeForceResolveOutbound(
        uint256 rescueId_,
        bytes32 operationId_,
        bool creditToSettled_
    ) external onlyRescueAdmin {
        _consumeForceResolve(rescueId_, _outboundCommitment(operationId_, creditToSettled_));
        // The library also bumps the accounting epoch and emits `OutboundForceResolved` (EIP-170).
        CcipExecutorTransferLib.applyForceResolveOutbound(
            outboundTransfers,
            outboundInFlight,
            settledRemoteBalance,
            _pendingCreatedAt,
            pendingTransferCount,
            oldestPendingAt,
            _attestationState,
            operationId_,
            creditToSettled_
        );
    }

    /// @notice Total value this executor accounts for: idle tokens plus, for every ready chain, the settled and
    ///         in-flight balances, in LOCAL asset decimals.
    /// @dev Fail-closed per chain: reverts `ChainBlocked`, `TransferStale` or `ObservationStale` where a chain's
    ///      books cannot be trusted. Use `getBalanceUnchecked()` for the books without the staleness gates.
    /// @return total The total in local asset decimals (the raw ledgers are in shared decimals).
    function getBalance() external view returns (uint256 total) {
        total = idleLedger;
        for (uint256 i; i < dispatcherChainIds.length; ++i) {
            total += _balanceByChain(dispatcherChainIds[i]);
        }
        total = _toLD(total);
    }

    /// @notice `getBalance()` without the staleness gates (IL-8611): idle + settled + outbound in flight as booked.
    /// @dev Reverts `ChainBlocked` exactly where `getBalance()` does: a blocked chain with a non-zero chain total
    ///      (`settled + outbound`; an empty blocked chain adds nothing, IL-8260). Such a chain means the books are
    ///      known-inconsistent until a rescue completes. Checked here, not only by the caller, since `getBalance()`
    ///      may surface a staleness selector first while such a chain exists.
    function getBalanceUnchecked() external view returns (uint256 total) {
        total = _toLD(
            idleLedger +
                CcipExecutorTransferLib.bookedRemoteTotal(
                    dispatcherChainIds,
                    settledRemoteBalance,
                    outboundInFlight,
                    chainBlocked
                )
        );
    }

    /// @notice The per-chain term of `getBalance()` for `chainId_` (settled plus in-flight), in LOCAL asset
    ///         decimals; idle tokens are not included. CCIP: fail-closed like the per-chain term of `getBalance()` (`ChainBlocked` /
    ///         `TransferStale` / `ObservationStale`); Stargate: a raw sum of the three booked buckets with no
    ///         gates; never use it to price anything.
    function getBalanceByChain(uint256 chainId_) external view returns (uint256) {
        return _toLD(_balanceByChain(chainId_));
    }

    /// @dev Inbound handler for the dispatcher -> executor lane.
    ///
    ///      CCIP does not keep this lane in order: the dispatcher sends from a FIFO queue, but on CCIP 2.0
    ///      `OffRamp.execute` runs messages in any order (IL-8496). Apart from the envelope check in
    ///      `CcipMessages.decode` (`InvalidVersion` / `InvalidMessageType`, a mismatched deployment), the one
    ///      intended revert is `StateVersionGap` in `_acceptRemoteStateVersion`, for a value-moving response
    ///      (`TRANSFER_SETTLED`, `RETURN_TRANSFER`) that arrives ahead of the frontier: the OffRamp records it as
    ///      FAILURE with every effect rolled back, and it is re-executed once the missing version has landed.
    ///      Only those two responses bump the dispatcher's `stateVersion` and move the frontier (IL-8257); each
    ///      consumes its version before any ignore exit on its payload, so an ignored response never leaves a gap
    ///      (the token-shape check of `TRANSFER_SETTLED`, which the dispatcher never sends with tokens, runs
    ///      first). `BALANCE_REPORT` and `COMMAND_ACK` are value-neutral: they carry the current version as
    ///      evidence, emit `RemoteBalanceUpdated` and never touch the frontier, so they cannot gap or advance it.
    ///      Otherwise every branch is applied-or-ignored, never reverting, with the reason emitted for monitoring
    ///      (audit C-1 / H-2): a response that can never apply would otherwise fail forever. Anything that cannot
    ///      be reconciled leaves the delivered tokens as untracked surplus, recoverable through the timelocked
    ///      rescue path.
    ///
    ///      The `TRANSFER_SETTLED` body lives in `CcipExecutorTransferLib.applyTransferSettled`; the credit is
    ///      bounded by the recorded outbound amount and `remoteBalance` is evidence only.
    function _handleCcipMessage(uint256 srcChainId_, CcipClient.Any2EVMMessage memory message_) internal override {
        (CcipMsgType messageType, bytes memory data) = CcipMessages.decode(message_.data);
        if (messageType == CcipMsgType.TRANSFER_SETTLED) {
            if (message_.destTokenAmounts.length != 0) return _ignore(srcChainId_, messageType, "token");
            (bytes32 reason, uint256 remoteBalance, uint64 stateVersion) = CcipExecutorTransferLib.applyTransferSettled(
                outboundTransfers,
                outboundInFlight,
                settledRemoteBalance,
                _pendingCreatedAt,
                pendingTransferCount,
                oldestPendingAt,
                _attestationState,
                srcChainId_,
                data
            );
            _acceptRemoteStateVersion(srcChainId_, remoteBalance, stateVersion);
            if (reason != bytes32(0)) return _ignore(srcChainId_, messageType, reason);
        } else if (messageType == CcipMsgType.RETURN_TRANSFER) {
            (bytes32 operationId, uint256 sentSD, uint256 remoteBalance, uint64 stateVersion) = abi.decode(
                data,
                (bytes32, uint256, uint256, uint64)
            );
            _acceptRemoteStateVersion(srcChainId_, remoteBalance, stateVersion);
            // A standard CCIP 2.0 pool fee plus decimal downscaling can deliver a ZERO amount for a positive
            // send; an absent or zero token entry is a valid finalization with `received == 0` (IL-8635), not an
            // ignore that would leave the recall open. Any other token shape is still ignored.
            // The credited amount is EXTERNAL: floor it rather than reverting on sub-precision dust.
            uint256 received;
            if (message_.destTokenAmounts.length != 0) {
                if (message_.destTokenAmounts.length != 1 || message_.destTokenAmounts[0].token != _asset()) {
                    return _ignore(srcChainId_, messageType, "token");
                }
                received = _toSDFloor(message_.destTokenAmounts[0].amount);
            }
            PendingReturn storage pending = pendingReturns[operationId];
            ReturnStatus status = pending.status;
            if (pending.createdAt == 0 || (status != ReturnStatus.REQUESTED && status != ReturnStatus.CANCELLED)) {
                return _ignore(srcChainId_, messageType, "unknown");
            }
            if (pending.chainId != srcChainId_) return _ignore(srcChainId_, messageType, "chain");
            // The tokens are already home. Refusing them would not undo the transfer — it would strand
            // them and kill the lane — so a shortfall against the requested floor is credited and loudly
            // surfaced instead of reverted (audit H-2). The authoritative pre-send bound stays on the
            // dispatcher, which rejects the recall before any value moves.
            if (received < pending.minReturn) {
                emit ReturnBelowMinimumCredited(srcChainId_, operationId, received, pending.minReturn);
            }
            pending.status = ReturnStatus.FINALIZED;
            // Debit body (+ the accounting anchor pro-rata reduction, IL-7967) lives in the attestation
            // lib so the executor spends no extra bytes on it. `settled` is debited by the dispatcher-declared
            // `sentSD`, not by `received`: the transport fee is a realized loss, not phantom settled value
            // (IL-8497).
            uint256 debited = _attestationState.applyReturnDebit(
                settledRemoteBalance,
                srcChainId_,
                operationId,
                sentSD,
                pending.maxAccounted,
                remoteBalance
            );
            idleLedger += received;
            _attestationState.bumpEpochValueMoving(srcChainId_);
            _resolveCancelledReturn(srcChainId_, operationId, status);
            if (activeReturn[srcChainId_] == operationId) {
                delete activeReturn[srcChainId_];
                emit ReturnFinalized(srcChainId_, operationId, sentSD, received, debited);
            } else {
                emit LateReturnFinalized(srcChainId_, operationId, sentSD, received, debited);
            }
        } else if (messageType == CcipMsgType.RETURN_REJECTED) {
            if (message_.destTokenAmounts.length != 0) return _ignore(srcChainId_, messageType, "token");
            (bytes32 operationId, uint8 reason) = abi.decode(data, (bytes32, uint8));
            PendingReturn storage pending = pendingReturns[operationId];
            ReturnStatus status = pending.status;
            if (pending.createdAt == 0 || (status != ReturnStatus.REQUESTED && status != ReturnStatus.CANCELLED)) {
                return _ignore(srcChainId_, messageType, "unknown");
            }
            if (pending.chainId != srcChainId_) return _ignore(srcChainId_, messageType, "chain");
            pending.status = ReturnStatus.REJECTED;
            if (activeReturn[srcChainId_] == operationId) delete activeReturn[srcChainId_];
            _resolveCancelledReturn(srcChainId_, operationId, status);
            emit ReturnRejected(srcChainId_, operationId, reason);
        } else if (messageType == CcipMsgType.COMMAND_ACK) {
            if (message_.destTokenAmounts.length != 0) return _ignore(srcChainId_, messageType, "token");
            (
                ReceiptIgnoreReason reason,
                bytes32 commandId,
                ,
                uint256 remoteBalance,
                uint64 stateVersion
            ) = _commandState.acknowledgeReceipt(srcChainId_, data);
            // A command receipt is value-neutral for the version (IL-8257): the dispatcher no longer bumps
            // `stateVersion` for it, it only carries the CURRENT version as evidence. So there is nothing to
            // consume (the IL-7970 "consume the version FIRST" rule applied when ACKs bumped it) and the
            // frontier must not move: an ACK carrying `V+1` can overtake a still in-transit
            // `TRANSFER_SETTLED V+1`, and advancing on it would drop that settle as stale. Record the
            // evidence and decide about the command effects; the ACK also applies when a value response
            // is still in transit, which keeps the command lane live.
            CcipExecutorCommandLib.recordRemoteBalanceEvidence(srcChainId_, remoteBalance, stateVersion);
            if (reason != ReceiptIgnoreReason.NONE) {
                emit CommandReceiptIgnored(srcChainId_, commandId, uint8(messageType), uint8(reason));
                return;
            }
            // `CommandAcknowledged` is emitted by `acknowledgeReceipt` (it carries the resolution and epoch).
        } else if (messageType == CcipMsgType.COMMAND_NACK) {
            if (message_.destTokenAmounts.length != 0) return _ignore(srcChainId_, messageType, "token");
            (bytes32 commandId, uint64 sequence) = abi.decode(data, (bytes32, uint64));
            ReceiptIgnoreReason reason = _commandState.fail(srcChainId_, commandId, sequence);
            if (reason != ReceiptIgnoreReason.NONE) {
                emit CommandReceiptIgnored(srcChainId_, commandId, uint8(messageType), uint8(reason));
                return;
            }
            emit CommandFailed(srcChainId_, commandId, sequence);
        } else if (messageType == CcipMsgType.BALANCE_REPORT) {
            if (message_.destTokenAmounts.length != 0) return _ignore(srcChainId_, messageType, "token");
            (uint256 remoteBalance, uint64 stateVersion) = abi.decode(data, (uint256, uint64));
            // Evidence only (IL-8257): a report never bumps the dispatcher version, so it never moves the
            // frontier either.
            CcipExecutorCommandLib.recordRemoteBalanceEvidence(srcChainId_, remoteBalance, stateVersion);
            balanceRequestOutstanding[srcChainId_] = false;
        } else {
            _ignore(srcChainId_, messageType, "type");
        }
    }

    /// @dev A cancelled recall (`status_` read before the terminal write) resolved: drop one from the chain's
    ///      cancelled count and clear the clock with the last one (IL-8590). No-op for a recall cancelled before
    ///      the last clock reset (`FORCE_SET_SETTLED` or `ADVANCE_FRONTIER`, older generation).
    function _resolveCancelledReturn(uint256 chainId_, bytes32 operationId_, ReturnStatus status_) private {
        uint32 count = cancelledRecallCount[chainId_];
        if (status_ != ReturnStatus.CANCELLED || count == 0) return;
        // An answer to a recall cancelled before the last reset must not touch the newer clock.
        if (cancelledRecallGenerationOf[operationId_] != cancelledRecallGeneration[chainId_]) return;
        cancelledRecallCount[chainId_] = count - 1;
        if (count == 1) delete cancelledRecallPendingAt[chainId_];
    }

    /// @dev Drop the chain's cancelled-recall clock and start a new generation (IL-8590). While a cancelled recall
    ///      is unresolved, the reset waits until `cancelledRecallLatestAt + TRANSFER_STALENESS_MAX +
    ///      RECALL_DEADLINE_SKEW_MARGIN` has passed: only then is every cancelled `RETURN_REQUEST` guaranteed to be
    ///      rejected `EXPIRED` by the dispatcher (given the skew assumption), so forgetting the clock cannot leave a
    ///      request that still moves value unpriced. The newest recall is used because its deadline expires last.
    ///      Before that: `strict_` (FORCE_SET_SETTLED) reverts `CancelledRecallNotExpired(chainId, refusedUntil)`;
    ///      non-strict (ADVANCE_FRONTIER) leaves the clock untouched and returns.
    function _resetCancelledRecall(uint256 chainId_, bool strict_) private {
        CcipExecutorTransferLib.resetCancelledRecall(
            cancelledRecallCount,
            cancelledRecallPendingAt,
            cancelledRecallLatestAt,
            cancelledRecallGeneration,
            chainId_,
            _transferStalenessMax(),
            strict_
        );
    }

    function _ignore(uint256 chainId_, CcipMsgType messageType_, bytes32 reason_) private {
        emit InboundMessageIgnored(chainId_, uint8(messageType_), reason_);
    }

    /// @dev Frontier advance for the value-moving responses only; body lives in the linked library for
    ///      EIP-170 headroom. Reverts `StateVersionGap` on a response that arrives ahead of the frontier, so
    ///      the OffRamp keeps it for re-execution (IL-8496) — see the library's NatSpec.
    function _acceptRemoteStateVersion(uint256 chainId_, uint256 remoteBalance_, uint64 stateVersion_) private {
        CcipExecutorCommandLib.acceptRemoteStateVersion(
            lastRemoteStateVersion,
            chainId_,
            remoteBalance_,
            stateVersion_
        );
    }

    function _balanceByChain(uint256 chainId_) private view returns (uint256) {
        return
            CcipExecutorTransferLib.balanceByChain(
                chainBlocked,
                oldestPendingAt,
                activeReturn,
                pendingReturns,
                settledRemoteBalance,
                outboundInFlight,
                _attestationState,
                cancelledRecallPendingAt[chainId_],
                chainId_,
                CcipExecutorTransferLib.BalanceGates({
                    transferStalenessMax: _transferStalenessMax(),
                    balanceStalenessMax: _balanceStalenessMax()
                })
            );
    }

    function _requireReady(uint256 chainId_) private view {
        if (!hasDispatcher[chainId_]) revert DispatcherNotReady(chainId_);
    }

    function _armStaleness(uint256 chainId_) private returns (uint8 slot_) {
        return CcipExecutorTransferLib.armStaleness(_pendingCreatedAt, pendingTransferCount, oldestPendingAt, chainId_);
    }

    function _disarmStaleness(uint256 chainId_, uint8 slot_) private {
        CcipExecutorTransferLib.disarmStaleness(
            _pendingCreatedAt,
            pendingTransferCount,
            oldestPendingAt,
            chainId_,
            slot_
        );
    }

    function _bumpAccountingEpoch(uint256 chainId_) private {
        _attestationState.bumpEpoch(chainId_);
    }

    function lastApprovedObservedAt(uint256 chainId_) external view returns (uint64) {
        return _attestationState.lastApprovedObservedAt[chainId_];
    }

    /// @notice Per-chain accounting epoch; bumped by every value-moving operation to invalidate the active proposal.
    function accountingEpoch(uint256 chainId_) external view returns (uint64) {
        return _attestationState.accountingEpoch[chainId_];
    }

    /// @notice Local time of the last value-moving dispatcher response (or outbound force-resolve / settled
    ///         force-set) applied for the chain; a balance proposal, its approval and a `FORCE_SET_SETTLED` schedule
    ///         must carry a strictly later remote observation time (IL-8604 / IL-8584).
    function lastValueMovingReceiptAt(uint256 chainId_) external view returns (uint64) {
        return _attestationState.lastValueMovingReceiptAt[chainId_];
    }

    /// @notice The active balance proposal id per chain (0 = none).
    function activeProposalId(uint256 chainId_) external view returns (uint256) {
        return _attestationState.activeProposalId[chainId_];
    }

    /// @notice The per-chain accounting anchor `approveBalance` bounds attestations against (IL-7967).
    function attestationAnchorPrincipal(uint256 chainId_) external view returns (uint256) {
        return _attestationState.anchorPrincipal[chainId_];
    }

    /// @notice The per-chain net principal that caps anchor credits (IL-8578 / TP-H-02).
    function attestationNetPrincipal(uint256 chainId_) external view returns (uint256) {
        return _attestationState.netPrincipal[chainId_];
    }

    function _beforeRescueExecuted() internal view override returns (uint256) {
        return IERC20(_asset()).balanceOf(address(this));
    }

    function _afterRescueExecuted(uint256 balanceBefore_) internal override {
        uint256 balance = IERC20(_asset()).balanceOf(address(this));
        uint256 required = _toLD(idleLedger);
        if (balanceBefore_ < required) required = balanceBefore_;
        if (balance < required) revert UnbackedIdleCredit(balance, required);
    }

    function ccipReceive(CcipClient.Any2EVMMessage calldata message_) public override nonReentrant {
        super.ccipReceive(message_);
    }

    /// @dev Exact: only for amounts a privileged caller (manager, rescue admin) supplies and that must round-trip
    ///      byte-exactly.
    function _toSDExact(uint256 amountLD_) private view returns (uint256 amountSD) {
        return CcipDecimalsLib.toSDExact(amountLD_, _rate());
    }

    /// @dev Truncating: for measured or externally observed amounts. Never reverts (audit C-2/H-2).
    function _toSDFloor(uint256 amountLD_) private view returns (uint256 amountSD) {
        return CcipDecimalsLib.toSDFloor(amountLD_, _rate());
    }

    function _toLD(uint256 amountSD_) private view returns (uint256) {
        return CcipDecimalsLib.toLD(amountSD_, _rate());
    }

    /// @dev Shared library call of `cancelPendingReturn` / `cancelStalePendingReturn` (EIP-170).
    function _cancelReturn(uint256 chainId_, uint256 stalenessMax_, bool requireStale_) private {
        CcipExecutorTransferLib.cancelPendingReturn(
            activeReturn,
            pendingReturns,
            cancelledRecallCount,
            cancelledRecallPendingAt,
            cancelledRecallGeneration,
            cancelledRecallGenerationOf,
            cancelledRecallLatestAt,
            chainId_,
            stalenessMax_,
            requireStale_
        );
    }

    /// @dev Commitment shared by `scheduleForceResolveOutbound` / `executeForceResolveOutbound`.
    function _outboundCommitment(bytes32 operationId_, bool creditToSettled_) private pure returns (bytes32) {
        return keccak256(abi.encode("CCIP_OUTBOUND", operationId_, creditToSettled_));
    }

    /// @dev Reads `BALANCE_STALENESS_MAX` through one shared JUMP target instead of inlining the immutable (EIP-170).
    function _balanceStalenessMax() private view returns (uint256) {
        return BALANCE_STALENESS_MAX;
    }

    /// @dev Reads `TRANSFER_STALENESS_MAX` through one shared JUMP target instead of inlining the immutable (EIP-170).
    function _transferStalenessMax() private view returns (uint256) {
        return TRANSFER_STALENESS_MAX;
    }

    /// @dev Reads `DECIMAL_CONVERSION_RATE` through one shared JUMP target instead of inlining the immutable (EIP-170).
    function _rate() private view returns (uint256) {
        return DECIMAL_CONVERSION_RATE;
    }

    /// @dev Reads the immutable through one JUMP instead of an inlined PUSH32 at every site (EIP-170).
    function _asset() private view returns (address) {
        return ASSET;
    }

    /// @dev Approver check shared by its call sites (EIP-170).
    function _checkApprover() private view {
        if (msg.sender != BALANCE_APPROVER) revert OnlyBalanceApprover();
    }

    /// @dev Factory check shared by its call sites (EIP-170).
    function _checkFactory() private view {
        if (msg.sender != FACTORY) revert OnlyFactory();
    }

    /// @dev Modifier body as one internal call instead of an inlined copy per use (EIP-170).
    function _checkManager() private view {
        if (msg.sender != MANAGER) revert OnlyManager();
    }

    /// @dev IL-8625: stored-word count of each command's payload (the dispatcher's pre-check work scales with it), read
    ///      by `requireRetryGas`. Declared LAST so no existing executor slot moves.
    mapping(bytes32 commandId => uint32 words) private _commandPayloadWords;
}
