// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CrosschainErrors} from "./CrosschainErrors.sol";
import {CrosschainConstants} from "./CrosschainConstants.sol";
import {RescueLogicLib, RescueStorage, RescueStorageRecord} from "./RescueLogicLib.sol";

/// @title RescueModule
/// @notice Generic, timelocked, guardian-vetoable rescue queue shared by the crosschain executors and
///         dispatchers of both transports and by the Stargate factory. The rescue admin is a full delayed
///         administrator: it can schedule
///         an arbitrary `target.call{value}(callData)` that, after `RESCUE_DELAY`, executes as this
///         contract. An immutable independent guardian can veto any single scheduled action or veto
///         all pending actions at once, but can never schedule or execute one.
/// @dev Inherited by every host. The hosts are ordinary deployed contracts (no proxy), so the queue lives in
///      their regular storage (`RescueStorage`); the queue/timelock state machine runs in the linked
///      `RescueLogicLib` on that storage. The same queue and timelock/veto machinery back the hosts' other
///      timelocked admin exits (executor force-resolves, force-sets and chain rescues; dispatcher admin recall,
///      force-untrack and, on CCIP, the stuck-response skip) via the `_scheduleForceResolve` / `_consumeForceResolve`
///      internal helpers, so those share the delay, the guardian veto epoch and the cancel path with generic
///      rescues.
/// @author IPOR Labs
abstract contract RescueModule is ReentrancyGuard {
    /// @notice Discriminates a queued action between a generic external call and a force-resolve marker.
    enum RescueKind {
        NONE, // 0 - empty slot
        GENERIC, // 1 - arbitrary `target.call{value}(callData)`
        FORCE_RESOLVE // 2 - NAV force-resolve marker (no external call; subclass applies the change)
    }

    /// @notice Lifecycle state of a queued action.
    enum RescueState {
        NONE, // 0 - never scheduled
        SCHEDULED, // 1 - committed, awaiting timelock / veto window
        EXECUTED, // 2 - terminally executed / consumed
        CANCELLED // 3 - terminally cancelled
    }

    /// @notice A single queued rescue or force-resolve commitment.
    /// @param kind Generic external call or force-resolve marker.
    /// @param state Lifecycle state.
    /// @param executableAt Unix timestamp after which the action may execute.
    /// @param vetoEpoch The guardian veto epoch snapshotted at schedule time; must still match at execute.
    /// @param target GENERIC only: the call target.
    /// @param value GENERIC only: the native value forwarded with the call.
    /// @param commitment GENERIC: `keccak256(callData)`; FORCE_RESOLVE: the caller-supplied commitment.
    struct RescueRecord {
        RescueKind kind;
        RescueState state;
        uint64 executableAt;
        uint64 vetoEpoch;
        address target;
        uint256 value;
        bytes32 commitment;
    }

    /// @notice Full delayed administrator: schedules and executes rescues / force-resolves.
    /// @dev Immutable. Must be an independently controlled contract (a Safe), never an EOA.
    address public immutable ADMIN;

    /// @notice Independent veto-only role: can cancel a scheduled action or veto all pending actions.
    /// @dev Immutable and distinct from `ADMIN`. Can never schedule or execute.
    address public immutable RESCUE_GUARDIAN;

    /// @notice Minimum delay (seconds) between scheduling and executing an action.
    uint256 public immutable RESCUE_DELAY;

    /// @dev The rescue queue: records, `rescueCount`, `pendingRescueCount` and the monotonic guardian veto
    ///      epoch (bumped by `vetoAllPendingRescues`; a scheduled action is executable only while its snapshotted
    ///      epoch still equals it). Private; read through `rescues` / `rescueCount` / `pendingRescueCount` (the
    ///      current veto epoch has no getter: follow `AllRescuesVetoed(newVetoEpoch)`).
    RescueStorage private _rescueStorage;

    /// @notice Emitted when a generic rescue is scheduled.
    event RescueScheduled(
        uint256 rescueId,
        address target,
        uint256 value,
        bytes32 commitment,
        uint256 executableAt,
        uint256 vetoEpoch
    );

    /// @notice Emitted when a generic rescue is executed.
    event RescueExecuted(uint256 rescueId, address target, uint256 value, bytes32 commitment);

    /// @notice Emitted when a queued action (generic or force-resolve) is cancelled.
    event RescueCancelled(uint256 rescueId, address canceller);

    /// @notice Emitted when the guardian vetoes all pending actions.
    event AllRescuesVetoed(uint256 newVetoEpoch);

    /// @notice Emitted when a force-resolve marker is scheduled.
    event ForceResolveScheduled(uint256 rescueId, bytes32 commitment, uint256 executableAt, uint256 vetoEpoch);

    /// @notice Emitted when a force-resolve marker is consumed (the subclass applies the NAV change).
    event ForceResolveConsumed(uint256 rescueId, bytes32 commitment);

    // RescueLogicLib errors. The library runs under delegatecall, so they are raised from the host address;
    // declared here so every host inheriting the module carries them in its ABI (signatures must match the
    // library's, see CrosschainLibraryAbiCompletenessTest).
    error ForceResolveCommitmentMismatch(uint256 rescueId);
    error RescueAlreadyConsumed(uint256 rescueId);
    error RescueCallFailed();
    error RescueCalldataMismatch(uint256 rescueId);
    error RescueFactoryCall(address factory);
    error RescueExecutorCall(address executor);
    error RescueContextCall(address target);
    error RescueTransportCall(address target, bytes4 selector);
    error RescueTrackedVaultCall(address vault);
    error RescueTrackedSetTooLarge(uint256 len, uint256 max);
    error RescueHostReadFailed(bytes4 selector);
    error RescueTrackedSharesReduced(address vault, uint256 before, uint256 after_);
    error RescueNotScheduled(uint256 rescueId);
    error RescueProtectedTokenCall(address token, bytes4 selector);
    error RescueQueueFull(uint256 max);
    error RescueTimelockNotElapsed(uint256 rescueId, uint256 nowTs, uint256 executableAt);
    error RescueVetoed(uint256 rescueId);
    error RescueWrongKind(uint256 rescueId);
    /// @dev OpenZeppelin SafeCast error, raised inside RescueLogicLib.
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    /// @notice Restricts a function to the rescue admin.
    modifier onlyRescueAdmin() {
        _checkRescueAdmin();
        _;
    }

    /// @dev Body of `onlyRescueAdmin`, kept out of the modifier so it is not inlined at every use (EIP-170).
    function _checkRescueAdmin() internal view {
        if (msg.sender != ADMIN) revert CrosschainErrors.UnauthorizedRescueAdmin(msg.sender);
    }

    /// @notice Restricts a function to the rescue guardian.
    modifier onlyRescueGuardian() {
        if (msg.sender != RESCUE_GUARDIAN) revert CrosschainErrors.UnauthorizedRescueGuardian(msg.sender);
        _;
    }

    /// @param admin_ Rescue admin (full delayed administrator); must be non-zero and != guardian_.
    /// @param guardian_ Rescue guardian (veto only); must be non-zero and != admin_.
    /// @param rescueDelay_ Timelock in seconds applied to every scheduled action.
    constructor(address admin_, address guardian_, uint256 rescueDelay_) {
        if (admin_ == address(0) || guardian_ == address(0)) revert CrosschainErrors.ZeroAddress();
        if (admin_ == guardian_) revert CrosschainErrors.SameAddress();
        if (rescueDelay_ < CrosschainConstants.MIN_RESCUE_DELAY) {
            revert CrosschainErrors.InvalidRescueDelay(rescueDelay_, CrosschainConstants.MIN_RESCUE_DELAY);
        }
        ADMIN = admin_;
        RESCUE_GUARDIAN = guardian_;
        RESCUE_DELAY = rescueDelay_;
    }

    // ============================================================
    // Generic rescue (admin scheduled/executed, guardian vetoable)
    // ============================================================

    /// @notice Schedule a generic delayed call executed as this contract after `RESCUE_DELAY`.
    /// @dev Admin only. Stores a commitment to `(target, value, keccak256(callData))`; the calldata
    ///      itself is not stored and must be re-supplied to `executeRescue`. Reverts if the queue is full,
    ///      and for calls to the subclass's own factory — the address its `FACTORY()` getter returns —
    ///      because the factory trusts calls from its executors (IL-8261).
    ///      Calls to the subclass's tracked asset — the address its `ASSET()` getter returns, read back
    ///      by `RescueLogicLib` — are narrowed to a plain `transfer(address,uint256)`, because the
    ///      post-call `_afterRescueExecuted` balance snapshot cannot see spending rights granted over
    ///      tracked value (approve / permit / operator grants).
    ///      Two more fences (IL-8555, IL-8556): no call to the transport (the CCIP router, the Stargate
    ///      pool, or the LayerZero endpoint except `skip`/`clear`/`nilify`/`burn`) because both authenticate the host
    ///      by bare `msg.sender` and a rescue `send`/`ccipSend` would forge a peer message on the other
    ///      chain; and no call to a tracked or allowlisted vault of a dispatcher (re-checked at execute time, plus a
    ///      share-balance snapshot around the call), because share approvals or redemptions bypass the
    ///      ASSET floor.
    ///      Two further fences (IL-8763, IL-8770): the Stargate factory may not call any of its own
    ///      executors (the address passes the host's `isExecutor(address)`; re-checked at execute time),
    ///      because executors trust it by `msg.sender`; and no call may carry the ContextManager
    ///      `runWithContext` selector, because it would make this contract the context sender.
    /// @param target_ The call target.
    /// @param value_ Native value to forward with the call.
    /// @param callData_ The calldata that will be executed (committed via its keccak hash).
    /// @return rescueId The id of the scheduled rescue.
    function scheduleRescue(
        address target_,
        uint256 value_,
        bytes calldata callData_
    ) external onlyRescueAdmin returns (uint256 rescueId) {
        // Self-calls could otherwise reach dispatcher-only self entry points and bypass their normal
        // sequencing/epoch envelope. Dedicated force-resolve entry points remain available.
        if (target_ == address(this)) revert CrosschainErrors.SameAddress();
        return RescueLogicLib.schedule(_rescueStorage, RESCUE_DELAY, target_, value_, callData_);
    }

    /// @notice Execute a previously scheduled generic rescue after its timelock, if not vetoed.
    /// @dev Admin only. CEI: the record is marked `EXECUTED` before the external call. Failure bubbles
    ///      the target's revert data atomically. On success the `_afterRescueExecuted` hook runs (each executor /
    ///      dispatcher snapshots ASSET before the call and requires `balanceAfter >= min(balanceBefore, ledger)`
    ///      after it; the Stargate factory tracks no ASSET and keeps the no-op default).
    /// @param rescueId_ The scheduled rescue id.
    /// @param callData_ The exact calldata committed at schedule time.
    function executeRescue(uint256 rescueId_, bytes calldata callData_) external onlyRescueAdmin nonReentrant {
        uint256 balanceBefore = _beforeRescueExecuted();
        RescueLogicLib.execute(_rescueStorage, rescueId_, callData_);
        _afterRescueExecuted(balanceBefore);
    }

    /// @notice Terminally cancel a scheduled generic rescue or force-resolve marker.
    /// @dev Admin or guardian. Only `SCHEDULED` records can be cancelled. The pending counter is
    ///      decremented only when the record is still counted under the current veto epoch, so
    ///      cancelling a stale (globally vetoed) record cannot underflow the counter.
    /// @param rescueId_ The queued action id.
    function cancelRescue(uint256 rescueId_) external {
        if (msg.sender != ADMIN && msg.sender != RESCUE_GUARDIAN) {
            revert CrosschainErrors.UnauthorizedRescueCanceller(msg.sender);
        }
        RescueLogicLib.cancel(_rescueStorage, rescueId_, msg.sender);
    }

    /// @notice Veto every currently pending action without an unbounded loop.
    /// @dev Guardian only. Advances the veto epoch (invalidating all prior `SCHEDULED` records via the
    ///      execute-time epoch check) and resets the pending counter, re-opening the full queue cap.
    function vetoAllPendingRescues() external onlyRescueGuardian {
        RescueLogicLib.vetoAll(_rescueStorage);
    }

    // ============================================================
    // Force-resolve helpers (internal — wrapped by the hosts' admin-gated entry points, §4.3)
    // ============================================================

    /// @notice Schedule a force-resolve marker sharing the rescue delay, veto epoch and cancel path.
    /// @dev Internal: the hosts' admin-gated schedule entry points wrap this (e.g. the Stargate executor's
    ///      `scheduleForceResolveTransfer`, the CCIP executor's `scheduleChainRescue`, the dispatchers'
    ///      `scheduleAdminRecall`). No external call is ever made for this kind; the host applies the change
    ///      on consume.
    /// @param commitment_ Commitment binding the resolution (e.g. keccak of transferId + outcome).
    /// @return rescueId The id of the scheduled force-resolve.
    function _scheduleForceResolve(bytes32 commitment_) internal returns (uint256 rescueId) {
        return RescueLogicLib.scheduleForce(_rescueStorage, RESCUE_DELAY, commitment_);
    }

    /// @dev A shorter delay is reserved exclusively for state-frontier repair wrappers. The consuming
    ///      wrapper must still block the affected chain until a fresh approved observation arrives.
    function _scheduleFrontierRepair(bytes32 commitment_) internal returns (uint256 rescueId) {
        return RescueLogicLib.scheduleForce(_rescueStorage, CrosschainConstants.FRONTIER_REPAIR_DELAY, commitment_);
    }

    /// @notice Consume a scheduled force-resolve marker after its timelock, if not vetoed.
    /// @dev Internal: the hosts' admin-gated execute entry points (e.g. `executeForceResolveTransfer`) wrap this
    ///      and apply the change atomically after the call returns. Same checks as `executeRescue` minus the
    ///      external call. The caller MUST enforce admin authorization.
    /// @param rescueId_ The scheduled force-resolve id.
    /// @param commitment_ The exact commitment supplied at schedule time.
    function _consumeForceResolve(uint256 rescueId_, bytes32 commitment_) internal {
        RescueLogicLib.consumeForce(_rescueStorage, rescueId_, commitment_);
    }

    // ============================================================
    // Hooks / internal
    // ============================================================

    /// @notice Hook invoked before a generic rescue call; returns the host's ASSET balance snapshot.
    /// @dev Default returns `type(uint256).max` (fail-closed: `min(max, ledger) = ledger`, so a host that
    ///      overrides only the after-hook keeps the absolute rule). Hosts override it to return
    ///      `ASSET.balanceOf(this)`; the value is passed to `_afterRescueExecuted` so the post-condition can be
    ///      non-worsening (IL-8640).
    function _beforeRescueExecuted() internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Hook invoked after a successful generic rescue call.
    /// @dev Default no-op. Hosts override this to assert their tracked-ledger invariant in a
    ///      non-worsening form: `ASSET.balanceOf(this) >= min(balanceBefore_, required)` where `required`
    ///      is the tracked ledger in LD (§4.3). A rescue may never lower a sufficient balance below the
    ///      ledger and never lower an already-insufficient balance further, so a host whose balance fell
    ///      below its ledger through an issuer-side adjustment can still run endpoint clear/skip, native,
    ///      unrelated-token and share recoveries. The donation remedy (transferring ASSET in) stays
    ///      available. This is the second layer only: it bounds how much value a rescue may *move*, while
    ///      the protected-asset guard in `scheduleRescue` bounds what a rescue may *authorise*.
    /// @param balanceBefore_ The snapshot returned by `_beforeRescueExecuted`.
    function _afterRescueExecuted(uint256 balanceBefore_) internal virtual {}

    function rescueCount() public view returns (uint256) {
        return _rescueStorage.rescueCount;
    }

    function pendingRescueCount() public view returns (uint256) {
        return _rescueStorage.pendingRescueCount;
    }

    function rescues(
        uint256 rescueId_
    )
        public
        view
        returns (
            RescueKind kind,
            RescueState state,
            uint64 executableAt,
            uint64 vetoEpoch,
            address target,
            uint256 value,
            bytes32 commitment
        )
    {
        RescueStorageRecord storage record = _rescueStorage.rescues[rescueId_];
        return (
            RescueKind(record.kind),
            RescueState(record.state),
            record.executableAt,
            record.vetoEpoch,
            record.target,
            record.value,
            record.commitment
        );
    }
}
