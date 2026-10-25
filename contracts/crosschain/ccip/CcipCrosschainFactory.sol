// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CREATE3} from "solady/utils/CREATE3.sol";

import {CcipAppBase} from "./base/CcipAppBase.sol";
import {CcipClient} from "./interfaces/CcipClient.sol";
import {CcipRouteConfig} from "./interfaces/ICcipCrosschain.sol";
import {CcipMessages, CcipMsgType} from "./lib/CcipMessages.sol";
import {CcipCrosschainExecutor} from "./CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "./CcipCrosschainDispatcher.sol";
import {CrosschainConstants} from "../lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../lib/CrosschainErrors.sol";

/// @dev Views of the executor that the factory reads, plus the callback it uses to mark a dispatcher ready.
interface ICcipExecutorFactoryView {
    function MANAGER() external view returns (address);
    function ASSET_ID() external view returns (bytes32);
    function markDispatcherReady(uint256 chainId_) external;
    function ADMIN() external view returns (address);
    function RESCUE_GUARDIAN() external view returns (address);
    function RESCUE_DELAY() external view returns (uint256);
    function hasDispatcher(uint256 chainId_) external view returns (bool);
}

/// @dev Route entry points of an executor that the factory drives.
interface ICcipRoutePolicyReceiver {
    function registerRoute(uint256 chainId_, CcipRouteConfig calldata route_) external;
    function syncRoutePolicy(uint256 chainId_, address feeToken_, uint256 gasLimitsAndFlags_, uint256 maxFee_) external;
}

/// @dev Route-policy entry point of a dispatcher that the factory drives.
interface ICcipDispatcherRoutePolicyReceiver {
    function EXECUTOR_CHAIN_ID() external view returns (uint256);
    function syncRoutePolicy(address feeToken_, uint256 gasLimitsAndFlags_, uint256 maxFee_) external;
}

/// @dev Init code that stores `data_` as the runtime code of the deployed contract, behind a leading `0x00` byte
///      (STOP). Used to keep creation codes in contract storage chunks that are read back with `extcodecopy`.
contract CcipCreationCodeStore {
    constructor(bytes memory data_) {
        bytes memory runtime = abi.encodePacked(hex"00", data_);
        assembly ("memory-safe") {
            return(add(runtime, 0x20), mload(runtime))
        }
    }
}

/// @title CcipCrosschainFactory
/// @notice Deploys the CCIP executor on this chain and, on request of an executor, the matching dispatcher on a
///         destination chain, both at deterministic CREATE3 addresses, and pays every CCIP message it originates
///         from its own native or fee-token balance.
/// @dev Same-address model: an executor, and the dispatcher deployed for it on the destination, share one address.
///      The factory is also a CCIP app: it receives `CREATE_DISPATCHER` tickets (destination side) and
///      `DEPLOYMENT_ACK` / `DEPLOYMENT_NACK` answers (source side) from its peer factory. Configuration (routes,
///      assets, dispatcher gas limits) is owner-only and timelocked by `CONFIG_DELAY`; the creation codes are set once.
contract CcipCrosschainFactory is CcipAppBase {
    using SafeERC20 for IERC20;

    uint256 public constant CONFIG_DELAY = CrosschainConstants.MIN_CONFIG_DELAY;
    uint256 public constant DEPLOYMENT_TTL = 7 days;
    /// @dev NACK reason codes, see `_sendDeploymentNack`. A failed deployment attempt is answered with a NACK only
    ///      if (1) at least `NACK_MIN_GAS` remains for the NACK send and (2) the attempt consumed at most 90% of the
    ///      gas it started with (a deterministic rejection is early and cheap; a nested out-of-gas is not).
    ///      Otherwise the receive reverts with `InsufficientGasForDeploymentNack` and stays retryable.
    uint8 private constant NACK_CONFIG_REJECTED = 2;
    uint8 private constant NACK_VAULTS_REJECTED = 3;
    uint8 private constant NACK_TICKET_EXPIRED = 4;
    uint256 private constant NACK_MIN_GAS = 200_000;

    /// @notice Shared-decimals asset an executor can be built for.
    /// @param token Token the executor and dispatcher hold.
    /// @param sharedDecimals Decimals used on the wire between chains.
    /// @param enabled False until `executeAsset` has written the entry.
    struct AssetConfig {
        address token;
        uint8 sharedDecimals;
        bool enabled;
    }

    /// @notice Payload of a `CREATE_DISPATCHER` message: what the destination factory must deploy.
    /// @dev Its hash (`keccak256(abi.encode(ticket))`) identifies the deployment in ACK, NACK and cancel handling.
    /// @param salt CREATE3 salt of the executor on the source chain; the dispatcher reuses it on the destination.
    /// @param executor Executor address on the source chain; must equal the address derived from `salt`.
    /// @param srcChainId Chain of the executor and of the requesting factory.
    /// @param dstChainId Chain the dispatcher is deployed on.
    /// @param assetId Asset the executor was built for.
    /// @param sharedDecimals Shared decimals of that asset; must match the destination asset config.
    /// @param vaults Vaults the dispatcher serves.
    /// @param rescueAdmin Rescue admin of the executor, copied to the dispatcher.
    /// @param rescueGuardian Rescue guardian of the executor, copied to the dispatcher.
    /// @param rescueDelay Rescue delay of the executor, copied to the dispatcher.
    struct DeploymentTicket {
        bytes32 salt;
        address executor;
        uint256 srcChainId;
        uint256 dstChainId;
        bytes32 assetId;
        uint8 sharedDecimals;
        address[] vaults;
        address rescueAdmin;
        address rescueGuardian;
        uint256 rescueDelay;
    }

    error OnlyOwner();
    error InvalidExecutor();
    error AssetNotEnabled(bytes32 assetId);
    error TicketDestinationMismatch(uint256 expected, uint256 actual);
    error TicketSourceChainMismatch(uint256 expected, uint256 actual);
    error TicketExecutorMismatch(address expected, address actual);
    error CreationCodesNotConfigured();
    error CreationCodesAlreadyConfigured();
    error InvalidCreationCode();
    error DeploymentAlreadyPending(address executor, uint256 chainId);
    error DispatcherAlreadyDeployed(address executor, uint256 dstChainId);
    /// @notice The executor used all its CREATE_DISPATCHER attempts for this destination chain.
    error DeploymentAttemptsExhausted(address executor, uint256 dstChainId, uint8 attempts);
    error NoPendingDeployment(address executor, uint256 dstChainId);
    error UnexpectedTokenTransfer(uint256 count);
    error UnknownDeploymentAck(address executor, uint256 chainId, bytes32 ticketHash);
    error SharedDecimalsMismatch(uint8 expected, uint8 received);
    error ConfigNotReady(bytes32 commitment, uint256 executableAt);
    error ConfigNotScheduled(bytes32 commitment);
    error DeploymentNotExpired(address executor, uint256 chainId, uint256 expiresAt);
    error ExecutorRouteMismatch(address executor, uint256 chainId);
    error DispatcherRouteMismatch(address dispatcher, uint256 expectedChainId, uint256 suppliedChainId);
    error InvalidCcipApp(address app);
    error AssetConfigFrozen(bytes32 assetId);
    error CreatorNotAllowed(address creator);
    error SweepFailed();
    error OnlySelf();
    /// @notice A failed deployment attempt cannot be answered with a NACK: too little gas is left for the send, or
    ///         the attempt burned over 90% of its gas. The receive reverts and stays retryable.
    /// @dev Named apart from `CrosschainErrors.InsufficientGasForNack(uint256,uint256)` (the command-NACK error of
    ///      the dispatchers), whose selector differs.
    /// @param gasLeft `gasleft()` at the revert.
    error InsufficientGasForDeploymentNack(uint256 gasLeft);
    error TooManyVaults(uint256 supplied, uint256 maximum);
    error InvalidVaultAddress(address vault);
    error DuplicateVault(address vault);
    error PeerMustBeSelf(address peer);
    error RouteToLocalChain(uint256 chainId);

    address public immutable OWNER;
    mapping(bytes32 => AssetConfig) public assetConfig;
    mapping(address => bool) public isExecutor;
    mapping(address => bool) public isDispatcher;
    mapping(address => bytes32) public saltOf;
    mapping(address => address[]) private _executorsByManager;
    mapping(bytes32 => bool) public consumedTicket;
    mapping(address executor => mapping(uint256 chainId => bytes32 ticketHash)) public pendingDeploymentTicket;
    mapping(address executor => mapping(uint256 chainId => uint64 createdAt)) public pendingDeploymentCreatedAt;
    /// @notice Hash of the ticket most recently dropped by `cancelExpiredDeployment` per executor and chain (IL-8637).
    /// @dev The cancel never reaches the destination and a CCIP message has no protocol expiry, so a ticket delivered
    ///      before its `expiresAt` can still be ACKed after the cancel. Kept for monitoring: the late-ACK branch
    ///      matches `isCancelledDeploymentTicket` (IL-8637 R2). Deleted by every accepted DEPLOYMENT_ACK for the
    ///      executor and chain. The dispatcher is always the executor's address (same-address model), so the hash
    ///      alone identifies it.
    mapping(address executor => mapping(uint256 chainId => bytes32 ticketHash)) public cancelledDeploymentTicket;
    /// @notice Every ticket hash ever dropped by `cancelExpiredDeployment` per executor and chain (IL-8637 R2).
    /// @dev `cancelledDeploymentTicket` keeps only the last cancel, so a second cancel of a different ticket used to
    ///      orphan the first ticket's late ACK. The late-ACK branch matches this set instead. Accepting any cancelled
    ///      hash is safe: the destination deploys at most one ticket per executor (any other answers NACK(1) for the
    ///      occupied address), so at most one of these hashes can ever be ACKed, and `hasDispatcher` refuses the rest.
    mapping(address executor => mapping(uint256 chainId => mapping(bytes32 ticketHash => bool))) public
        isCancelledDeploymentTicket;
    /// @notice Maximum CREATE_DISPATCHER tickets one executor may send toward one destination chain without a
    ///         successful deployment ACK or an owner reset.
    uint8 public constant MAX_DEPLOYMENT_ATTEMPTS = 3;

    /// @notice CREATE_DISPATCHER tickets an executor has sent toward a chain since its last ACK or owner reset.
    /// @dev Every ticket's CCIP fee is paid from this factory's balance, shared by all tenants. An ALPHA could
    ///      otherwise target a chain where the asset is not enabled (the destination answers NACK, which also
    ///      spends destination budget), or let the ticket expire and be cancelled, and re-request for another
    ///      full fee, without bound (IL-8565 / IL-8605). A NACK or a TTL cancel does NOT reset the counter; a
    ///      DEPLOYMENT_ACK deletes it, and the owner can clear it with `resetDeploymentAttempts`. Same policy
    ///      as the Stargate factory.
    mapping(address executor => mapping(uint256 dstChainId => uint8 attempts)) public deploymentAttempts;

    /// @notice Emitted when the owner clears an executor's attempt counter for a chain.
    event DeploymentAttemptsReset(address executor, uint256 dstChainId);
    mapping(bytes32 commitment => uint64 executableAt) public scheduledConfig;
    /// @notice Scheduled, not yet executed or cancelled `scheduleAsset` commitments per asset (IL-8623). While
    ///         non-zero (and the asset is not frozen) a fresh `CREATE_DISPATCHER` for the asset reverts.
    mapping(bytes32 assetId => uint256 count) public scheduledAssetCount;
    /// @dev Asset behind an asset commitment, so `cancelScheduledConfig` (which only knows the commitment) can
    ///      decrement `scheduledAssetCount`. Chosen over a dedicated cancel function: no new owner entry point and
    ///      the existing cancel flow keeps working. Zero for every non-asset commitment.
    mapping(bytes32 commitment => bytes32 assetId) private _scheduledAssetOf;
    uint256 private constant _CODE_CHUNK_SIZE = 20_000;
    address[2] private _executorCodeStores;
    address[2] private _dispatcherCodeStores;
    uint32 private _executorCodeLength;
    uint32 private _dispatcherCodeLength;
    bool public creationCodesConfigured;
    /// @notice Assets permanently pinned because an executor or dispatcher was built against them.
    mapping(bytes32 assetId => bool frozen) public assetFrozen;
    /// @notice When true only allowlisted addresses may call `createExecutor`.
    bool public creationRestricted = true;
    mapping(address creator => bool allowed) public isAllowedCreator;
    /// @notice Destination gas limit of the `CREATE_DISPATCHER` ticket sent to a chain; 0 falls back to the
    ///         route's `messageGasLimit`. ACK and NACK use the route's `messageGasLimit`; executor sends are bound
    ///         to the route policy in `CcipSendLib` (0 uses the policy, above it is clamped, below it reverts)
    ///         (IL-8516).
    mapping(uint256 chainId => uint96 gasLimit) public dispatcherDeploymentGasLimit;
    /// @notice keccak256 of the executor creation code stored by `configureCreationCodes` (zero until configured).
    bytes32 public executorCreationCodeHash;
    /// @notice keccak256 of the dispatcher creation code stored by `configureCreationCodes` (zero until configured).
    bytes32 public dispatcherCreationCodeHash;

    event ExecutorCreated(address manager, address executor, bytes32 salt);
    event DispatcherRequested(address executor, uint256 dstChainId, bytes32 messageId);
    event DispatcherDeployed(address dispatcher, uint256 srcChainId);
    event CcipRoutePolicySynced(address app, uint256 chainId);
    event DeploymentNack(address executor, uint256 dstChainId, bytes32 ticketHash, uint8 reason);
    event DeploymentCancelled(address executor, uint256 dstChainId, bytes32 ticketHash);
    /// @notice A DEPLOYMENT_ACK matching a cancelled ticket was accepted late (IL-8637).
    event DeploymentLateAcked(address executor, uint256 dstChainId, bytes32 ticketHash);
    event ConfigScheduled(bytes32 commitment, uint256 executableAt);
    event ConfigCancelled(bytes32 commitment);
    /// @notice Emitted when a factory route is scheduled, alongside the hash-only `ConfigScheduled`.
    event FactoryRouteScheduled(uint256 chainId, CcipRouteConfig route, uint256 executableAt);
    /// @notice Emitted when a dispatcher deployment gas limit is scheduled, alongside the hash-only `ConfigScheduled`.
    event DispatcherDeploymentGasLimitScheduled(uint256 chainId, uint96 gasLimit, uint256 executableAt);
    /// @notice Emitted when a scheduled dispatcher deployment gas limit is executed and written.
    event DispatcherDeploymentGasLimitExecuted(uint256 chainId, uint96 gasLimit);
    /// @notice Emitted when an asset config is scheduled, alongside the hash-only `ConfigScheduled`.
    event AssetConfigScheduled(bytes32 assetId, address token, uint8 sharedDecimals, uint256 executableAt);
    /// @notice Emitted when a scheduled asset config is executed and `assetConfig[assetId]` is written.
    event AssetConfigExecuted(bytes32 assetId, address token, uint8 sharedDecimals);
    /// @notice Emitted once when the executor and dispatcher creation codes are stored.
    event CreationCodesConfigured(bytes32 executorCodeHash, bytes32 dispatcherCodeHash);
    event CreatorAllowanceUpdated(address creator, bool allowed);
    event CreationRestrictionUpdated(bool restricted);
    event NativeSwept(address to, uint256 amount);
    event TokenSwept(address token, address to, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert OnlyOwner();
        _;
    }

    constructor(address router_, address owner_) CcipAppBase(router_) {
        if (owner_ == address(0)) revert CcipZeroAddress();
        OWNER = owner_;
        isAllowedCreator[owner_] = true;
        emit CreatorAllowanceUpdated(owner_, true);
        emit CreationRestrictionUpdated(true);
    }

    /// @notice Version of the factory interface.
    /// @dev Constant for off-chain tooling; no contract reads it.
    /// @return Always 1.
    function factoryInterfaceVersion() external pure returns (uint32) {
        return 1;
    }

    /// @notice Recover native fee budget the owner previously funded.
    /// @dev The factory pays every CCIP fee it originates from its own balance and had no exit before,
    ///      so operator-funded gas was permanently locked (audit H-3). Mirrors the Stargate factory's
    ///      `sweepNative`.
    function sweepNative(address payable to_, uint256 amount_) external onlyOwner {
        if (to_ == address(0)) revert CcipZeroAddress();
        (bool ok,) = to_.call{value: amount_}("");
        if (!ok) revert SweepFailed();
        emit NativeSwept(to_, amount_);
    }

    /// @notice Recover ERC20 fee budget (e.g. LINK) the owner previously funded.
    function sweepToken(address token_, address to_, uint256 amount_) external onlyOwner {
        if (to_ == address(0) || token_ == address(0)) revert CcipZeroAddress();
        IERC20(token_).safeTransfer(to_, amount_);
        emit TokenSwept(token_, to_, amount_);
    }

    /// @notice Restrict `createExecutor` to an allowlist.
    /// @dev Creation is restricted by default because each executor can spend the shared factory fee
    ///      budget through `requestDispatcher`. The owner is allowlisted during construction.
    ///      Policy (IL-8104, applying the decision recorded for IL-8069): keep it `true` in production
    ///      and allowlist only IPOR-operated creators, so every spender of this budget is an IPOR
    ///      executor. An allowlisted creator can mint executors bounded only by gas (`createExecutor`
    ///      derives the CREATE3 salt from the creator and a caller-chosen `userSalt_`), each able to
    ///      spend one ticket fee per destination chain at a time and to request again at once after a NACK,
    ///      up to `MAX_DEPLOYMENT_ATTEMPTS` tickets per chain until an ACK or an owner reset (IL-8565 / IL-8605).
    function setCreationRestricted(bool restricted_) external onlyOwner {
        creationRestricted = restricted_;
        emit CreationRestrictionUpdated(restricted_);
    }

    /// @notice Add or remove an address from the `createExecutor` allowlist.
    /// @dev The list only matters while `creationRestricted` is true; entries are kept when it is switched off.
    function setCreatorAllowed(address creator_, bool allowed_) external onlyOwner {
        isAllowedCreator[creator_] = allowed_;
        emit CreatorAllowanceUpdated(creator_, allowed_);
    }

    /// @notice Drop a scheduled-but-unwanted config commitment before it becomes executable.
    function cancelScheduledConfig(bytes32 commitment_) external onlyOwner {
        if (scheduledConfig[commitment_] == 0) revert ConfigNotScheduled(commitment_);
        delete scheduledConfig[commitment_];
        _releaseScheduledAsset(commitment_);
        emit ConfigCancelled(commitment_);
    }

    /// @notice Commit a factory-to-factory route for `chainId_` to the 24 h timelock; the peer must be this
    ///         factory's own address.
    /// @dev The factory is deployed to the same CREATE3 address on each chain it is deployed to with the same
    ///      salt, so a factory-to-factory lane authenticates this factory's own address; any other value
    ///      reverts `PeerMustBeSelf` before it is committed. Rejected here as well as in `executeFactoryRoute` so
    ///      an operator learns of a wrong peer at schedule time; the commitment hash binds every field of
    ///      `route_`, so a rejected schedule cannot later be executed.
    /// @dev A route to this chain's own id reverts `RouteToLocalChain`, the CCIP counterpart of the Stargate
    ///      `_registerPath` check (IL-8451). Executor and dispatcher routes are derived from factory routes, so
    ///      this one check keeps the local chain id out of every CCIP route table.
    function scheduleFactoryRoute(uint256 chainId_, CcipRouteConfig calldata route_) external onlyOwner {
        if (route_.peer != address(this)) revert PeerMustBeSelf(route_.peer);
        if (chainId_ == block.chainid) revert RouteToLocalChain(chainId_);
        uint256 executableAt = _scheduleConfig(keccak256(abi.encode("ROUTE", chainId_, route_)));
        emit FactoryRouteScheduled(chainId_, route_, executableAt);
    }

    /// @notice Execute a committed factory-to-factory route; the peer must be this factory's own address.
    /// @dev Checked before the commitment is consumed so the invariant holds for the stored route regardless of
    ///      how the commitment was scheduled. Route identity is immutable after first registration
    ///      (`CcipRouteLib.setRoute`), which is why a foreign peer is refused rather than corrected.
    function executeFactoryRoute(uint256 chainId_, CcipRouteConfig calldata route_) external onlyOwner {
        if (route_.peer != address(this)) revert PeerMustBeSelf(route_.peer);
        if (chainId_ == block.chainid) revert RouteToLocalChain(chainId_);
        _consumeConfig(keccak256(abi.encode("ROUTE", chainId_, route_)));
        _registerCcipRoute(chainId_, route_);
    }

    /// @notice Commit the `CREATE_DISPATCHER` gas limit for `chainId_` to the config timelock; 0 resets it to the
    ///         route's `messageGasLimit`.
    /// @dev Deploying a dispatcher via CREATE3 needs far more gas than a command, so the ticket has its own limit
    ///      (IL-8516). Cancel with `cancelScheduledConfig`.
    function scheduleDispatcherDeploymentGasLimit(uint256 chainId_, uint96 gasLimit_) external onlyOwner {
        uint256 executableAt = _scheduleConfig(keccak256(abi.encode("DEPLOY_GAS", chainId_, gasLimit_)));
        emit DispatcherDeploymentGasLimitScheduled(chainId_, gasLimit_, executableAt);
    }

    /// @notice Execute a committed dispatcher deployment gas limit.
    function executeDispatcherDeploymentGasLimit(uint256 chainId_, uint96 gasLimit_) external onlyOwner {
        _consumeConfig(keccak256(abi.encode("DEPLOY_GAS", chainId_, gasLimit_)));
        dispatcherDeploymentGasLimit[chainId_] = gasLimit_;
        emit DispatcherDeploymentGasLimitExecuted(chainId_, gasLimit_);
    }

    /// @notice Schedule an asset config; `executeAsset` applies it after `CONFIG_DELAY`.
    /// @dev Reverts for a frozen asset (see `executeAsset`). While a commitment for the asset is pending, a fresh
    ///      `CREATE_DISPATCHER` for it reverts (IL-8623). Scheduling the same commitment again restarts its timer.
    function scheduleAsset(bytes32 assetId_, address token_, uint8 sharedDecimals_) external onlyOwner {
        if (token_ == address(0)) revert CcipZeroAddress();
        // A zero asset id is the "not an asset commitment" marker of `_scheduledAssetOf`; counting it would leak.
        if (assetId_ == bytes32(0)) revert CrosschainErrors.AssetConfigNotEnabled(assetId_);
        if (assetFrozen[assetId_]) revert AssetConfigFrozen(assetId_);
        bytes32 commitment = keccak256(abi.encode("ASSET", assetId_, token_, sharedDecimals_));
        // Re-scheduling an identical commitment overwrites its timer; it must count once.
        if (scheduledConfig[commitment] == 0) {
            ++scheduledAssetCount[assetId_];
            _scheduledAssetOf[commitment] = assetId_;
        }
        uint256 executableAt = _scheduleConfig(commitment);
        emit AssetConfigScheduled(assetId_, token_, sharedDecimals_, executableAt);
    }

    /// @notice Apply a scheduled asset config once its timelock has passed.
    /// @dev Reverts `AssetConfigFrozen` if an executor or dispatcher was built against the asset in the meantime
    ///      (audit M-4): the first deployment freezes the asset for good, so it can no longer be repointed.
    function executeAsset(bytes32 assetId_, address token_, uint8 sharedDecimals_) external onlyOwner {
        bytes32 commitment = keccak256(abi.encode("ASSET", assetId_, token_, sharedDecimals_));
        _consumeConfig(commitment);
        _releaseScheduledAsset(commitment);
        if (token_ == address(0)) revert CcipZeroAddress();
        // Re-check at execute: an executor or dispatcher may have been built against this asset during
        // the timelock window, and repointing it afterwards would silently split the deployment set
        // between two different tokens (audit M-4). Matches the Stargate factory's `assetFrozen`.
        if (assetFrozen[assetId_]) revert AssetConfigFrozen(assetId_);
        assetConfig[assetId_] = AssetConfig({token: token_, sharedDecimals: sharedDecimals_, enabled: true});
        emit AssetConfigExecuted(assetId_, token_, sharedDecimals_);
    }

    function _releaseScheduledAsset(bytes32 commitment_) private {
        bytes32 assetId = _scheduledAssetOf[commitment_];
        if (assetId == bytes32(0)) return;
        delete _scheduledAssetOf[commitment_];
        --scheduledAssetCount[assetId];
    }

    function _scheduleConfig(bytes32 commitment_) private returns (uint64 executableAt) {
        executableAt = uint64(block.timestamp + CONFIG_DELAY);
        scheduledConfig[commitment_] = executableAt;
        emit ConfigScheduled(commitment_, executableAt);
    }

    function _consumeConfig(bytes32 commitment_) private {
        uint64 executableAt = scheduledConfig[commitment_];
        if (executableAt == 0) revert ConfigNotScheduled(commitment_);
        if (block.timestamp < executableAt) revert ConfigNotReady(commitment_, executableAt);
        delete scheduledConfig[commitment_];
    }

    /// @notice Store the executor and dispatcher creation codes the factory deploys from.
    /// @dev One-shot: a second call reverts `CreationCodesAlreadyConfigured`. Each input must be non-empty and at
    ///      most `2 * _CODE_CHUNK_SIZE` = 40 000 bytes (`InvalidCreationCode`). Each input is the creation code
    ///      already linked against the deployed CCIP libraries (the `crosschain_deploy` profile), without
    ///      constructor arguments, which `createExecutor` and the ticket handler append. The keccak256 of each
    ///      input is stored as `executorCreationCodeHash` / `dispatcherCreationCodeHash` and emitted in
    ///      `CreationCodesConfigured`, so anyone can verify on-chain which code the factory deploys.
    function configureCreationCodes(bytes calldata executorCode_, bytes calldata dispatcherCode_) external onlyOwner {
        if (creationCodesConfigured) revert CreationCodesAlreadyConfigured();
        if (executorCode_.length == 0 || dispatcherCode_.length == 0) revert InvalidCreationCode();
        if (executorCode_.length > _CODE_CHUNK_SIZE * 2 || dispatcherCode_.length > _CODE_CHUNK_SIZE * 2) {
            revert InvalidCreationCode();
        }
        _executorCodeLength = uint32(executorCode_.length);
        _dispatcherCodeLength = uint32(dispatcherCode_.length);
        _writeCode(executorCode_, _executorCodeStores);
        _writeCode(dispatcherCode_, _dispatcherCodeStores);
        creationCodesConfigured = true;
        bytes32 executorCodeHash = keccak256(executorCode_);
        bytes32 dispatcherCodeHash = keccak256(dispatcherCode_);
        executorCreationCodeHash = executorCodeHash;
        dispatcherCreationCodeHash = dispatcherCodeHash;
        emit CreationCodesConfigured(executorCodeHash, dispatcherCodeHash);
    }

    /// @notice Deploy an executor at the creator-bound CREATE3 address derived from `msg.sender` and
    ///      `userSalt_`, and register it as a spender of this factory's fee budget.
    /// @dev The same creator and `userSalt_` yield the same address on every chain where this factory
    ///      has the same address, and the executor's dispatcher is deployed at that address on the
    ///      destination; any contract already deployed at that address on the destination makes every
    ///      ticket the destination has not already consumed NACK in `_deployDispatcher`.
    /// @dev `manager_` is caller-chosen and becomes the only caller of `requestDispatcher` for this
    ///      executor.
    function createExecutor(
        bytes32 userSalt_,
        bytes32 assetId_,
        address manager_,
        CcipCrosschainExecutor.SafetyConfig calldata safety_
    ) external returns (address executor) {
        if (creationRestricted && !isAllowedCreator[msg.sender]) revert CreatorNotAllowed(msg.sender);
        AssetConfig memory asset = assetConfig[assetId_];
        if (!asset.enabled) revert AssetNotEnabled(assetId_);
        if (!creationCodesConfigured) revert CreationCodesNotConfigured();
        assetFrozen[assetId_] = true;
        bytes32 salt = keccak256(abi.encode(msg.sender, userSalt_, uint8(7)));
        bytes memory creationCode = abi.encodePacked(
            _readCode(_executorCodeStores, _executorCodeLength),
            abi.encode(CCIP_ROUTER, address(this), manager_, asset.token, assetId_, asset.sharedDecimals, safety_)
        );
        executor = CREATE3.deploy(salt, creationCode, 0);
        isExecutor[executor] = true;
        saltOf[executor] = salt;
        _executorsByManager[manager_].push(executor);
        emit ExecutorCreated(manager_, executor, salt);
    }

    /// @notice Address `createExecutor` yields for `creator_` and `userSalt_` on this factory.
    /// @dev The same creator and salt give the same address on every chain where this factory has the same address.
    function computeExecutorAddress(address creator_, bytes32 userSalt_) external view returns (address) {
        return CREATE3.getDeployed(keccak256(abi.encode(creator_, userSalt_, uint8(7))), address(this));
    }

    /// @notice Executors created for `manager_`, in creation order.
    /// @dev An append-only, uncapped registry meant for off-chain reads: the array is copied whole, so a manager
    ///      with very many executors can make this call too large for another contract to consume.
    function executorsOf(address manager_) external view returns (address[] memory) {
        return _executorsByManager[manager_];
    }

    /// @notice On-chain source of truth for executor routes. The executor peer is its own
    ///         deterministic CREATE3 address; every transport parameter must match the
    ///         timelocked factory route for the same destination.
    function registerExecutorRoute(address executor_, uint256 chainId_, CcipRouteConfig calldata route_) external {
        if (!isExecutor[executor_] || ICcipExecutorFactoryView(executor_).MANAGER() != msg.sender) {
            revert InvalidExecutor();
        }
        CcipRouteConfig storage configured = _ccipRoutes[chainId_];
        if (
            route_.peer != executor_ || !configured.enabled || !route_.enabled
                || configured.chainSelector != route_.chainSelector || configured.feeToken != route_.feeToken
                || configured.messageGasLimit != route_.messageGasLimit
                || configured.tokenGasLimit != route_.tokenGasLimit || configured.maxFee != route_.maxFee
        ) revert ExecutorRouteMismatch(executor_, chainId_);
        ICcipRoutePolicyReceiver(executor_).registerRoute(chainId_, route_);
    }

    /// @notice Pull the factory's timelocked route policy into a registered local CCIP application.
    /// @dev Permissionless and payload-free: callers cannot choose any policy field. The application
    ///      authenticates this factory before applying the update; route identity is not part of the call.
    function syncCcipRoutePolicy(address app_, uint256 chainId_) external {
        if (!isExecutor[app_] && !isDispatcher[app_]) revert InvalidCcipApp(app_);
        _syncCcipRoutePolicy(app_, chainId_);
    }

    function _syncCcipRoutePolicy(address app_, uint256 chainId_) private {
        CcipRouteConfig memory route = _ccipRoutes[chainId_];
        if (route.chainSelector == 0) revert CcipUnknownChain(chainId_);
        uint256 gasLimitsAndFlags = uint256(route.messageGasLimit) | uint256(route.tokenGasLimit) << 96
            | (route.enabled ? uint256(1) << 192 : 0);
        if (isExecutor[app_]) {
            ICcipRoutePolicyReceiver(app_).syncRoutePolicy(chainId_, route.feeToken, gasLimitsAndFlags, route.maxFee);
        } else {
            uint256 expectedChainId = ICcipDispatcherRoutePolicyReceiver(app_).EXECUTOR_CHAIN_ID();
            if (expectedChainId != chainId_) {
                revert DispatcherRouteMismatch(app_, expectedChainId, chainId_);
            }
            ICcipDispatcherRoutePolicyReceiver(app_).syncRoutePolicy(route.feeToken, gasLimitsAndFlags, route.maxFee);
        }
        emit CcipRoutePolicySynced(app_, chainId_);
    }

    /// @notice Send one `CREATE_DISPATCHER` ticket for `executor_` to `dstChainId_`, paid from this
    ///      factory's own balance.
    /// @dev Callable only by the executor's `MANAGER`; the caller pays no fee (IL-8104 policy: creators
    ///      are IPOR-operated, see `setCreationRestricted`).
    /// @dev At most one ticket per executor and destination is open, and none once the executor reports
    ///      `hasDispatcher` for that chain; at most `MAX_DEPLOYMENT_ATTEMPTS` are sent before an ACK or an owner
    ///      reset (IL-8565 / IL-8605); the amount paid is the router quote, bounded by `maxFee_` and
    ///      by the route ceiling in `CcipSendLib.send`.
    /// @dev `vaults_` is shape-checked before any fee is paid (at most `MAX_TRACKED_POSITION_VAULTS`, no zero
    ///      address, no duplicate), the same rule as `CcipCrosschainExecutor.updateVaults`. Whether each vault has
    ///      code and holds the executor's asset is only knowable on the destination: a list the destination
    ///      dispatcher rejects is answered with a NACK (reason 3), see `_sendDeploymentNack`.
    /// @dev A pending ticket is cleared by the destination's ACK or NACK, or by `cancelExpiredDeployment`.
    /// @dev The ticket is sent with `dispatcherDeploymentGasLimit[dstChainId_]`, or the route's `messageGasLimit`
    ///      when that is 0, and is not bound to the route policy; ACK and NACK use `messageGasLimit`, and executor
    ///      sends are bound to the route policy in `CcipSendLib` (token-bearing sends use `tokenGasLimit`).
    function requestDispatcher(address executor_, uint256 dstChainId_, address[] calldata vaults_, uint256 maxFee_)
        external
        returns (bytes32 messageId)
    {
        if (!isExecutor[executor_] || ICcipExecutorFactoryView(executor_).MANAGER() != msg.sender) {
            revert InvalidExecutor();
        }
        if (ICcipExecutorFactoryView(executor_).hasDispatcher(dstChainId_)) {
            revert DispatcherAlreadyDeployed(executor_, dstChainId_);
        }
        _validateVaultShape(vaults_);
        DeploymentTicket memory ticket = DeploymentTicket({
            salt: saltOf[executor_],
            executor: executor_,
            srcChainId: block.chainid,
            dstChainId: dstChainId_,
            assetId: ICcipExecutorFactoryView(executor_).ASSET_ID(),
            sharedDecimals: CcipCrosschainExecutor(payable(executor_)).SHARED_DECIMALS(),
            vaults: vaults_,
            rescueAdmin: ICcipExecutorFactoryView(executor_).ADMIN(),
            rescueGuardian: ICcipExecutorFactoryView(executor_).RESCUE_GUARDIAN(),
            rescueDelay: ICcipExecutorFactoryView(executor_).RESCUE_DELAY()
        });
        bytes32 ticketHash = keccak256(abi.encode(ticket));
        if (pendingDeploymentTicket[executor_][dstChainId_] != bytes32(0)) {
            revert DeploymentAlreadyPending(executor_, dstChainId_);
        }
        // Bound the factory-funded fees one executor can burn per chain (IL-8565 / IL-8605); counted before the
        // send, never reset by a NACK or a cancel. Every factory send is capped by `route.maxFee` in `CcipSendLib`.
        uint8 attempts = deploymentAttempts[executor_][dstChainId_];
        if (attempts >= MAX_DEPLOYMENT_ATTEMPTS) {
            revert DeploymentAttemptsExhausted(executor_, dstChainId_, attempts);
        }
        deploymentAttempts[executor_][dstChainId_] = attempts + 1;
        pendingDeploymentTicket[executor_][dstChainId_] = ticketHash;
        pendingDeploymentCreatedAt[executor_][dstChainId_] = uint64(block.timestamp);
        CcipRouteConfig memory route = _ccipRoutes[dstChainId_];
        uint96 gasLimit = dispatcherDeploymentGasLimit[dstChainId_];
        if (gasLimit == 0) gasLimit = route.messageGasLimit;
        // Ticket gas is its own timelocked policy (`dispatcherDeploymentGasLimit`, size it for the largest vault
        // list, see the README), so it is exempt from the route-policy binding of `_sendCcip`.
        (messageId,) = _sendCcipUnbound(
            dstChainId_,
            CcipMessages.encode(
                CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket, block.timestamp + DEPLOYMENT_TTL)
            ),
            address(0),
            0,
            maxFee_,
            route.feeToken,
            gasLimit
        );
        emit DispatcherRequested(executor_, dstChainId_, messageId);
    }

    /// @notice Clear an executor's CREATE_DISPATCHER attempt counter for a chain (IL-8565 / IL-8605). Immediate,
    ///         owner-only, not timelocked: it only re-opens spending of the owner's own fee budget.
    /// @param executor_ The executor whose counter is cleared.
    /// @param dstChainId_ The destination chain id.
    function resetDeploymentAttempts(address executor_, uint256 dstChainId_) external onlyOwner {
        delete deploymentAttempts[executor_][dstChainId_];
        emit DeploymentAttemptsReset(executor_, dstChainId_);
    }

    /// @notice Drop a ticket strictly after `createdAt + DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN`, freeing its
    ///      executor and chain for a new request. The owner and the executor's manager may do so from that point;
    ///      third parties only after a further `DEPLOYMENT_CANCEL_GRACE` (IL-8637).
    /// @dev The `CREATE_DISPATCHER` payload carries `expiresAt = createdAt + DEPLOYMENT_TTL` next to the ticket (not
    ///      inside it: the ticket hash must stay identical across re-requests, see IL-8486). The destination answers
    ///      NACK(4) from `expiresAt` on instead of deploying, so a ticket dropped here can never be deployed by a
    ///      late manual execution (IL-8623); the margin covers a destination clock that lags this chain's.
    /// @dev A ticket delivered before `expiresAt` can still deploy and ACK after this cancel; the hash is kept in
    ///      `isCancelledDeploymentTicket` (every cancel) and `cancelledDeploymentTicket` (the last one) so that late
    ///      ACK is accepted instead of orphaned, even after later cancels of other tickets (IL-8637, R2).
    /// @dev The TTL is a factory constant, not a value read from the executor, so a request and its
    ///      cancellation cannot land in one transaction (contrast IL-8069 on the Stargate factory).
    function cancelExpiredDeployment(address executor_, uint256 dstChainId_) external {
        bytes32 ticketHash = pendingDeploymentTicket[executor_][dstChainId_];
        if (ticketHash == bytes32(0)) revert NoPendingDeployment(executor_, dstChainId_);
        uint256 expiresAt = uint256(pendingDeploymentCreatedAt[executor_][dstChainId_]) + DEPLOYMENT_TTL
            + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        if (msg.sender != OWNER && msg.sender != ICcipExecutorFactoryView(executor_).MANAGER()) {
            expiresAt += CrosschainConstants.DEPLOYMENT_CANCEL_GRACE;
        }
        if (block.timestamp <= expiresAt) revert DeploymentNotExpired(executor_, dstChainId_, expiresAt);
        delete pendingDeploymentTicket[executor_][dstChainId_];
        delete pendingDeploymentCreatedAt[executor_][dstChainId_];
        cancelledDeploymentTicket[executor_][dstChainId_] = ticketHash;
        isCancelledDeploymentTicket[executor_][dstChainId_][ticketHash] = true;
        emit DeploymentCancelled(executor_, dstChainId_, ticketHash);
    }

    function _handleCcipMessage(uint256 srcChainId_, CcipClient.Any2EVMMessage memory message_) internal override {
        if (message_.destTokenAmounts.length != 0) revert UnexpectedTokenTransfer(message_.destTokenAmounts.length);
        (CcipMsgType messageType, bytes memory data) = CcipMessages.decode(message_.data);
        if (messageType == CcipMsgType.CREATE_DISPATCHER) {
            (DeploymentTicket memory ticket, uint256 expiresAt) = abi.decode(data, (DeploymentTicket, uint256));
            _deployDispatcher(srcChainId_, ticket, expiresAt);
        } else if (messageType == CcipMsgType.DEPLOYMENT_ACK) {
            (address executor, uint256 dstChainId, bytes32 ticketHash) = abi.decode(data, (address, uint256, bytes32));
            if (!isExecutor[executor]) revert InvalidExecutor();
            if (dstChainId != srcChainId_) revert UnknownDeploymentAck(executor, dstChainId, ticketHash);
            if (pendingDeploymentTicket[executor][dstChainId] != ticketHash) {
                // Late ACK for a cancelled ticket (IL-8637): accepted only while no newer ticket is open and the
                // executor has no dispatcher there yet; the slot was already freed at cancel, nothing to release.
                if (
                    ticketHash == bytes32(0) || !isCancelledDeploymentTicket[executor][dstChainId][ticketHash]
                        || pendingDeploymentTicket[executor][dstChainId] != bytes32(0)
                        || ICcipExecutorFactoryView(executor).hasDispatcher(dstChainId)
                ) revert UnknownDeploymentAck(executor, dstChainId, ticketHash);
                emit DeploymentLateAcked(executor, dstChainId, ticketHash);
            }
            delete pendingDeploymentTicket[executor][dstChainId];
            delete pendingDeploymentCreatedAt[executor][dstChainId];
            // Consumes the late-ACK record; on the normal path it is defence in depth (markDispatcherReady and
            // initializeRoute are idempotent, so a stale record could not be replayed into harm anyway).
            delete cancelledDeploymentTicket[executor][dstChainId];
            delete isCancelledDeploymentTicket[executor][dstChainId][ticketHash];
            delete deploymentAttempts[executor][dstChainId];
            ICcipExecutorFactoryView(executor).markDispatcherReady(dstChainId);
        } else if (messageType == CcipMsgType.DEPLOYMENT_NACK) {
            (address executor, uint256 dstChainId, bytes32 ticketHash, uint8 reason) =
                abi.decode(data, (address, uint256, bytes32, uint8));
            if (
                !isExecutor[executor] || dstChainId != srcChainId_
                    || pendingDeploymentTicket[executor][dstChainId] != ticketHash
            ) revert UnknownDeploymentAck(executor, dstChainId, ticketHash);
            // A TICKET_EXPIRED NACK is sent only by a destination that saw `expiresAt = createdAt + TTL` pass, so
            // one arriving earlier belongs to a previous, identical request (same ticket hash across re-requests)
            // and must not close the fresh one. Revert (retryable): it is harmless once the fresh TTL has elapsed.
            if (reason == NACK_TICKET_EXPIRED) {
                uint256 notBefore = uint256(pendingDeploymentCreatedAt[executor][dstChainId]) + DEPLOYMENT_TTL;
                if (block.timestamp < notBefore) {
                    revert CrosschainErrors.PrematureExpiredNack(executor, dstChainId, notBefore);
                }
            }
            delete pendingDeploymentTicket[executor][dstChainId];
            delete pendingDeploymentCreatedAt[executor][dstChainId];
            // Beyond the TICKET_EXPIRED timing check above, `reason` is informational: it is relayed in the event and
            // not validated (unlike the Stargate factory).
            emit DeploymentNack(executor, dstChainId, ticketHash, reason);
        } else {
            revert CcipMessages.InvalidMessageType(uint8(messageType));
        }
    }

    function _deployDispatcher(uint256 srcChainId_, DeploymentTicket memory ticket_, uint256 expiresAt_) private {
        if (ticket_.dstChainId != block.chainid) {
            revert TicketDestinationMismatch(ticket_.dstChainId, block.chainid);
        }
        // Sanity bound on the source-set expiry (IL-8623): `expiresAt` is decoded from a trailing word that a payload
        // of another wire format (the ticket alone) fills with foreign data, which CCIP's ABI decoding accepts
        // silently; and a destination clock lagging the source's beyond the margin is not trusted to judge expiry.
        // Revert (retryable) rather than NACK or deploy.
        uint256 maxExpiresAt =
            block.timestamp + CrosschainConstants.MAX_DEPLOYMENT_TTL + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        if (expiresAt_ > maxExpiresAt) revert CrosschainErrors.TicketExpiryOutOfRange(expiresAt_, maxExpiresAt);
        if (ticket_.srcChainId != srcChainId_) revert TicketSourceChainMismatch(ticket_.srcChainId, srcChainId_);
        address predicted = CREATE3.getDeployed(ticket_.salt, address(this));
        if (predicted != ticket_.executor) revert TicketExecutorMismatch(ticket_.executor, predicted);
        bytes32 ticketHash = keccak256(abi.encode(ticket_));
        if (predicted.code.length != 0 && !consumedTicket[ticketHash]) {
            _sendDeploymentNack(srcChainId_, ticket_, ticketHash, 1);
            return;
        }
        if (!consumedTicket[ticketHash]) {
            // Absolute expiry (IL-8623): never deploy a ticket delivered at or after `expiresAt`; the source drops
            // it only `DEPLOYMENT_CANCEL_MARGIN` later. An already consumed ticket is re-ACKed below as before.
            if (block.timestamp >= expiresAt_) {
                _sendDeploymentNack(srcChainId_, ticket_, ticketHash, NACK_TICKET_EXPIRED);
                return;
            }
            // Migration gate (IL-8623): a deployment freezes the asset, which would make the owner's scheduled
            // `executeAsset` revert for good. Revert (retryable) until that migration is executed or cancelled. A
            // frozen asset cannot be migrated, so a stale commitment on it must not hold the packet.
            if (!assetFrozen[ticket_.assetId] && scheduledAssetCount[ticket_.assetId] != 0) {
                revert CrosschainErrors.DestinationAssetMigrationScheduled(ticket_.assetId);
            }
            // Deterministic rejections (asset, decimals, creation code, vault list) answer NACK; transient
            // failures (the ACK/NACK send below, an exhausted executor gas budget) still revert the receive.
            uint256 gasBefore = gasleft();
            try this.deployDispatcherForTicket(ticket_, srcChainId_) {}
            catch (bytes memory reason) {
                // Each nested frame (self-call, CREATE3 proxy, CREATE) keeps 1/64 of its gas when the callee runs
                // out, so an out-of-gas deployment can leave more than `NACK_MIN_GAS`. Revert (retryable) when too
                // little gas remains for the NACK send, or when the attempt burned over 90% of its gas.
                if (gasleft() < NACK_MIN_GAS || gasleft() * 10 < gasBefore) {
                    revert InsufficientGasForDeploymentNack(gasleft());
                }
                _sendDeploymentNack(srcChainId_, ticket_, ticketHash, _nackReason(reason));
                return;
            }
        }
        isDispatcher[predicted] = true;
        CcipRouteConfig memory route = _ccipRoutes[srcChainId_];
        _sendCcip(
            srcChainId_,
            CcipMessages.encode(
                CcipMsgType.DEPLOYMENT_ACK, abi.encode(ticket_.executor, block.chainid, ticketHash)
            ),
            address(0),
            0,
            route.maxFee,
            route.feeToken,
            route.messageGasLimit
        );
    }

    /// @notice Self-call entry for the deterministic part of a deployment, so `_deployDispatcher` can turn a
    ///      revert here into a NACK. Everything it writes is rolled back with the revert.
    /// @dev Callable only by this factory.
    function deployDispatcherForTicket(DeploymentTicket calldata ticket_, uint256 srcChainId_)
        external
        returns (address dispatcher)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        AssetConfig memory asset = assetConfig[ticket_.assetId];
        if (!asset.enabled) revert AssetNotEnabled(ticket_.assetId);
        assetFrozen[ticket_.assetId] = true;
        if (asset.sharedDecimals != ticket_.sharedDecimals) {
            revert SharedDecimalsMismatch(asset.sharedDecimals, ticket_.sharedDecimals);
        }
        CcipRouteConfig memory factoryRoute = _ccipRoutes[srcChainId_];
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: factoryRoute.chainSelector,
            peer: ticket_.executor,
            feeToken: factoryRoute.feeToken,
            messageGasLimit: factoryRoute.messageGasLimit,
            tokenGasLimit: factoryRoute.tokenGasLimit,
            maxFee: factoryRoute.maxFee,
            enabled: true
        });
        bytes memory creationCode = _dispatcherCreationCode(ticket_, asset.token, executorRoute);
        dispatcher = CREATE3.deploy(ticket_.salt, creationCode, 0);
        CcipCrosschainDispatcher(payable(dispatcher)).configureVaults(ticket_.vaults, true);
        consumedTicket[keccak256(abi.encode(ticket_))] = true;
        emit DispatcherDeployed(dispatcher, srcChainId_);
    }

    /// @dev Reason 3 for the dispatcher's own vault-list errors, otherwise 2.
    function _nackReason(bytes memory revertData_) private pure returns (uint8) {
        if (revertData_.length >= 4) {
            bytes4 selector = bytes4(revertData_);
            if (
                selector == CcipCrosschainDispatcher.InvalidVault.selector
                    || selector == CcipCrosschainDispatcher.VaultsCapReached.selector
            ) return NACK_VAULTS_REJECTED;
        }
        return NACK_CONFIG_REJECTED;
    }

    /// @dev Same rule as `CcipExecutorCommandLib.validateVaultShape` (kept inline so the factory need not link that
    ///      library).
    function _validateVaultShape(address[] calldata vaults_) private pure {
        uint256 length = vaults_.length;
        if (length > CrosschainConstants.MAX_TRACKED_POSITION_VAULTS) {
            revert TooManyVaults(length, CrosschainConstants.MAX_TRACKED_POSITION_VAULTS);
        }
        for (uint256 i; i < length; ++i) {
            address vault = vaults_[i];
            if (vault == address(0)) revert InvalidVaultAddress(vault);
            for (uint256 j; j < i; ++j) {
                if (vaults_[j] == vault) revert DuplicateVault(vault);
            }
        }
    }

    /// @dev NACK reason codes (relayed in `DeploymentNack`, informational on the source): 1 = predicted address
    ///      occupied by another ticket; 2 = asset not enabled, shared-decimals mismatch, creation code missing
    ///      or CREATE3 failed; 3 = the dispatcher rejected the vault list (`InvalidVault`, `VaultsCapReached`);
    ///      4 = the ticket was delivered at or after its `expiresAt` and nothing was deployed (IL-8623).
    function _sendDeploymentNack(
        uint256 srcChainId_,
        DeploymentTicket memory ticket_,
        bytes32 ticketHash_,
        uint8 reason_
    ) private {
        CcipRouteConfig memory route = _ccipRoutes[srcChainId_];
        _sendCcip(
            srcChainId_,
            CcipMessages.encode(
                CcipMsgType.DEPLOYMENT_NACK, abi.encode(ticket_.executor, block.chainid, ticketHash_, reason_)
            ),
            address(0),
            0,
            route.maxFee,
            route.feeToken,
            route.messageGasLimit
        );
    }

    function _dispatcherCreationCode(
        DeploymentTicket memory ticket_,
        address token_,
        CcipRouteConfig memory executorRoute_
    ) private view returns (bytes memory) {
        return abi.encodePacked(
            _readCode(_dispatcherCodeStores, _dispatcherCodeLength),
            abi.encode(
                CCIP_ROUTER,
                address(this),
                token_,
                ticket_.assetId,
                ticket_.sharedDecimals,
                ticket_.srcChainId,
                executorRoute_,
                ticket_.rescueAdmin,
                ticket_.rescueGuardian,
                ticket_.rescueDelay
            )
        );
    }

    function _writeCode(bytes calldata code_, address[2] storage stores_) private {
        uint256 firstLength = code_.length > _CODE_CHUNK_SIZE ? _CODE_CHUNK_SIZE : code_.length;
        stores_[0] = address(new CcipCreationCodeStore(code_[:firstLength]));
        if (code_.length > firstLength) stores_[1] = address(new CcipCreationCodeStore(code_[firstLength:]));
    }

    function _readCode(address[2] storage stores_, uint256 totalLength_) private view returns (bytes memory code) {
        code = new bytes(totalLength_);
        uint256 copied;
        for (uint256 i; i < 2 && copied < totalLength_; ++i) {
            address store = stores_[i];
            uint256 size = store.code.length - 1;
            if (size > totalLength_ - copied) size = totalLength_ - copied;
            assembly ("memory-safe") {
                extcodecopy(store, add(add(code, 0x20), copied), 1, size)
            }
            copied += size;
        }
    }
}
