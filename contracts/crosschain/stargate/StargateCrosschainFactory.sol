// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {CREATE3} from "solady/utils/CREATE3.sol";

import {StargateLzOAppBase} from "./base/StargateLzOAppBase.sol";
import {StargateLzSendLib} from "./lib/StargateLzSendLib.sol";
import {StargateFactoryLib} from "./lib/StargateFactoryLib.sol";
import {IStargateFactoryLibraryAbi} from "./IStargateFactoryLibraryAbi.sol";
import {ICrosschainFactory, ExecutorInitParams, DeploymentRequest} from "../interfaces/ICrosschainFactory.sol";
import {ICrosschainExecutor} from "../interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../lib/CrosschainErrors.sol";
import {MsgType, DeploymentStatus, NackReason, CrosschainConstants} from "../lib/CrosschainConstants.sol";
import {CrosschainMessages, DeploymentTicket, DeploymentAck, DeploymentNack} from "../lib/CrosschainMessages.sol";

/// @notice Minimal view of the propagated deployment TTL read from a requesting executor. The concrete
///         `StargateCrosschainExecutor` exposes `DEPLOYMENT_TTL` as a public immutable getter; the factory reads it
///         at request time, stores it with the pending request and derives the ticket's `expiresAt` and the
///         cancellation window from it. Declared locally
///         because `ICrosschainExecutor` does not surface the TTL and the executor is not modified here.
interface IExecutorDeploymentTtl {
    /// @notice Seconds after which a stuck deployment ticket becomes cancellable.
    function DEPLOYMENT_TTL() external view returns (uint256);
}

/// @title StargateCrosschainFactory
/// @notice Deployment-authorization contract of the crosschain POC. Deployed at the SAME
///         address on every chain (initcode-binding CREATE2) so that CREATE3 addresses are
///         reproducible cross-chain. It creates executors via CREATE3 (creator-bound salt) and, via
///         authenticated factory-to-factory tickets, deploys dispatchers on remote chains at the SAME
///         address as their executor. The factory is the sole authority that can flip a
///         source executor's `hasDispatcher`, and it does so only after recording its OWN deployment
///        : code presence at a predicted address is never proof of authorization.
/// @dev Message-only OApp — inherits `StargateLzOAppBase` (no Stargate value channel, no `lzCompose`). Keeps its
///      owner as the timelocked config custodian — it is NOT renounced. Every constructor
///      argument is a deploy-time-identical constant across chains so the initcode (and therefore the
///      address) is identical everywhere: the LayerZero V2 endpoint is same-address on
///      ETH/ARB, and `(owner, admin, guardian, rescueDelay, configDelay)` are chosen identical in the
///      deploy manifest. The deploy script asserts the pinned initcode hash before deployment.
///
///      POC simplifications a reviewer must know:
///      - Dispatchers are deployed with immutable enforced options for plain-message receipt and Stargate
///        return receive/compose execution. The operator separately sets the factory's own path enforced
///        options via `schedulePathConfig` for the CREATE_DISPATCHER / ACK / NACK sends.
///      - Path "migration" (replacing an already-registered chainId<->EID pair) is out of POC scope: the
///        base `_registerPath` is append-only, so a path is effectively immutable once executed (a
///        timelocked migration is deferred).
///      - Destination validation at deployment time cannot fail: the dispatcher is born with an empty
///        allowlist, so its constructor is destination-state-independent. The deployment-time NACKs are
///        `REJECTED_OCCUPIED` and `TICKET_EXPIRED` (IL-8623).
/// @author IPOR Labs
contract StargateCrosschainFactory is StargateLzOAppBase, ICrosschainFactory, IStargateFactoryLibraryAbi {
    using OptionsBuilder for bytes;

    /// @notice `createExecutor` caller is not an allowed creator while creation is restricted.
    error CreatorNotAllowed(address creator);
    /// @notice The executor used all its CREATE_DISPATCHER attempts for this destination chain.
    error DeploymentAttemptsExhausted(address executor, uint256 dstChainId, uint8 attempts);

    uint128 private constant DISPATCHER_RECEIVE_GAS = 2_000_000;
    uint128 private constant RETURN_ASSET_RECEIVE_GAS = 250_000;
    uint128 private constant RETURN_ASSET_COMPOSE_GAS = 1_500_000;
    // ============================================================
    // Enforced-options keys (per-message-type)
    // ============================================================

    /// @notice Enforced-options key for the source->destination CREATE_DISPATCHER send.
    uint16 public constant CREATE_DISPATCHER_MSG_TYPE = uint16(uint8(MsgType.CREATE_DISPATCHER));

    /// @notice Enforced-options key for the destination->source DEPLOYMENT_ACK send.
    uint16 public constant DEPLOYMENT_ACK_MSG_TYPE = uint16(uint8(MsgType.DEPLOYMENT_ACK));

    /// @notice Enforced-options key for the destination->source DEPLOYMENT_NACK send.
    uint16 public constant DEPLOYMENT_NACK_MSG_TYPE = uint16(uint8(MsgType.DEPLOYMENT_NACK));

    // ============================================================
    // Immutables
    // ============================================================

    /// @notice Timelock (seconds) applied to every asset/path config change. Deploy-time
    ///         identical across chains so it does not perturb the same-address initcode.
    uint256 public immutable CONFIG_DELAY;

    address[2] private _executorCreationCodeStores;
    address[2] private _dispatcherCreationCodeStores;
    uint32 private _executorCreationCodeLength;
    uint32 private _dispatcherCreationCodeLength;
    bytes32 public executorCreationCodeHash;
    bytes32 public dispatcherCreationCodeHash;
    bool public creationCodesConfigured;

    // ============================================================
    // Asset config
    // ============================================================

    /// @notice Local token/pool wiring for a chain-independent asset id.
    /// @param localToken The local ERC20 token resolved for the asset.
    /// @param localStargatePool The local Stargate pool whose `token()` is `localToken`.
    /// @param enabled Whether the asset is enabled on this chain.
    struct AssetConfig {
        address localToken;
        address localStargatePool;
        bool enabled;
    }

    /// @inheritdoc ICrosschainFactory
    mapping(bytes32 assetId => AssetConfig config) public override assetConfig;

    /// @notice A scheduled (not-yet-executed) asset configuration awaiting the config timelock.
    struct ScheduledAsset {
        address localToken;
        address localStargatePool;
        uint64 executableAt;
        bool exists;
    }

    /// @notice Pending scheduled asset configs by asset id.
    mapping(bytes32 assetId => ScheduledAsset scheduled) public scheduledAssetConfig;

    /// @notice A scheduled (not-yet-executed) path configuration awaiting the config timelock.
    struct ScheduledPath {
        uint32 eid;
        uint64 executableAt;
        bool exists;
        bytes enforcedOptions;
    }

    /// @notice Pending scheduled path configs by chain id.
    mapping(uint256 chainId => ScheduledPath scheduled) public scheduledPathConfig;

    /// @notice Whether an asset is permanently frozen: set on the destination when a dispatcher is deployed or
    ///         adopted through this factory, and on the source when an executor is created for it or a deployment
    ///         ACK is received; a NACK never freezes.
    mapping(bytes32 assetId => bool frozen) public assetFrozen;

    /// @notice Whether a path is permanently frozen (a dispatcher has been deployed on that chain).
    mapping(uint256 chainId => bool frozen) public pathFrozen;

    /// @notice Number of pending deployment tickets referencing an asset (blocks its config change).
    mapping(bytes32 assetId => uint256 count) public pendingCountByAsset;

    /// @notice Number of pending deployment tickets targeting a path (blocks its config change).
    mapping(uint256 chainId => uint256 count) public pendingCountByChain;

    /// @notice Per-destination ceiling on the LayerZero native fee an executor of this factory, and the factory's
    ///         own ticket / ACK / NACK sends, may pay for one send to `chainId` (source-chain native token, wei).
    ///         Zero means no send is admitted on that path.
    mapping(uint256 chainId => uint256 maxNativeFee) public maxNativeFee;

    /// @notice Emitted when the owner sets the per-destination native fee ceiling.
    event MaxNativeFeeSet(uint256 chainId, uint256 maxNativeFee);

    /// @notice Maximum CREATE_DISPATCHER tickets one executor may send toward one destination chain without a
    ///         successful deployment ACK or an owner reset.
    uint8 public constant MAX_DEPLOYMENT_ATTEMPTS = 3;

    /// @notice CREATE_DISPATCHER tickets an executor has sent toward a chain since its last ACK or owner reset.
    /// @dev Every ticket's LayerZero fee is paid from this factory's native budget, shared by all tenants. An
    ///      ALPHA could otherwise target a chain where the asset is not enabled (the destination reverts, the
    ///      ticket stays pending), wait out the TTL, let anyone cancel it, and re-request for another full fee,
    ///      without bound (IL-8565 / IL-8605). A NACK or a TTL cancel does NOT reset the counter; a
    ///      DEPLOYMENT_ACK deletes it, and the owner can clear it with `resetDeploymentAttempts`.
    mapping(address executor => mapping(uint256 dstChainId => uint8 attempts)) public deploymentAttempts;

    /// @notice Emitted when the owner clears an executor's attempt counter for a chain.
    event DeploymentAttemptsReset(address executor, uint256 dstChainId);

    // ============================================================
    // Executor registry
    // ============================================================

    /// @notice Whether an address is an executor this factory deployed via CREATE3.
    mapping(address executor => bool isExec) public isExecutor;

    /// @notice The CREATE3 salt (`keccak256(creator, userSalt)`) an executor was deployed with.
    mapping(address executor => bytes32 salt) public saltOf;

    /// @notice Executors grouped by their immutable manager (normally a PlasmaVault).
    mapping(address manager => address[] executors) private _executorsByManager;

    /// @notice Creation is restricted by default because executors can spend the shared factory fee budget.
    bool public creationRestricted = true;
    mapping(address creator => bool allowed) public isAllowedCreator;

    // ============================================================
    // Source-side pending deployments
    // ============================================================

    /// @notice A dispatcher deployment ticket this factory issued and is awaiting an ACK/NACK for.
    /// @param executor The requesting executor (== `msg.sender` at request time == predicted dispatcher).
    /// @param dstChainId The destination chain the dispatcher must deploy on.
    /// @param assetId The chain-independent asset identity.
    /// @param salt The CREATE3 salt (== `saltOf[executor]`).
    /// @param ticketHash The full ticket commitment (`keccak256(abi.encode(DeploymentTicket))`).
    /// @param status Lifecycle status (PENDING -> DEPLOYED / FAILED / CANCELLED / REJECTED_OCCUPIED; a CANCELLED
    ///        request still moves to DEPLOYED on its matching late ACK, IL-8649).
    /// @param createdAt Timestamp the ticket was issued (TTL base).
    /// @param deploymentTtl The TTL read from the executor at request time (cancellation window); at
    ///        least `MIN_DEPLOYMENT_TTL`, checked by `requestDispatcher`.
    struct PendingDeployment {
        address executor;
        uint256 dstChainId;
        bytes32 assetId;
        bytes32 salt;
        bytes32 ticketHash;
        DeploymentStatus status;
        uint64 createdAt;
        uint256 deploymentTtl;
    }

    /// @notice Pending deployments by source-local request id.
    mapping(uint256 requestId => PendingDeployment deployment) public pendingDeployment;

    /// @notice Monotonic source-local request id allocator (ids start at 1).
    uint256 public requestCount;

    // ============================================================
    // Destination-side consumed tickets & own deployments
    // ============================================================

    /// @notice Destination-side status of a consumed ticket, keyed by
    ///         `ticketKey = keccak256(abi.encode(srcEid, sourceFactory, requestId))`.
    /// @param status DEPLOYED (own-deployment ACK) or REJECTED_OCCUPIED (squat NACK); NONE = unseen.
    /// @param ticketHash The full ticket commitment consumed (reuse with different data reverts).
    /// @param dispatcher The dispatcher address the ACK resolved to (zero for a NACK).
    struct ConsumedTicket {
        DeploymentStatus status;
        bytes32 ticketHash;
        address dispatcher;
    }

    /// @notice Consumed ticket records by ticket key.
    mapping(bytes32 ticketKey => ConsumedTicket ticket) public consumedTicket;

    /// @notice The factory's OWN deployment record for a predicted dispatcher address. This is the SOLE
    ///         authority for an ACK: only an address this factory itself deployed (or
    ///         adopts an identical re-request for) may ever be ACKed.
    /// @param deployed Whether this factory deployed a dispatcher at the address.
    /// @param immutableParamsHash The immutable-parameters commitment it was deployed with (adopt guard).
    /// @param ticketKey The ticket key that originally deployed it (audit reference).
    struct OwnDeployment {
        bool deployed;
        bytes32 immutableParamsHash;
        bytes32 ticketKey;
    }

    /// @notice Own deployment records keyed by (predicted == deployed) dispatcher address.
    mapping(address dispatcher => OwnDeployment record) public ownDeployment;

    // ============================================================
    // Events
    // ============================================================

    /// @notice Emitted when an executor is created via CREATE3.
    event ExecutorCreated(address creator, address executor, bytes32 salt, bytes32 assetId);
    /// @notice Emitted when a source factory issues a CREATE_DISPATCHER ticket.
    event DispatcherTicketSent(uint256 requestId, uint256 dstChainId, address executor, bytes32 ticketHash);
    /// @notice Emitted when the destination factory deploys a dispatcher and ACKs it.
    event DispatcherDeployed(bytes32 ticketKey, uint256 requestId, address dispatcher);
    /// @notice Emitted when the destination factory adopts a re-request for a dispatcher it already deployed.
    event DispatcherTicketAdopted(bytes32 ticketKey, uint256 requestId, address dispatcher);
    /// @notice Emitted when the destination factory rejects an occupied predicted address (NACK, never ACK).
    event DispatcherTicketRejectedOccupied(bytes32 ticketKey, uint256 requestId, address predicted);
    /// @notice Emitted when the destination factory answers a ticket delivered at or after its `expiresAt` with a NACK.
    event DispatcherTicketExpired(bytes32 ticketKey, uint256 requestId, uint256 expiresAt);
    /// @notice Emitted on the source when an authenticated ACK flips the executor's dispatcher readiness.
    event DispatcherRequestAcked(uint256 requestId, uint256 dstChainId, address dispatcher);
    /// @notice Emitted after `DispatcherRequestAcked` when the ACK promoted a request that had been CANCELLED.
    event DispatcherRequestLateAcked(uint256 requestId, uint256 dstChainId, address dispatcher);
    /// @notice Emitted on the source when an authenticated NACK fails the request (readiness never flips).
    event DispatcherRequestNacked(uint256 requestId, uint256 dstChainId, uint8 reason);
    /// @notice Emitted when a stuck pending deployment is cancelled after its expiry plus `DEPLOYMENT_CANCEL_MARGIN`;
    ///         a matching late ACK can still promote it (`DispatcherRequestLateAcked`, IL-8649).
    event DispatcherRequestCancelled(uint256 requestId, uint256 dstChainId);
    /// @notice Emitted when an asset config is scheduled.
    event AssetConfigScheduled(bytes32 assetId, address localToken, address localStargatePool, uint256 executableAt);
    /// @notice Emitted when a scheduled asset config is executed.
    event AssetConfigExecuted(bytes32 assetId, address localToken, address localStargatePool);
    /// @notice Emitted when a path config is scheduled.
    event PathConfigScheduled(uint256 chainId, uint32 eid, uint256 executableAt);
    /// @notice Emitted when a scheduled path config is executed (registers the same-address peer).
    event PathConfigExecuted(uint256 chainId, uint32 eid);
    /// @notice Emitted when the owner sweeps native ACK budget.
    event NativeSwept(address to, uint256 amount);
    /// @notice Emitted once both the executor and the dispatcher creation codes are stored.
    event CreationCodesConfigured(bytes32 executorCodeHash, bytes32 dispatcherCodeHash);
    /// @notice Emitted when a creator's `createExecutor` allowance changes (the owner's grant at construction too).
    event CreatorAllowanceUpdated(address creator, bool allowed);
    /// @notice Emitted when the creation restriction flag changes (its initial `true` at construction too).
    event CreationRestrictionUpdated(bool restricted);

    /// @param endpoint_ LayerZero V2 endpoint (same-address across chains). Deploy-time identical constant.
    /// @param owner_ Timelocked config custodian; kept (NOT renounced). Deploy-time identical constant.
    /// @param admin_ Rescue admin (full delayed administrator). Deploy-time identical constant.
    /// @param guardian_ Rescue guardian (veto only), distinct from `admin_`. Deploy-time identical constant.
    /// @param rescueDelay_ Rescue timelock (seconds). Deploy-time identical constant.
    /// @param configDelay_ Asset/path config timelock (seconds); must be at least `CrosschainConstants.MIN_CONFIG_DELAY`
    ///        (IL-8538). Deploy-time identical constant.
    /// @dev All six arguments are deploy-time-identical constants across chains so the initcode — and
    ///      therefore the CREATE2-bound factory address — is identical everywhere.
    constructor(
        address endpoint_,
        address owner_,
        address admin_,
        address guardian_,
        uint256 rescueDelay_,
        uint256 configDelay_
    ) StargateLzOAppBase(endpoint_, owner_, admin_, guardian_, rescueDelay_) {
        if (configDelay_ < CrosschainConstants.MIN_CONFIG_DELAY) {
            revert CrosschainErrors.InvalidConfigDelay(configDelay_, CrosschainConstants.MIN_CONFIG_DELAY);
        }
        CONFIG_DELAY = configDelay_;
        isAllowedCreator[owner_] = true;
        emit CreatorAllowanceUpdated(owner_, true);
        emit CreationRestrictionUpdated(true);
    }

    /// @notice Turn the `createExecutor` creator allowlist on or off. Immediate, owner-only.
    /// @param restricted_ True to admit only allowed creators.
    function setCreationRestricted(bool restricted_) external onlyOwner {
        creationRestricted = restricted_;
        emit CreationRestrictionUpdated(restricted_);
    }

    /// @notice Grant or revoke a creator's right to call `createExecutor` while creation is restricted. Immediate,
    ///         owner-only.
    /// @param creator_ The creator account.
    /// @param allowed_ Whether it may create executors.
    function setCreatorAllowed(address creator_, bool allowed_) external onlyOwner {
        isAllowedCreator[creator_] = allowed_;
        emit CreatorAllowanceUpdated(creator_, allowed_);
    }

    /// @inheritdoc ICrosschainFactory
    function configureCreationCodes(bytes calldata executorCreationCode_, bytes calldata dispatcherCreationCode_)
        external
        override
        onlyOwner
    {
        if (creationCodesConfigured) revert CrosschainErrors.CreationCodesAlreadyConfigured();
        _configureExecutorCreationCode(executorCreationCode_);
        _configureDispatcherCreationCode(dispatcherCreationCode_);
    }

    /// @inheritdoc ICrosschainFactory
    function configureExecutorCreationCode(bytes calldata executorCreationCode_) external override onlyOwner {
        if (creationCodesConfigured || _executorCreationCodeLength != 0) {
            revert CrosschainErrors.CreationCodesAlreadyConfigured();
        }
        _configureExecutorCreationCode(executorCreationCode_);
    }

    /// @inheritdoc ICrosschainFactory
    function configureDispatcherCreationCode(bytes calldata dispatcherCreationCode_) external override onlyOwner {
        if (creationCodesConfigured || _dispatcherCreationCodeLength != 0) {
            revert CrosschainErrors.CreationCodesAlreadyConfigured();
        }
        _configureDispatcherCreationCode(dispatcherCreationCode_);
    }

    function _configureExecutorCreationCode(bytes calldata executorCreationCode_) private {
        _executorCreationCodeLength = _storeCreationCode(executorCreationCode_, _executorCreationCodeStores);
        executorCreationCodeHash = keccak256(executorCreationCode_);
        _finishCreationCodeConfiguration();
    }

    function _configureDispatcherCreationCode(bytes calldata dispatcherCreationCode_) private {
        _dispatcherCreationCodeLength = _storeCreationCode(dispatcherCreationCode_, _dispatcherCreationCodeStores);
        dispatcherCreationCodeHash = keccak256(dispatcherCreationCode_);
        _finishCreationCodeConfiguration();
    }

    function _finishCreationCodeConfiguration() private {
        if (_executorCreationCodeLength != 0 && _dispatcherCreationCodeLength != 0) {
            creationCodesConfigured = true;
            emit CreationCodesConfigured(executorCreationCodeHash, dispatcherCreationCodeHash);
        }
    }

    // ============================================================
    // Executor creation (allowlisted creators while `creationRestricted`)
    // ============================================================

    /// @inheritdoc ICrosschainFactory
    function createExecutor(bytes32 userSalt_, ExecutorInitParams calldata params_)
        external
        override
        nonReentrant
        returns (address executor)
    {
        if (creationRestricted && !isAllowedCreator[msg.sender]) revert CreatorNotAllowed(msg.sender);
        AssetConfig memory cfg = assetConfig[params_.assetId];
        if (!cfg.enabled) revert CrosschainErrors.AssetConfigNotEnabled(params_.assetId);
        assetFrozen[params_.assetId] = true;

        // Creator-bound salt prevents address squatting/frontrunning of someone else's planned executor
        //. The executor address is `f(salt, deployer=factory)` and is independent of initcode.
        bytes32 salt = keccak256(abi.encode(msg.sender, userSalt_));

        // The factory is injected as an EXPLICIT constructor arg (`address(this)`): CREATE3 deploys through
        // an ephemeral proxy, so `msg.sender` in the executor constructor would be that proxy, not us. This
        // does not affect the CREATE3 address (salt + deployer only).
        bytes memory creationCode = abi.encodePacked(
            _configuredCreationCode(_executorCreationCodeStores, _executorCreationCodeLength),
            abi.encode(
                address(endpoint), cfg.localToken, cfg.localStargatePool, params_.assetId, address(this), params_
            )
        );
        executor = CREATE3.deploy(salt, creationCode, 0);

        isExecutor[executor] = true;
        saltOf[executor] = salt;
        _executorsByManager[params_.manager].push(executor);
        emit ExecutorCreated(msg.sender, executor, salt, params_.assetId);
    }

    /// @inheritdoc ICrosschainFactory
    function computeExecutorAddress(address creator_, bytes32 userSalt_) external view override returns (address) {
        return CREATE3.getDeployed(keccak256(abi.encode(creator_, userSalt_)), address(this));
    }

    /// @inheritdoc ICrosschainFactory
    function executorsOf(address manager_) external view override returns (address[] memory) {
        return _executorsByManager[manager_];
    }

    // ============================================================
    // Dispatcher deployment request (registered executor only)
    // ============================================================

    /// @inheritdoc ICrosschainFactory
    function requestDispatcher(DeploymentRequest calldata request_)
        external
        override
        nonReentrant
        returns (uint256 requestId)
    {
        if (!isExecutor[msg.sender]) revert CrosschainErrors.NotRegisteredExecutor(msg.sender);
        if (msg.sender != request_.executor) {
            revert CrosschainErrors.ExecutorRequestMismatch(msg.sender, request_.executor);
        }

        uint256 dstChainId = request_.dstChainId;
        // Destination path must be registered so the ticket can be sent (and its ACK returned). `eidOf`
        // reverts on an unknown chain.
        eidOf(dstChainId);
        if (!assetConfig[request_.assetId].enabled) revert CrosschainErrors.AssetConfigNotEnabled(request_.assetId);

        // The factory relies on the stored TTL for its cancellation gate and does not trust the executor
        // build it latched to have bounded it: a TTL below `MIN_DEPLOYMENT_TTL` would let request and
        // cancel run in one block and spend the native budget per iteration (IL-8069). Only the floor is
        // checked here; the ceiling protects factory configuration, not the budget, and is enforced by the
        // executor constructor (IL-8049).
        uint256 deploymentTtl = IExecutorDeploymentTtl(msg.sender).DEPLOYMENT_TTL();
        if (deploymentTtl < CrosschainConstants.MIN_DEPLOYMENT_TTL) {
            revert CrosschainErrors.InvalidDeploymentTtl(
                deploymentTtl, CrosschainConstants.MIN_DEPLOYMENT_TTL, CrosschainConstants.MAX_DEPLOYMENT_TTL
            );
        }

        // Verify the immutable-parameters commitment against its raw fields BEFORE binding the ticket.
        // The factory runs on the source chain, so `block.chainid` is the executor's chain and
        // this reconstruction is identical to the one the executor builds in `StargateExecutorDeploymentLib.request`.
        _requireImmutableParamsHash(
            request_.admin,
            request_.rescueGuardian,
            request_.rescueDelay,
            block.chainid,
            dstChainId,
            request_.assetId,
            request_.immutableParamsHash
        );

        // Bound the factory-funded fees one executor can burn per chain (IL-8565 / IL-8605); counted before
        // the send, never reset by a NACK or a cancel.
        uint8 attempts = deploymentAttempts[msg.sender][dstChainId];
        if (attempts >= MAX_DEPLOYMENT_ATTEMPTS) {
            revert DeploymentAttemptsExhausted(msg.sender, dstChainId, attempts);
        }
        deploymentAttempts[msg.sender][dstChainId] = attempts + 1;

        bytes32 salt = saltOf[msg.sender];
        requestId = ++requestCount;

        DeploymentTicket memory ticket = DeploymentTicket({
            requestId: requestId,
            salt: salt,
            executor: msg.sender, // == predicted dispatcher address (same-address CREATE3)
            srcChainId: block.chainid,
            dstChainId: dstChainId,
            assetId: request_.assetId,
            admin: request_.admin,
            guardian: request_.rescueGuardian,
            rescueDelay: request_.rescueDelay,
            immutableParamsHash: request_.immutableParamsHash,
            expiresAt: block.timestamp + deploymentTtl
        });
        bytes32 ticketHash = keccak256(abi.encode(ticket));

        pendingDeployment[requestId] = PendingDeployment({
            executor: msg.sender,
            dstChainId: dstChainId,
            assetId: request_.assetId,
            salt: salt,
            ticketHash: ticketHash,
            status: DeploymentStatus.PENDING,
            createdAt: SafeCast.toUint64(block.timestamp),
            deploymentTtl: deploymentTtl
        });
        // Freeze config while this ticket is in flight.
        unchecked {
            ++pendingCountByAsset[request_.assetId];
            ++pendingCountByChain[dstChainId];
        }

        bytes memory payload = CrosschainMessages.encodeDeploymentTicket(ticket);
        _sendLzMessage(dstChainId, payload, CREATE_DISPATCHER_MSG_TYPE, "");
        emit DispatcherTicketSent(requestId, dstChainId, msg.sender, ticketHash);
    }

    /// @inheritdoc ICrosschainFactory
    /// @dev The factory owner, the executor and its manager may cancel once the ticket's expiry plus
    ///      `DEPLOYMENT_CANCEL_MARGIN` has passed; everyone else after `DEPLOYMENT_CANCEL_GRACE` more (IL-8649),
    ///      like `CcipCrosschainFactory.cancelExpiredDeployment`. The ticket carries the absolute `expiresAt`
    ///      (`createdAt + deploymentTtl`) and the destination NACKs it from then on, so a ticket cancelled here can
    ///      no longer be deployed by a late delivery (IL-8623); the margin covers a destination clock that lags
    ///      this one.
    ///      The pending counters freeze asset and path config factory-wide, so a stuck ticket must not depend on
    ///      its executor's manager: a PlasmaVault whose crosschain NAV is fail-closed cannot reach
    ///      `cancelDispatcherRequest` through `execute()` (IL-8259), hence the permissionless fallback after the
    ///      grace. Nobody can cancel earlier than the executor could. A cancelled request keeps its ticket hash and
    ///      executor, so a DEPLOYMENT_ACK that arrives (or is retried) afterwards is still accepted, see
    ///      `_onDeploymentAck`.
    function cancelPendingDeployment(uint256 requestId_) external override nonReentrant {
        PendingDeployment storage pd = pendingDeployment[requestId_];
        if (pd.status != DeploymentStatus.PENDING) revert CrosschainErrors.DeploymentNotPending(requestId_);

        uint256 executableAt = uint256(pd.createdAt) + pd.deploymentTtl + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        // Exclusive grace for the factory owner and the executor's manager (IL-8649): they may cancel from
        // `executableAt`, everyone else only after `DEPLOYMENT_CANCEL_GRACE` more.
        // The executor's own `cancelDispatcherRequest` (manager-gated) reaches this function as the executor.
        address executor = pd.executor;
        if (msg.sender != owner() && msg.sender != executor && msg.sender != ICrosschainExecutor(executor).MANAGER()) {
            executableAt += CrosschainConstants.DEPLOYMENT_CANCEL_GRACE;
        }
        if (block.timestamp < executableAt) {
            revert CrosschainErrors.DeploymentTtlNotElapsed(requestId_, block.timestamp, executableAt);
        }

        pd.status = DeploymentStatus.CANCELLED;
        _releasePending(pd); // re-open config
        // A later NACK is rejected; an ACK matching this ticket is still accepted (IL-8649), see _onDeploymentAck.
        ICrosschainExecutor(pd.executor).onDispatcherRequestCancelled(requestId_);
        emit DispatcherRequestCancelled(requestId_, pd.dstChainId);
    }

    // ============================================================
    // Timelocked owner configuration (frozen per asset/path after first use)
    // ============================================================

    /// @inheritdoc ICrosschainFactory
    function scheduleAssetConfig(bytes32 assetId_, address localToken_, address localStargatePool_)
        external
        override
        onlyOwner
    {
        _requireAssetMutable(assetId_);
        _validateAssetConfig(localToken_, localStargatePool_);

        uint64 executableAt = _configExecutableAt();
        scheduledAssetConfig[assetId_] = ScheduledAsset({
            localToken: localToken_, localStargatePool: localStargatePool_, executableAt: executableAt, exists: true
        });
        emit AssetConfigScheduled(assetId_, localToken_, localStargatePool_, executableAt);
    }

    /// @inheritdoc ICrosschainFactory
    function executeAssetConfig(bytes32 assetId_) external override onlyOwner {
        ScheduledAsset memory sa = scheduledAssetConfig[assetId_];
        _requireScheduledAndElapsed(sa.exists, sa.executableAt);
        _requireAssetMutable(assetId_);
        // Re-validate at execute: token/pool state could have changed during the timelock window.
        _validateAssetConfig(sa.localToken, sa.localStargatePool);

        assetConfig[assetId_] =
            AssetConfig({localToken: sa.localToken, localStargatePool: sa.localStargatePool, enabled: true});
        delete scheduledAssetConfig[assetId_];
        emit AssetConfigExecuted(assetId_, sa.localToken, sa.localStargatePool);
    }

    /// @inheritdoc ICrosschainFactory
    function schedulePathConfig(uint256 chainId_, uint32 eid_, bytes calldata enforcedOptions_)
        external
        override
        onlyOwner
    {
        _requirePathMutable(chainId_);
        // Early shape feedback plus the path options check (IL-8296); the authoritative bijection/peer
        // checks run in `_registerPath` on execute.
        StargateLzSendLib.validatePathSchedule(chainId_, eid_, enforcedOptions_);

        uint64 executableAt = _configExecutableAt();
        scheduledPathConfig[chainId_] =
            ScheduledPath({eid: eid_, executableAt: executableAt, exists: true, enforcedOptions: enforcedOptions_});
        emit PathConfigScheduled(chainId_, eid_, executableAt);
    }

    /// @inheritdoc ICrosschainFactory
    function executePathConfig(uint256 chainId_) external override onlyOwner {
        ScheduledPath memory sp = scheduledPathConfig[chainId_];
        _requireScheduledAndElapsed(sp.exists, sp.executableAt);
        _requirePathMutable(chainId_);

        delete scheduledPathConfig[chainId_];
        // Append-only bijection + same-address peer + enforced-options validation (base).
        _registerPath(chainId_, sp.eid, sp.enforcedOptions);
        emit PathConfigExecuted(chainId_, sp.eid);
    }

    /// @notice Sweep native ACK budget the owner previously funded.
    /// @param to_ The recipient.
    /// @param amount_ The amount of native to sweep.
    function sweepNative(address payable to_, uint256 amount_) external onlyOwner nonReentrant {
        if (to_ == address(0)) revert CrosschainErrors.ZeroAddress();
        (bool ok,) = to_.call{value: amount_}("");
        if (!ok) revert CrosschainErrors.RescueCallFailed();
        emit NativeSwept(to_, amount_);
    }

    /// @notice Set the per-destination native fee ceiling read by every executor send and by the factory's own
    ///         ticket / ACK / NACK sends (see `StargateNativeFeeCapLib`). Immediate,
    ///         owner-only; no path-registration guard on purpose: a ceiling for an unregistered chain is inert,
    ///         because a send to it already reverts `UnknownChain` before any quote.
    /// @param chainId_ The destination chain id.
    /// @param maxNativeFee_ The new ceiling, in source-chain native token wei. Zero admits no send on that
    ///        path; set it before the first `createDispatcher` for that chain — the deployment ACK's callback
    ///        already sends the initial `UPDATE_VAULTS` through the ceiling, and an ACK rejected this way stays
    ///        retryable once the ceiling is raised.
    function setMaxNativeFee(uint256 chainId_, uint256 maxNativeFee_) external onlyOwner {
        maxNativeFee[chainId_] = maxNativeFee_;
        emit MaxNativeFeeSet(chainId_, maxNativeFee_);
    }

    /// @notice Clear an executor's CREATE_DISPATCHER attempt counter for a chain (IL-8565 / IL-8605). Immediate,
    ///         owner-only, not timelocked: it only re-opens spending of the owner's own fee budget.
    /// @param executor_ The executor whose counter is cleared.
    /// @param dstChainId_ The destination chain id.
    function resetDeploymentAttempts(address executor_, uint256 dstChainId_) external onlyOwner {
        delete deploymentAttempts[executor_][dstChainId_];
        emit DeploymentAttemptsReset(executor_, dstChainId_);
    }

    // ============================================================
    // Path lookups (frozen source of truth for executor `registerChain`)
    // ============================================================

    /// @inheritdoc ICrosschainFactory
    function eidOf(uint256 chainId_) public view override(StargateLzOAppBase, ICrosschainFactory) returns (uint32) {
        return super.eidOf(chainId_);
    }

    /// @inheritdoc ICrosschainFactory
    function chainIdOf(uint32 eid_) public view override(StargateLzOAppBase, ICrosschainFactory) returns (uint256) {
        return super.chainIdOf(eid_);
    }

    // ============================================================
    // Inbound message dispatch (factory-to-factory, peer already authenticated by the base)
    // ============================================================

    /// @notice Handle a decoded, authenticated inbound factory-to-factory message.
    /// @dev The base (`OAppReceiver` + `StargateLzOAppBase`) has already verified endpoint + same-address peer and
    ///      mapped `origin_.srcEid -> srcChainId_`. Routes the three factory message types.
    function _handleLzMessage(MsgType msgType_, uint256 srcChainId_, Origin calldata origin_, bytes memory data_)
        internal
        override
    {
        if (msgType_ == MsgType.CREATE_DISPATCHER) {
            _onCreateDispatcher(srcChainId_, origin_, CrosschainMessages.decodeDeploymentTicket(data_));
        } else if (msgType_ == MsgType.DEPLOYMENT_ACK) {
            _onDeploymentAck(srcChainId_, CrosschainMessages.decodeDeploymentAck(data_));
        } else if (msgType_ == MsgType.DEPLOYMENT_NACK) {
            _onDeploymentNack(srcChainId_, CrosschainMessages.decodeDeploymentNack(data_));
        } else {
            revert CrosschainErrors.UnexpectedMessageType(uint8(msgType_));
        }
    }

    // ============================================================
    // Destination: CREATE_DISPATCHER handler (three exhaustive idempotency cases)
    // ============================================================

    /// @dev Deploys a dispatcher (or replays the prior outcome) for an authenticated ticket. Structural
    ///      invariants revert (LZ retains the packet; the source can TTL-cancel); the deployment-time NACKs are
    ///      `REJECTED_OCCUPIED` and `TICKET_EXPIRED` (IL-8623). An ACK is sent ONLY after this factory's own
    ///      recorded deployment (or its adoption of an identical re-request).
    function _onCreateDispatcher(uint256 srcChainId_, Origin calldata origin_, DeploymentTicket memory ticket_)
        private
    {
        // --- Structural invariants (deterministic; retrying without config changes cannot help) ---
        if (block.chainid != ticket_.dstChainId) {
            revert CrosschainErrors.TicketWrongDestinationChain(ticket_.dstChainId, block.chainid);
        }
        // Bind the ticket's claimed source chain to the real delivery source (the base mapped the EID).
        if (srcChainId_ != ticket_.srcChainId) {
            revert CrosschainErrors.TicketSourceChainMismatch(ticket_.srcChainId, srcChainId_);
        }
        // Verify the propagated raw admin/guardian/rescueDelay commit to `immutableParamsHash` before they
        // are used to CONSTRUCT the dispatcher: the hash alone is one-way and insufficient.
        _requireImmutableParamsHash(
            ticket_.admin,
            ticket_.guardian,
            ticket_.rescueDelay,
            ticket_.srcChainId,
            ticket_.dstChainId,
            ticket_.assetId,
            ticket_.immutableParamsHash
        );
        // Sanity bound on the source-set expiry (IL-8623): no source accepts a TTL above `MAX_DEPLOYMENT_TTL`, so a
        // larger `expiresAt` is a longer foreign layout read through this one, or this chain's clock lagging the
        // source's beyond `DEPLOYMENT_CANCEL_MARGIN`. Revert (retryable) rather than NACK or deploy.
        uint256 maxExpiresAt =
            block.timestamp + CrosschainConstants.MAX_DEPLOYMENT_TTL + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        if (ticket_.expiresAt > maxExpiresAt) {
            revert CrosschainErrors.TicketExpiryOutOfRange(ticket_.expiresAt, maxExpiresAt);
        }
        // This function freezes the asset only on deploy/adopt below; a NACK never freezes.
        // The predicted address is `f(salt, deployer=factory)`; the factory is same-address on every chain,
        // so it must equal the ticket's executor (== the dispatcher's target address).
        address predicted = CREATE3.getDeployed(ticket_.salt, address(this));
        if (predicted != ticket_.executor) {
            revert CrosschainErrors.TicketAddressMismatch(ticket_.executor, predicted);
        }

        bytes32 ticketHash = keccak256(abi.encode(ticket_));
        // `ticketKey` namespaces the ticket by (srcEid, sourceFactory, requestId): a bare requestId is
        // never globally unique across independent source factories.
        bytes32 ticketKey = keccak256(abi.encode(origin_.srcEid, origin_.sender, ticket_.requestId));

        ConsumedTicket storage ct = consumedTicket[ticketKey];
        if (ct.status != DeploymentStatus.NONE) {
            // Same ticketKey re-delivered. Reuse with DIFFERENT data reverts.
            if (ct.ticketHash != ticketHash) revert CrosschainErrors.TicketReplayMismatch(ct.ticketHash, ticketHash);
            if (ct.status == DeploymentStatus.DEPLOYED) {
                // Case (a): identical ticket, own deployment recorded -> re-send the SAME ACK.
                _sendDeploymentAck(ticket_, ticketHash, ct.dispatcher);
            } else {
                // Previously REJECTED_OCCUPIED -> re-send the SAME NACK (never an ACK).
                _sendDeploymentNack(ticket_, ticketHash, NackReason.REJECTED_OCCUPIED);
            }
            return;
        }

        // Absolute expiry (IL-8623): the source factory cancels a ticket only `DEPLOYMENT_CANCEL_MARGIN` after
        // `expiresAt`, so a ticket delivered from `expiresAt` on is never deployed here. Answer a NACK that the
        // source consumes (PENDING -> FAILED, releasing the config freeze) instead of reverting, which would
        // leave a packet that stays executable by anyone. Nothing is recorded: time only moves forward, so a
        // re-delivery is expired again. An already consumed ticket is replayed above, before this check.
        if (block.timestamp >= ticket_.expiresAt) {
            _sendDeploymentNack(ticket_, ticketHash, NackReason.TICKET_EXPIRED);
            emit DispatcherTicketExpired(ticketKey, ticket_.requestId, ticket_.expiresAt);
            return;
        }

        OwnDeployment storage od = ownDeployment[predicted];
        if (od.deployed) {
            // Case (b): a NEW ticketKey whose predicted address THIS factory already deployed (recovery
            // after a cancelled/lost ACK) -> ADOPT if the immutable commitment matches, then ACK.
            if (od.immutableParamsHash != ticket_.immutableParamsHash) {
                revert CrosschainErrors.TicketAdoptionCommitmentMismatch(
                    od.immutableParamsHash, ticket_.immutableParamsHash
                );
            }
            ct.status = DeploymentStatus.DEPLOYED;
            ct.ticketHash = ticketHash;
            ct.dispatcher = predicted;
            // Already frozen by the first deployment; kept explicit as the invariant.
            assetFrozen[ticket_.assetId] = true;
            _sendDeploymentAck(ticket_, ticketHash, predicted);
            emit DispatcherTicketAdopted(ticketKey, ticket_.requestId, predicted);
            return;
        }

        if (predicted.code.length != 0) {
            // Case (c): code present with NO own deployment record -> the address was occupied by something
            // this factory never deployed (only the executor's creator can squat it). Permanent
            // REJECTED_OCCUPIED + NACK, NEVER an ACK. This keeps squatting a single-chain
            // DoS: `hasDispatcher` can never flip toward code we did not deploy.
            ct.status = DeploymentStatus.REJECTED_OCCUPIED;
            ct.ticketHash = ticketHash;
            _sendDeploymentNack(ticket_, ticketHash, NackReason.REJECTED_OCCUPIED);
            emit DispatcherTicketRejectedOccupied(ticketKey, ticket_.requestId, predicted);
            return;
        }

        // --- First deployment: address empty, no record. Deploy the dispatcher (empty allowlist). ---
        // A deployment freezes the asset, which would make a scheduled `executeAssetConfig` revert for good:
        // wait (revert, retryable) until the owner's migration has executed. Adoption above needs no such guard,
        // the asset is already frozen, and the gate is skipped once it is.
        // A frozen asset cannot be migrated (no cancel, `scheduleAssetConfig` reverts), so a stale schedule on it
        // must not block deployments for good.
        if (!assetFrozen[ticket_.assetId] && scheduledAssetConfig[ticket_.assetId].exists) {
            revert CrosschainErrors.DestinationAssetMigrationScheduled(ticket_.assetId);
        }
        address dispatcher = _deployDispatcher(ticket_); // == predicted (reverts if the asset is not enabled)
        // Freeze the destination-local token/pool now that a dispatcher is bound to it.
        assetFrozen[ticket_.assetId] = true;

        od.deployed = true;
        od.immutableParamsHash = ticket_.immutableParamsHash;
        od.ticketKey = ticketKey;

        ct.status = DeploymentStatus.DEPLOYED;
        ct.ticketHash = ticketHash;
        ct.dispatcher = dispatcher;

        _sendDeploymentAck(ticket_, ticketHash, dispatcher);
        emit DispatcherDeployed(ticketKey, ticket_.requestId, dispatcher);
    }

    // ============================================================
    // Source: ACK / NACK handlers
    // ============================================================

    /// @dev Match an authenticated ACK against an unconsumed pending ticket, flip readiness on the executor.
    ///      The executor callback auto-sends the initial `UPDATE_VAULTS`; if it reverts (e.g. unfunded
    ///      native budget) the whole `_lzReceive` reverts and the ACK is retried — NOT caught: a catch would also
    ///      discard the executor's `markReady`, and the executor cannot yet record "initial UPDATE_VAULTS pending".
    function _onDeploymentAck(uint256 srcChainId_, DeploymentAck memory ack_) private {
        PendingDeployment storage pd = pendingDeployment[ack_.requestId];
        // A CANCELLED request still accepts the ACK that matches its ticket (IL-8649): the cancel does not reach
        // the destination, so the dispatcher may exist and its ACK may still be retained by LayerZero. The pending
        // counters were released at cancel and are not touched again. The executor's `onDispatcherCreated` still
        // refuses a late ACK once a newer request or a dispatcher decided the chain, which reverts this delivery.
        bool late = pd.status == DeploymentStatus.CANCELLED;
        if (pd.status != DeploymentStatus.PENDING && !late) {
            revert CrosschainErrors.DeploymentNotPending(ack_.requestId);
        }
        _requireReceiptChain(pd, srcChainId_);
        // Bind the ACK's own `dstChainId` field to the pending destination too (§8 P3 item 1): the ticket
        // hash already commits it, but an explicit check gives a precise diagnostic and defense in depth.
        if (ack_.dstChainId != pd.dstChainId) {
            revert CrosschainErrors.DeploymentAckChainMismatch(pd.dstChainId, ack_.dstChainId);
        }
        _requireTicketHash(pd, ack_.ticketHash);
        // The dispatcher must land at the executor's address (same-address model).
        if (ack_.dispatcher != pd.executor) {
            revert CrosschainErrors.DispatcherAddressMismatch(pd.executor, ack_.dispatcher);
        }

        pd.status = DeploymentStatus.DEPLOYED;
        if (!late) _releasePending(pd);
        // Permanently freeze the asset/path this dispatcher was deployed through.
        assetFrozen[pd.assetId] = true;
        pathFrozen[pd.dstChainId] = true;
        delete deploymentAttempts[pd.executor][pd.dstChainId];

        ICrosschainExecutor(pd.executor).onDispatcherCreated(ack_.requestId, pd.dstChainId, ack_.dispatcher);
        emit DispatcherRequestAcked(ack_.requestId, pd.dstChainId, ack_.dispatcher);
        if (late) emit DispatcherRequestLateAcked(ack_.requestId, pd.dstChainId, ack_.dispatcher);
    }

    /// @dev Match an authenticated NACK; mark the request failed and clear it WITHOUT flipping readiness
    ///      (`hasDispatcher` never flips on a NACK). Receipts for non-pending tickets reject.
    function _onDeploymentNack(uint256 srcChainId_, DeploymentNack memory nack_) private {
        PendingDeployment storage pd = pendingDeployment[nack_.requestId];
        if (pd.status != DeploymentStatus.PENDING) revert CrosschainErrors.DeploymentNotPending(nack_.requestId);
        _requireReceiptChain(pd, srcChainId_);
        _requireTicketHash(pd, nack_.ticketHash);

        // Reject a NACK whose reason is not a known `NackReason` rather than mapping every unrecognized
        // value to a generic FAILED (§8 P3 item 2). Only the three destination-side reasons are valid.
        if (
            nack_.reason != uint8(NackReason.REJECTED_OCCUPIED)
                && nack_.reason != uint8(NackReason.DESTINATION_VALIDATION)
                && nack_.reason != uint8(NackReason.TICKET_EXPIRED)
        ) {
            revert CrosschainErrors.InvalidNackReason(nack_.reason);
        }
        pd.status = (nack_.reason == uint8(NackReason.REJECTED_OCCUPIED))
            ? DeploymentStatus.REJECTED_OCCUPIED
            : DeploymentStatus.FAILED;
        _releasePending(pd); // re-open config; do NOT freeze on a NACK
        ICrosschainExecutor(pd.executor).onDispatcherRequestFailed(nack_.requestId);
        emit DispatcherRequestNacked(nack_.requestId, pd.dstChainId, nack_.reason);
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    /// @dev Deploy the dispatcher for a ticket via CREATE3 (empty allowlist + immutable receive/compose
    ///      enforced options). Isolated into its own stack frame (the 11-argument
    ///      constructor encode is heavy).
    ///      Resolves the DESTINATION-local token/pool from the ticket's asset id; `factory` is injected as
    ///      `address(this)` (the dispatcher reads it from this arg, not `msg.sender` == the CREATE3 proxy).
    function _deployDispatcher(DeploymentTicket memory ticket_) private returns (address dispatcher) {
        AssetConfig memory cfg = assetConfig[ticket_.assetId];
        if (!cfg.enabled) revert CrosschainErrors.AssetConfigNotEnabled(ticket_.assetId);

        // `eidOf` cannot revert here: `srcChainId_ == ticket_.srcChainId` was checked and the base only
        // reached us after mapping `origin_.srcEid -> srcChainId_`, so the source path is registered.
        uint32 executorEid = eidOf(ticket_.srcChainId);

        EnforcedOptionParam[] memory dispatcherOptions = new EnforcedOptionParam[](2);
        dispatcherOptions[0] = EnforcedOptionParam({
            eid: executorEid,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(DISPATCHER_RECEIVE_GAS, 0)
        });
        dispatcherOptions[1] = EnforcedOptionParam({
            eid: executorEid,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(RETURN_ASSET_RECEIVE_GAS, 0)
                .addExecutorLzComposeOption(0, RETURN_ASSET_COMPOSE_GAS, 0)
        });
        bytes memory creationCode = abi.encodePacked(
            _configuredCreationCode(_dispatcherCreationCodeStores, _dispatcherCreationCodeLength),
            abi.encode(
                address(endpoint),
                cfg.localToken,
                cfg.localStargatePool,
                ticket_.assetId,
                address(this),
                ticket_.admin,
                ticket_.guardian,
                ticket_.rescueDelay,
                ticket_.srcChainId, // executorChainId
                executorEid,
                abi.encode(dispatcherOptions)
            )
        );
        dispatcher = CREATE3.deploy(ticket_.salt, creationCode, 0);
    }

    /// @dev Send an authenticated ACK back to the source factory chain.
    function _sendDeploymentAck(DeploymentTicket memory ticket_, bytes32 ticketHash_, address dispatcher_) private {
        bytes memory payload = CrosschainMessages.encodeDeploymentAck(
            DeploymentAck({
                requestId: ticket_.requestId,
                ticketHash: ticketHash_,
                dispatcher: dispatcher_,
                dstChainId: ticket_.dstChainId
            })
        );
        _sendLzMessage(ticket_.srcChainId, payload, DEPLOYMENT_ACK_MSG_TYPE, "");
    }

    /// @dev Send an authenticated NACK back to the source factory chain.
    function _sendDeploymentNack(DeploymentTicket memory ticket_, bytes32 ticketHash_, NackReason reason_) private {
        bytes memory payload = CrosschainMessages.encodeDeploymentNack(
            DeploymentNack({requestId: ticket_.requestId, ticketHash: ticketHash_, reason: uint8(reason_)})
        );
        _sendLzMessage(ticket_.srcChainId, payload, DEPLOYMENT_NACK_MSG_TYPE, "");
    }

    /// @dev Decrement the pending config-freeze counters for a resolved ticket (ACK / NACK / cancel).
    function _releasePending(PendingDeployment storage pd_) private {
        uint256 a = pendingCountByAsset[pd_.assetId];
        if (a != 0) {
            unchecked {
                pendingCountByAsset[pd_.assetId] = a - 1;
            }
        }
        uint256 c = pendingCountByChain[pd_.dstChainId];
        if (c != 0) {
            unchecked {
                pendingCountByChain[pd_.dstChainId] = c - 1;
            }
        }
    }

    /// @dev Validate an asset's token/pool relationship: non-zero, real code, the pool's
    ///      `token()` equals the token, and local decimals are not below the pool's shared decimals. Body in the
    ///      linked `StargateFactoryLib` (EIP-170).
    function _validateAssetConfig(address token_, address pool_) private view {
        StargateFactoryLib.validateAssetConfig(token_, pool_);
    }

    function _writeCreationCode(bytes calldata creationCode_, address[2] storage stores_) private {
        StargateFactoryLib.writeCreationCode(creationCode_, stores_);
    }

    function _readCreationCode(address[2] storage stores_, uint256 totalLength_)
        private
        view
        returns (bytes memory creationCode)
    {
        creationCode = new bytes(totalLength_);
        uint256 copied;
        for (uint256 i; i < 2 && copied < totalLength_; ++i) {
            address store = stores_[i];
            uint256 size = store.code.length - 1;
            if (size > totalLength_ - copied) size = totalLength_ - copied;
            assembly ("memory-safe") {
                extcodecopy(store, add(add(creationCode, 0x20), copied), 1, size)
            }
            copied += size;
        }
    }

    /// @dev Frozen / pending-ticket guard shared by `schedulePathConfig` / `executePathConfig`.
    function _requirePathMutable(uint256 chainId_) private view {
        if (pathFrozen[chainId_]) revert CrosschainErrors.PathConfigFrozen(chainId_);
        if (pendingCountByChain[chainId_] != 0) revert CrosschainErrors.ConfigChangeWhilePendingTicket();
    }

    /// @dev Frozen / pending-ticket guard shared by `scheduleAssetConfig` / `executeAssetConfig`.
    function _requireAssetMutable(bytes32 assetId_) private view {
        if (assetFrozen[assetId_]) revert CrosschainErrors.AssetConfigFrozen(assetId_);
        if (pendingCountByAsset[assetId_] != 0) revert CrosschainErrors.ConfigChangeWhilePendingTicket();
    }

    /// @dev Schedule-exists and timelock guard shared by the two `execute*Config` functions.
    function _requireScheduledAndElapsed(bool exists_, uint64 executableAt_) private view {
        if (!exists_) revert CrosschainErrors.ConfigNotScheduled();
        if (block.timestamp < executableAt_) {
            revert CrosschainErrors.ConfigTimelockNotElapsed(block.timestamp, executableAt_);
        }
    }

    /// @dev Timelock end shared by the two `schedule*Config` functions.
    function _configExecutableAt() private view returns (uint64) {
        return SafeCast.toUint64(block.timestamp + CONFIG_DELAY);
    }

    /// @dev Shared part of the executor / dispatcher creation-code configuration.
    function _storeCreationCode(bytes calldata code_, address[2] storage stores_) private returns (uint32 length) {
        if (code_.length == 0) revert CrosschainErrors.EmptyCreationCode();
        length = SafeCast.toUint32(code_.length);
        _writeCreationCode(code_, stores_);
    }

    /// @dev `creationCodesConfigured` guard plus read, shared by both CREATE3 deployments.
    function _configuredCreationCode(address[2] storage stores_, uint256 totalLength_)
        private
        view
        returns (bytes memory)
    {
        if (!creationCodesConfigured) revert CrosschainErrors.CreationCodesNotConfigured();
        return _readCreationCode(stores_, totalLength_);
    }

    /// @dev Immutable-params commitment check shared by `requestDispatcher` and `_onCreateDispatcher`.
    function _requireImmutableParamsHash(
        address admin_,
        address guardian_,
        uint256 rescueDelay_,
        uint256 srcChainId_,
        uint256 dstChainId_,
        bytes32 assetId_,
        bytes32 supplied_
    ) private pure {
        bytes32 expectedHash =
            keccak256(abi.encode(admin_, guardian_, rescueDelay_, srcChainId_, dstChainId_, assetId_));
        if (expectedHash != supplied_) revert CrosschainErrors.ImmutableParamsHashMismatch(expectedHash, supplied_);
    }

    /// @dev Receipt source-chain check shared by the deployment ACK and NACK handlers.
    function _requireReceiptChain(PendingDeployment storage pd_, uint256 srcChainId_) private view {
        if (srcChainId_ != pd_.dstChainId) {
            revert CrosschainErrors.DeploymentReceiptChainMismatch(pd_.dstChainId, srcChainId_);
        }
    }

    /// @dev Ticket commitment check shared by the deployment ACK and NACK handlers.
    function _requireTicketHash(PendingDeployment storage pd_, bytes32 ticketHash_) private view {
        if (ticketHash_ != pd_.ticketHash) {
            revert CrosschainErrors.TicketCommitmentMismatch(pd_.ticketHash, ticketHash_);
        }
    }
}
