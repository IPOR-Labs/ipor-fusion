// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Immutable configuration for a new executor. All fields are baked into the
///         executor at CREATE3 deployment and never change. The factory resolves `ASSET`/`STARGATE_POOL`
///         locally from `assetId`.
/// @param assetId Chain-independent asset identity (e.g. `keccak256("USDC")`).
/// @param manager The PlasmaVault allowed to drive the executor (immutable MANAGER).
/// @param admin Rescue admin (full delayed administrator), propagated to every dispatcher.
/// @param rescueGuardian Independent veto-only role, distinct from `admin`, propagated to dispatchers.
/// @param rescueDelay Rescue timelock in seconds, propagated to dispatchers.
/// @param balanceProposer Two-step attestation proposer (must differ from `balanceApprover`).
/// @param balanceApprover Two-step attestation approver.
/// @param stalenessMax Max observation age before NAV blocks (seconds). Bounded to
///        `[MIN_PROPOSAL_APPROVAL_WINDOW, MAX_STALENESS_WINDOW]` at construction (IL-8049).
/// @param bigChangeBps Big-change threshold in basis points. Bounded to `[1, ATTESTATION_ANCHOR_BAND_BPS]`
///        at construction (IL-8049).
/// @param minUpdateInterval Minimum interval between confirmed attestations (seconds). Bounded to
///        `[1, stalenessMax)` at construction (IL-8049).
/// @param deploymentTtl Lifetime of a dispatcher deployment ticket (seconds): the destination refuses to deploy
///        from `createdAt + deploymentTtl` on, and the ticket becomes cancellable `DEPLOYMENT_CANCEL_MARGIN` later
///        (IL-8623). Bounded to `[MIN_DEPLOYMENT_TTL, MAX_DEPLOYMENT_TTL]` at construction (IL-8049).
/// @param transferStalenessMax Max in-flight transfer record age before NAV blocks (seconds). Bounded to
///        `[1, MAX_STALENESS_WINDOW]` at construction (IL-8049).
struct ExecutorInitParams {
    bytes32 assetId;
    address manager;
    address admin;
    address rescueGuardian;
    uint256 rescueDelay;
    address balanceProposer;
    address balanceApprover;
    uint256 stalenessMax;
    uint256 bigChangeBps;
    uint256 minUpdateInterval;
    uint256 deploymentTtl;
    uint256 transferStalenessMax;
}

/// @notice A dispatcher deployment request passed from a registered executor to its local factory. The
///         factory binds it into a factory-to-factory ticket.
/// @param executor The requesting executor (must equal `msg.sender` and be locally registered).
/// @param dstChainId The chain the dispatcher must deploy on.
/// @param assetId Chain-independent asset identity (must be enabled on both factories).
/// @param admin Rescue admin propagated to the dispatcher (raw value — the destination factory needs it
///        to CONSTRUCT the dispatcher; the hash alone is one-way and insufficient).
/// @param rescueGuardian Rescue guardian propagated to the dispatcher (raw value).
/// @param rescueDelay Rescue timelock propagated to the dispatcher (raw value).
/// @param immutableParamsHash Keccak binding (admin, guardian, rescueDelay, srcChainId, dstChainId,
///        assetId) — the destination factory verifies it against the raw fields before deploying.
struct DeploymentRequest {
    address executor;
    uint256 dstChainId;
    bytes32 assetId;
    address admin;
    address rescueGuardian;
    uint256 rescueDelay;
    bytes32 immutableParamsHash;
}

/// @title ICrosschainFactory
/// @notice Locked call surface of the crosschain factory. Same address on every chain;
///         creates executors via CREATE3 and dispatchers via authenticated factory-to-factory tickets.
/// @dev First cut: concrete contracts may add methods. Path lookups (`eidOf`/`chainIdOf`) are the
///      frozen source of truth the executor's `registerChain` hard-checks against.
/// @author IPOR Labs
interface ICrosschainFactory {
    /// @notice Configure the linked creation code used by CREATE3. One-time, before any executor or
    /// dispatcher deployment; keeping these blobs in storage avoids embedding them in factory runtime.
    function configureCreationCodes(bytes calldata executorCreationCode_, bytes calldata dispatcherCreationCode_)
        external;

    /// @notice Configure only the executor creation code. This split entrypoint
    /// keeps the mainnet transaction below per-transaction gas limits.
    function configureExecutorCreationCode(bytes calldata executorCreationCode_) external;

    /// @notice Configure only the dispatcher creation code. The factory becomes
    /// ready after both creation-code halves have been configured.
    function configureDispatcherCreationCode(bytes calldata dispatcherCreationCode_) external;

    /// @notice Deterministically create an executor for `msg.sender`. Restricted to the owner's allowed creators
    ///         while `creationRestricted` (the default), since executors spend the factory's shared fee budget.
    /// @param userSalt_ Caller-chosen salt; the CREATE3 salt is `keccak256(msg.sender, userSalt_)`.
    /// @param params_ Immutable executor configuration.
    /// @return executor The deployed executor address.
    function createExecutor(bytes32 userSalt_, ExecutorInitParams calldata params_) external returns (address executor);

    /// @notice Preview the CREATE3 executor address for `creator_`/`userSalt_`.
    /// @param creator_ The account that would call `createExecutor`.
    /// @param userSalt_ The caller-chosen salt.
    /// @return The predicted executor address.
    function computeExecutorAddress(address creator_, bytes32 userSalt_) external view returns (address);

    /// @notice Return every executor created with `manager_` as its immutable manager.
    /// @dev For PlasmaVault integrations, `manager_` is the vault address.
    function executorsOf(address manager_) external view returns (address[] memory);

    /// @notice Begin a dispatcher deployment for a locally registered executor.
    /// @param request_ The bound deployment request.
    /// @return requestId The source-factory-local request id.
    function requestDispatcher(DeploymentRequest calldata request_) external returns (uint256 requestId);

    /// @notice Cancel a stuck pending deployment after its TTL plus
    ///         `DEPLOYMENT_CANCEL_MARGIN` (factory owner, executor or its manager); anyone else only after a
    ///         further `DEPLOYMENT_CANCEL_GRACE`. A later NACK is rejected, but a late DEPLOYMENT_ACK that matches
    ///         the request's ticket still promotes it to DEPLOYED (IL-8649).
    /// @param requestId_ The pending request id.
    function cancelPendingDeployment(uint256 requestId_) external;

    /// @notice The LayerZero endpoint id registered for `chainId_` (frozen path table, §4.1).
    /// @param chainId_ EVM chain id.
    /// @return The endpoint id.
    function eidOf(uint256 chainId_) external view returns (uint32);

    /// @notice The EVM chain id registered for `eid_` (frozen path table, §4.1).
    /// @param eid_ Endpoint id.
    /// @return The chain id.
    function chainIdOf(uint32 eid_) external view returns (uint256);

    /// @notice The local token/pool wiring for an asset id.
    /// @param assetId_ Chain-independent asset identity.
    /// @return localToken The local ERC20 token.
    /// @return localStargatePool The local Stargate pool.
    /// @return enabled Whether the asset is enabled on this chain.
    function assetConfig(bytes32 assetId_)
        external
        view
        returns (address localToken, address localStargatePool, bool enabled);

    // --- Timelocked owner configuration (frozen per asset/path after first use) ---

    /// @notice Schedule an asset (token/pool) configuration for `assetId_`.
    function scheduleAssetConfig(bytes32 assetId_, address localToken_, address localStargatePool_) external;

    /// @notice Execute a previously scheduled asset configuration after the config delay.
    function executeAssetConfig(bytes32 assetId_) external;

    /// @notice Schedule a path (chainId/EID/peer + enforced options) configuration. Reverts
    ///         `PathConfigOptionsInvalid` unless the options of each CREATE_DISPATCHER / ACK / NACK message
    ///         type are exactly one executor `lzReceive` option with bounded gas and no value.
    function schedulePathConfig(uint256 chainId_, uint32 eid_, bytes calldata enforcedOptions_) external;

    /// @notice Execute a previously scheduled path configuration after the config delay.
    function executePathConfig(uint256 chainId_) external;
}
