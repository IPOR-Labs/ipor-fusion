// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {ICrosschainExecutor} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {
    MsgType,
    NackReason,
    DeploymentStatus,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    DeploymentTicket,
    DeploymentNack
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";

interface IDispatcherAssetView {
    function ASSET() external view returns (address);
    function STARGATE_POOL() external view returns (address);
}

/// @title StargateDispatcherTicketExpiryTest
/// @notice IL-8623 (Ackee TP-M-45): a CREATE_DISPATCHER ticket carries an absolute `expiresAt`. The destination
///         NACKs a ticket delivered at or after it instead of deploying, and the source factory cancels only
///         `DEPLOYMENT_CANCEL_MARGIN` after it, so a cancelled ticket can never be deployed later (which
///         used to freeze the destination asset right before a scheduled asset update).
/// @dev Requires the oversized real factory (auto-skips under `--code-size-limit 60000`).
contract StargateDispatcherTicketExpiryTest is FactoryTestBase {
    using OptionsBuilder for bytes;

    uint256 internal constant DEST_CHAIN = LOCAL_CHAIN;
    uint256 internal constant TTL = 1 days;
    bytes32 internal constant GUID = keccak256("guid");
    address internal manager = address(0x1111);

    function setUp() public {
        _factorySetUp(CrosschainConstants.MIN_CONFIG_DELAY);
        if (factoryReady) {
            _enableUsdc();
            factory.schedulePathConfig(REMOTE_CHAIN, REMOTE_EID, _factoryPathOptions(REMOTE_EID));
            _warpConfigDelay();
            factory.executePathConfig(REMOTE_CHAIN);
            vm.deal(address(factory), 100 ether);
            _real().setMaxNativeFee(REMOTE_CHAIN, type(uint256).max);
            _real().setMaxNativeFee(LOCAL_CHAIN, type(uint256).max);
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _real() internal view returns (StargateCrosschainFactory) {
        return StargateCrosschainFactory(payable(address(factory)));
    }

    function _factoryPeer() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(factory))));
    }

    function _makeTicket(uint256 requestId_, bytes32 userSalt_, uint256 expiresAt_)
        internal
        view
        returns (DeploymentTicket memory)
    {
        address creator = address(0xC0FFEE);
        return DeploymentTicket({
            requestId: requestId_,
            salt: keccak256(abi.encode(creator, userSalt_)),
            executor: factory.computeExecutorAddress(creator, userSalt_),
            srcChainId: REMOTE_CHAIN,
            dstChainId: DEST_CHAIN,
            assetId: ASSET_ID,
            admin: admin,
            guardian: guardian,
            rescueDelay: 3 days,
            immutableParamsHash: keccak256(
                abi.encode(admin, guardian, uint256(3 days), REMOTE_CHAIN, DEST_CHAIN, ASSET_ID)
            ),
            expiresAt: expiresAt_
        });
    }

    function _deliver(DeploymentTicket memory ticket_) internal {
        endpoint.deliverLz(
            address(factory), REMOTE_EID, _factoryPeer(), GUID, CrosschainMessages.encodeDeploymentTicket(ticket_)
        );
    }

    function _lastType() internal view returns (MsgType) {
        (, uint8 rawType,) = abi.decode(endpoint.lastMessage(), (uint8, uint8, bytes));
        return MsgType(rawType);
    }

    function _lastNack() internal view returns (DeploymentNack memory) {
        (,, bytes memory data) = abi.decode(endpoint.lastMessage(), (uint8, uint8, bytes));
        return CrosschainMessages.decodeDeploymentNack(data);
    }

    function _commandLaneOptions(uint32 eid_) internal pure returns (bytes memory) {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: eid_,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0)
        });
        return abi.encode(options);
    }

    /// @dev Source side: a real executor requests a dispatcher; returns it with the ticket the factory sent.
    function _request() internal returns (ICrosschainExecutor exec, DeploymentTicket memory ticket) {
        exec = ICrosschainExecutor(factory.createExecutor(keccak256("src"), _params(manager)));
        vm.deal(address(exec), 100 ether);
        vm.prank(manager);
        exec.registerChain(REMOTE_CHAIN, REMOTE_EID, _commandLaneOptions(REMOTE_EID));
        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults);
        (,, bytes memory data) = abi.decode(endpoint.lastMessage(), (uint8, uint8, bytes));
        ticket = CrosschainMessages.decodeDeploymentTicket(data);
    }

    /// @dev A second token / pool pair for the same asset id, as the destination asset update would install.
    function _scheduleMigration() internal returns (address newToken, address newPool) {
        MockERC20 token = new MockERC20("USD Coin v2", "USDC2", 6);
        newToken = address(token);
        newPool = address(new MockStargatePool(newToken, 6));
        factory.scheduleAssetConfig(ASSET_ID, newToken, newPool);
    }

    // ---------------------------------------------------------------------
    // Source: the ticket carries the absolute expiry; the cancel waits for expiry + margin
    // ---------------------------------------------------------------------

    function testShouldStampTicketWithCreatedAtPlusTtl() public requiresFactory {
        uint256 createdAt = block.timestamp;
        (, DeploymentTicket memory ticket) = _request();
        assertEq(ticket.expiresAt, createdAt + TTL, "expiresAt == createdAt + deploymentTtl");
    }

    function testShouldRefuseCancelBeforeExpiryPlusMarginAndAllowItAfter() public requiresFactory {
        (ICrosschainExecutor exec, DeploymentTicket memory ticket) = _request();
        uint256 cancellableAt = ticket.expiresAt + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;

        // Past the TTL alone is no longer enough: the destination may still lag behind this chain's clock.
        vm.warp(ticket.expiresAt + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.DeploymentTtlNotElapsed.selector, uint256(1), block.timestamp, cancellableAt
            )
        );
        _real().cancelPendingDeployment(1);

        vm.warp(cancellableAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.DeploymentTtlNotElapsed.selector, uint256(1), block.timestamp, cancellableAt
            )
        );
        vm.prank(manager);
        exec.cancelDispatcherRequest(1);

        vm.warp(cancellableAt);
        _real().cancelPendingDeployment(1);
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "cancelled at expiry + margin");
    }

    /// @dev The expired-ticket NACK is a defined receipt: the source consumes it (PENDING -> FAILED) and
    ///      releases the config freeze without waiting for the cancel window.
    function testShouldConsumeExpiredNackAtSourceAsFailed() public requiresFactory {
        (ICrosschainExecutor exec, DeploymentTicket memory ticket) = _request();
        assertEq(_real().pendingCountByChain(REMOTE_CHAIN), 1, "config frozen while pending");

        DeploymentNack memory nack = DeploymentNack({
            requestId: 1,
            ticketHash: keccak256(abi.encode(ticket)),
            reason: uint8(NackReason.TICKET_EXPIRED)
        });
        endpoint.deliverLz(
            address(factory), REMOTE_EID, _factoryPeer(), GUID, CrosschainMessages.encodeDeploymentNack(nack)
        );

        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.FAILED), "request FAILED");
        assertEq(_real().pendingCountByChain(REMOTE_CHAIN), 0, "config freeze released");
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "readiness never flips on a NACK");
    }

    // ---------------------------------------------------------------------
    // Destination: expired ticket -> NACK, no deployment; valid ticket deploys as before
    // ---------------------------------------------------------------------

    function testShouldNackExpiredTicketAndDeployNothing() public requiresFactory {
        DeploymentTicket memory ticket = _makeTicket(1, keccak256("expired"), block.timestamp + TTL);
        (address token, address stargatePool,) = _real().assetConfig(ASSET_ID);
        vm.warp(ticket.expiresAt);

        _deliver(ticket);

        assertEq(uint8(_lastType()), uint8(MsgType.DEPLOYMENT_NACK), "NACK sent");
        DeploymentNack memory nack = _lastNack();
        assertEq(nack.reason, uint8(NackReason.TICKET_EXPIRED), "reason TICKET_EXPIRED");
        assertEq(nack.ticketHash, keccak256(abi.encode(ticket)), "NACK bound to the ticket");
        assertEq(ticket.executor.code.length, 0, "no dispatcher deployed");
        assertFalse(_real().assetFrozen(ASSET_ID), "asset not frozen");
        (address token2, address pool2,) = _real().assetConfig(ASSET_ID);
        assertEq(token2, token, "asset token untouched");
        assertEq(pool2, stargatePool, "asset pool untouched");
        bytes32 ticketKey = keccak256(abi.encode(REMOTE_EID, _factoryPeer(), ticket.requestId));
        (DeploymentStatus status,,) = _real().consumedTicket(ticketKey);
        assertEq(uint8(status), uint8(DeploymentStatus.NONE), "nothing recorded");
    }

    function testShouldDeployTicketOneSecondBeforeExpiry() public requiresFactory {
        DeploymentTicket memory ticket = _makeTicket(1, keccak256("valid"), block.timestamp + TTL);
        vm.warp(ticket.expiresAt - 1);

        _deliver(ticket);

        assertEq(uint8(_lastType()), uint8(MsgType.DEPLOYMENT_ACK), "ACK sent");
        assertGt(ticket.executor.code.length, 0, "dispatcher deployed");
        assertTrue(_real().assetFrozen(ASSET_ID), "asset frozen by the deployment");
    }

    function testShouldStillReAckDeployedTicketRedeliveredAfterExpiry() public requiresFactory {
        DeploymentTicket memory ticket = _makeTicket(1, keccak256("replay"), block.timestamp + TTL);
        _deliver(ticket);
        assertEq(uint8(_lastType()), uint8(MsgType.DEPLOYMENT_ACK), "first delivery ACKed");

        vm.warp(ticket.expiresAt + 1);
        _deliver(ticket);
        assertEq(uint8(_lastType()), uint8(MsgType.DEPLOYMENT_ACK), "idempotent replay of the recorded outcome");
    }

    // ---------------------------------------------------------------------
    // The finding: an old ticket delivered right before the destination asset update
    // ---------------------------------------------------------------------

    /// @dev Before the fix the ticket stayed executable forever: the source cancelled it after the TTL, the
    ///      owner scheduled the asset update on the destination, and anyone delivered the old packet just before
    ///      `executeAssetConfig`, deploying against the old pool and freezing the asset.
    function testShouldNotLetAnExpiredTicketFreezeAssetBeforeScheduledUpdate() public requiresFactory {
        DeploymentTicket memory ticket = _makeTicket(1, keccak256("attack"), block.timestamp + TTL);
        (address newToken, address newPool) = _scheduleMigration();
        uint256 deliverAt = ticket.expiresAt + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1;
        vm.warp(deliverAt);

        _deliver(ticket); // the old packet is executed just before the update

        assertEq(uint8(_lastType()), uint8(MsgType.DEPLOYMENT_NACK), "expired ticket answered with a NACK");
        assertEq(ticket.executor.code.length, 0, "no dispatcher against the old pool");
        assertFalse(_real().assetFrozen(ASSET_ID), "asset not frozen");

        _real().executeAssetConfig(ASSET_ID);
        (address token, address pool,) = _real().assetConfig(ASSET_ID);
        assertEq(token, newToken, "asset update lands");
        assertEq(pool, newPool, "asset update lands");
    }

    function testShouldKeepFreshTicketRetryableWhileAssetMigrationIsScheduled() public requiresFactory {
        DeploymentTicket memory ticket = _makeTicket(1, keccak256("retry"), block.timestamp + 30 days);
        (address newToken, address newPool) = _scheduleMigration();

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DestinationAssetMigrationScheduled.selector, ASSET_ID));
        _deliver(ticket);
        assertEq(ticket.executor.code.length, 0, "nothing deployed while the migration is scheduled");
        assertFalse(_real().assetFrozen(ASSET_ID), "asset not frozen");

        _warpConfigDelay();
        _real().executeAssetConfig(ASSET_ID);

        _deliver(ticket); // the same packet, retried after the migration
        assertEq(uint8(_lastType()), uint8(MsgType.DEPLOYMENT_ACK), "ACK after the migration");
        assertGt(ticket.executor.code.length, 0, "deployed against the migrated config");
        (address token, address pool,) = _real().assetConfig(ASSET_ID);
        assertEq(token, newToken, "new token in use");
        assertEq(pool, newPool, "new pool in use");
        assertEq(IDispatcherAssetView(ticket.executor).ASSET(), newToken, "dispatcher bound to the new token");
        assertEq(IDispatcherAssetView(ticket.executor).STARGATE_POOL(), newPool, "dispatcher bound to the new pool");
    }

    /// @notice Once the asset is frozen on the destination (any `createExecutor`), a stale scheduled migration
    ///         cannot execute anymore and must not block fresh deployments.
    function testShouldSkipMigrationGateOnceTheAssetIsFrozen() public requiresFactory {
        DeploymentTicket memory ticket = _makeTicket(1, keccak256("frozen"), block.timestamp + 30 days);
        _scheduleMigration();
        factory.createExecutor(keccak256("freezer"), _params(manager)); // freezes ASSET_ID
        assertTrue(_real().assetFrozen(ASSET_ID), "frozen by createExecutor");

        _deliver(ticket);
        assertEq(uint8(_lastType()), uint8(MsgType.DEPLOYMENT_ACK), "ACK despite the stale schedule");
        assertGt(ticket.executor.code.length, 0, "deployed");
    }

    // ---------------------------------------------------------------------
    // Destination sanity bound on `expiresAt` (retryable revert, never a NACK)
    // ---------------------------------------------------------------------

    function testShouldRevertTicketWithExpiryBeyondSanityBoundAndDeployAtTheBound() public requiresFactory {
        uint256 maxExpiresAt =
            block.timestamp + CrosschainConstants.MAX_DEPLOYMENT_TTL + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        DeploymentTicket memory absurd = _makeTicket(1, keccak256("bound"), maxExpiresAt + 1);

        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.TicketExpiryOutOfRange.selector, maxExpiresAt + 1, maxExpiresAt)
        );
        _deliver(absurd);
        assertEq(absurd.executor.code.length, 0, "nothing deployed");
        assertFalse(_real().assetFrozen(ASSET_ID), "asset not frozen");

        // Exactly at the bound is accepted (a ticket never carries a TTL above MAX_DEPLOYMENT_TTL).
        DeploymentTicket memory atBound = _makeTicket(1, keccak256("bound"), maxExpiresAt);
        _deliver(atBound);
        assertEq(uint8(_lastType()), uint8(MsgType.DEPLOYMENT_ACK), "ACK at the bound");
        assertGt(atBound.executor.code.length, 0, "deployed");
    }
}
