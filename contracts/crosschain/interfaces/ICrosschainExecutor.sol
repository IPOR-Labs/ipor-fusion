// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Command} from "../lib/CrosschainMessages.sol";
import {DeploymentStatus} from "../lib/CrosschainConstants.sol";

/// @notice A settled-remote-balance attestation observation. Absolute
///         overwrite of the settled bucket only; in-flight buckets are never proposal fields. Amounts
///         are in local ASSET decimals per §4.1.
/// @param chainId The remote chain the observation is for.
/// @param settledBalance Absolute settled remote balance (local ASSET decimals).
/// @param stateVersion Dispatcher state version the observation was taken at (must equal the executor's
///        acknowledged frontier for that chain).
/// @param remoteBlock Remote block number the observation was read at.
/// @param remoteTimestamp Remote block timestamp the observation was read at.
/// @param expiry Timestamp after which the proposal can no longer be approved.
/// @param trackedPositionSetHash Hash of the dispatcher's tracked-position set at observation time.
struct BalanceObservation {
    uint256 chainId;
    uint256 settledBalance;
    uint64 stateVersion;
    uint64 remoteBlock;
    uint64 remoteTimestamp;
    uint64 expiry;
    bytes32 trackedPositionSetHash;
}

/// @title ICrosschainExecutor
/// @notice Locked call surface of the crosschain executor. Lives next to the source
///         PlasmaVault; the vault (immutable `MANAGER`) drives it through fuses. Also exposes the NAV
///         read consumed by the balance fuse and the factory-only deployment callbacks.
/// @dev First cut: the concrete contract adds rescue (via `RescueModule`) and inbound transport
///      handlers. `getBalance()` MUST NOT read raw `ASSET.balanceOf(this)` — it sums the four buckets
///      and applies freshness/blocked checks.
///      Implemented by `StargateCrosschainExecutor`. `CcipCrosschainExecutor` has its own surface
///      (`ICcipCrosschainExecutor`); the fuses and the NAV pre-hook reach it through this interface only for
///      `MANAGER()`, `claimAsset`, `getBalance()` and `getBalanceUnchecked()`, which it declares with the same
///      signatures.
/// @author IPOR Labs
interface ICrosschainExecutor {
    // --- Manager (== MANAGER, the PlasmaVault) only ---

    /// @notice Transfer `min(amount_, toLD(idleLedger))` of ASSET (rounded down to whole shared-decimal
    ///         units) to the manager and decrement the ledger.
    function claimAsset(uint256 amount_) external;

    /// @notice Append a validated target chain under the bijection/migration rules.
    /// @dev Stargate: `enforcedOptions_` must give the command lane exactly one executor `lzReceive` option
    ///      with gas in [`COMMAND_LANE_MIN_RECEIVE_GAS`, `COMMAND_LANE_MAX_RECEIVE_GAS`] and no value; a path is
    ///      append-only, so a registration missing that option is rejected here instead of surfacing later,
    ///      when the command-lane sends it enables would otherwise fail (IL-8296). That gas is stored and sets
    ///      each command's base budget; a larger manager or retry budget is topped up above it (IL-8625).
    function registerChain(uint256 chainId_, uint32 eid_, bytes calldata enforcedOptions_) external;

    /// @notice Request a dispatcher deployment on `dstChainId_` with an initial vault allowlist.
    function createDispatcher(uint256 dstChainId_, address[] calldata plasmaVaults_) external;

    /// @notice Cancel a stuck dispatcher request after its TTL plus
    ///         `DEPLOYMENT_CANCEL_MARGIN` (manager-driven).
    function cancelDispatcherRequest(uint256 requestId_) external;

    /// @notice Replace the remote deposit allowlist through the sequenced command envelope.
    /// @dev Every vault that leaves the allowlist is swept best effort and ALWAYS untracked: ALPHA must redeem or
    ///      recall its position to zero BEFORE removing it, otherwise a residual the sweep could not redeem leaves NAV
    ///      until the vault is allowlisted again (D-060). Send one removal per command on tight lanes and adds in a
    ///      separate command (D-065).
    function updatePlasmaVaults(uint256 dstChainId_, address[] calldata vaults_) external;

    /// @notice Bridge assets to the dispatcher (taxi + mandatory compose ACK).
    function sendAssetToDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 minAmountLD_,
        bytes calldata lzOptions_
    ) external;

    /// @notice Request assets back from the dispatcher (recall lane) with a min-return slippage bound.
    function requestAssetsFromDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 minReturn_,
        bytes calldata lzOptions_
    ) external;

    /// @notice Send a sequenced business command to the dispatcher (one active per chain).
    /// @dev `cmd_.minExecutionGas` (IL-8625) is the gas budget the dispatcher must have left to run the command; the
    ///      executor always derives one from the lane (formula in `CrosschainConstants.COMMAND_PRE_CALL_BASE`) and the
    ///      id / sequence / epoch fields are executor-assigned. What the manager's value means depends on the transport:
    ///      Stargate: 0 (or any value up to the lane budget) = the lane budget; above it (at most
    ///      `MAX_COMMAND_EXECUTION_GAS`) it becomes the budget and the
    ///      executor appends an extra `lzReceive` gas option (and pays its fee, inside the `maxNativeFee` check) that makes
    ///      the delivered gas reach it. CCIP: 0 = ignore; non-zero must not exceed the budget derived from the effective
    ///      gas limit (the route policy) nor `MAX_COMMAND_EXECUTION_GAS`, else the send reverts; the derived budget is
    ///      what is stamped. Giving a CCIP command more than the route policy needs a timelocked policy raise, then a
    ///      retry.
    function sendCommandToDispatcher(uint256 dstChainId_, Command calldata cmd_) external;

    /// @notice Retry a FAILED business command on the recall lane (dispatcher re-executes). The lane takes
    ///         no sequence of its own; the retry still resolves the record holding the dispatcher's current
    ///         one. Once the lane has moved past that record the Stargate dispatcher ignores it
    ///         (`StaleCommandResolutionIgnored`) and the CCIP dispatcher rejects it (`InvalidSequence`).
    function retryCommand(uint256 dstChainId_) external;

    /// @notice Cancel a FAILED business command on the recall lane; frees the slot on the ACK.
    function cancelCommand(uint256 dstChainId_) external;

    // --- Balance attestation (two-step) ---

    /// @notice Propose a settled-remote-balance observation (BALANCE_PROPOSER).
    function proposeBalance(BalanceObservation calldata observation_) external;

    /// @notice Approve a pending balance proposal (BALANCE_APPROVER).
    function approveBalance(uint256 proposalId_) external;

    /// @notice Reject a proposal and block NAV-dependent vault operations (BALANCE_APPROVER).
    function rejectAndBlockProposal(uint256 proposalId_) external;

    // --- Views (local ASSET decimals) ---

    /// @notice Aggregate NAV: `toLD(idleLedger + Σ(settled + outbound + return))`; fail-closed on staleness and
    ///         on a blocked chain (`ChainBlocked`).
    function getBalance() external view returns (uint256);

    /// @notice The booked NAV without the staleness gates (IL-8611 / TP-M-33), local ASSET decimals.
    /// @dev `getBalance()` minus the staleness reverts: `idleLedger + Σ(settled + in-flight buckets)` exactly as
    ///      booked, so it can be stale. It reverts `ChainBlocked` exactly where `getBalance()` does (a blocked
    ///      chain that still tracks value; on Stargate also an open return record without a staleness slot,
    ///      IL-8618), because such a chain means the books are known-inconsistent until a
    ///      rescue completes. It exists for the balance fuse's per-executor
    ///      recovery fallback only (a recovery-marked executor, whose `getBalance()` reverted with a staleness
    ///      selector, in a market with several executors) and MUST NOT price any value-adding decision.
    function getBalanceUnchecked() external view returns (uint256);

    /// @notice Per-chain booked component (Stargate: settled + outbound + return; CCIP: settled +
    ///         outbound), local ASSET decimals; idle tokens are not included.
    /// @dev The two transports differ. CCIP: fail-closed like the per-chain term of `getBalance()` (`ChainBlocked` /
    ///      `TransferStale` / `ObservationStale`). Stargate: a raw sum of the three booked buckets with no
    ///      `ChainBlocked` or staleness gates (IL-9066). Never use it to price anything.
    function getBalanceByChain(uint256 chainId_) external view returns (uint256);

    /// @notice The PlasmaVault allowed to drive this executor.
    function MANAGER() external view returns (address);

    /// @dev `ASSET()` is intentionally NOT declared here: the transport base already exposes it as a
    ///      public immutable getter, and a non-virtual base getter cannot be reconciled with an
    ///      interface method in the deriving contract. `ASSET()` remains present in the concrete
    ///      executor's ABI (inherited from `StargateOAppBase`).

    /// @notice The chain-independent asset identity.
    function ASSET_ID() external view returns (bytes32);

    /// @notice Whether a dispatcher on `chainId_` is deployed and ready.
    function isDispatcherReady(uint256 chainId_) external view returns (bool);

    /// @notice The lifecycle status of a deployment request.
    function deploymentStatus(uint256 requestId_) external view returns (DeploymentStatus);

    // --- Factory-only callbacks ---

    /// @notice Factory callback: authenticated ACK; flips `hasDispatcher` and sends the initial vault list.
    function onDispatcherCreated(uint256 requestId_, uint256 dstChainId_, address dispatcher_) external;

    /// @notice Factory callback: authenticated NACK; clears the pending request without flipping ready.
    function onDispatcherRequestFailed(uint256 requestId_) external;

    /// @notice Factory callback: TTL cancellation; clears the pending request.
    function onDispatcherRequestCancelled(uint256 requestId_) external;
}
