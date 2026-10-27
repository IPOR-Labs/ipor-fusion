// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {ICrosschainExecutor} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {ICrosschainFactory, DeploymentRequest} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {RescueModule} from "../../contracts/crosschain/lib/RescueModule.sol";
import {
    MsgType,
    NackReason,
    DeploymentStatus,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    DeploymentTicket,
    DeploymentAck,
    DeploymentNack
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {ContextManager, ExecuteData} from "../../contracts/managers/context/ContextManager.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title FactoryTicketTest
/// @notice Factory-to-factory dispatcher deployment (plan §3.3/§4.2): destination deploys the dispatcher at
///         the executor's address and ACKs; occupied address -> REJECTED_OCCUPIED NACK (never ACK); identical
///         re-delivery re-ACKs; adopt-on-re-request; `ticketKey` namespacing; immutableParamsHash check; and
///         source-side ACK -> readiness + auto UPDATE_VAULTS, NACK, TTL-cancel + late-ACK rejection.
/// @dev Requires the oversized real factory — auto-skips under `--code-size-limit 60000`, passes at 130000.
contract FactoryTicketTest is FactoryTestBase {
    using OptionsBuilder for bytes;

    uint256 internal constant DEST_CHAIN = LOCAL_CHAIN; // 1; the factory's chain in destination-side tests
    bytes32 internal constant GUID = keccak256("guid");
    address internal manager = address(0x1111);

    /// @dev A `msgType 1` (command lane) enforced-options blob with a usable executor `lzReceive` gas, the
    ///      shape `registerChain` requires since IL-8296, with a lane at or above the IL-8625 minimum. The production
    ///      script `RegisterRemoteChains.s.sol` (deploy repo) registered 2,000,000 and must be raised to the new minimum.
    function _commandLaneOptions(uint32 eid_) internal pure returns (bytes memory) {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: eid_,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0)
        });
        return abi.encode(options);
    }

    function setUp() public {
        _factorySetUp(CrosschainConstants.MIN_CONFIG_DELAY);
        if (factoryReady) {
            _enableUsdc();
            // Register the peer ("source") path so tickets can arrive and ACKs/NACKs can be returned.
            factory.schedulePathConfig(REMOTE_CHAIN, REMOTE_EID, _factoryPathOptions(REMOTE_EID));
            _warpConfigDelay();
            factory.executePathConfig(REMOTE_CHAIN);
            vm.deal(address(factory), 100 ether);
            // IL-8050: this file drives the REAL `StargateCrosschainFactory`, so every executor
            // `_createExecutorAndRequest()` deploys through it IS written to `isExecutor` (unlike
            // `CrosschainTestBase`'s controllable mock, whose default is unregistered). The auto initial
            // UPDATE_VAULTS an ACK triggers is therefore a real capped send; set a generous ceiling on the
            // path these executors send to, as owner, rather than weaken the check.
            StargateCrosschainFactory(payable(address(factory))).setMaxNativeFee(REMOTE_CHAIN, type(uint256).max);
            // IL-8565: the factory's own ticket / ACK / NACK sends take the same ceiling, on whichever chain
            // the factory plays source or destination in these single-factory tests (and the second peer).
            StargateCrosschainFactory(payable(address(factory))).setMaxNativeFee(LOCAL_CHAIN, type(uint256).max);
            StargateCrosschainFactory(payable(address(factory))).setMaxNativeFee(10, type(uint256).max);
        }
    }

    // ---------------------------------------------------------------------
    // Ticket / delivery helpers
    // ---------------------------------------------------------------------

    function _factoryPeer() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(factory))));
    }

    function _immutableHash(uint256 srcChainId_, uint256 dstChainId_) internal view returns (bytes32) {
        return keccak256(abi.encode(admin, guardian, uint256(3 days), srcChainId_, dstChainId_, ASSET_ID));
    }

    function _makeTicket(
        uint256 requestId_,
        address creator_,
        bytes32 userSalt_,
        uint256 srcChainId_
    ) internal view returns (DeploymentTicket memory) {
        return
            DeploymentTicket({
                requestId: requestId_,
                salt: keccak256(abi.encode(creator_, userSalt_)),
                executor: factory.computeExecutorAddress(creator_, userSalt_),
                srcChainId: srcChainId_,
                dstChainId: DEST_CHAIN,
                assetId: ASSET_ID,
                admin: admin,
                guardian: guardian,
                rescueDelay: 3 days,
                immutableParamsHash: _immutableHash(srcChainId_, DEST_CHAIN),
                expiresAt: block.timestamp + 7 days
            });
    }

    function _deliverTicket(DeploymentTicket memory ticket_, uint32 srcEid_) internal {
        endpoint.deliverLz(
            address(factory),
            srcEid_,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentTicket(ticket_)
        );
    }

    function _lastSentType() internal view returns (MsgType) {
        (, uint8 rawType, ) = _split(endpoint.lastMessage());
        return MsgType(rawType);
    }

    function _split(bytes memory raw_) internal pure returns (uint8 version, uint8 rawType, bytes memory data) {
        (version, rawType, data) = abi.decode(raw_, (uint8, uint8, bytes));
    }

    function _lastNackReason() internal view returns (uint8) {
        (, , bytes memory data) = _split(endpoint.lastMessage());
        return CrosschainMessages.decodeDeploymentNack(data).reason;
    }

    function _lastAckDispatcher() internal view returns (address) {
        (, , bytes memory data) = _split(endpoint.lastMessage());
        return CrosschainMessages.decodeDeploymentAck(data).dispatcher;
    }

    // ---------------------------------------------------------------------
    // Destination: deploy dispatcher at the executor's address
    // ---------------------------------------------------------------------

    function testShouldEmitInitialCreatorAllowanceAndRestrictionFromConstructor() public requiresFactory {
        vm.recordLogs();
        address fresh = this.deployFactoryExt(3 days);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 allowanceTopic = keccak256("CreatorAllowanceUpdated(address,bool)");
        bytes32 restrictionTopic = keccak256("CreationRestrictionUpdated(bool)");
        bool sawAllowance;
        bool sawRestriction;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != fresh) continue;
            if (logs[i].topics[0] == allowanceTopic) {
                (address creator, bool allowed) = abi.decode(logs[i].data, (address, bool));
                if (creator == address(this) && allowed) sawAllowance = true;
            } else if (logs[i].topics[0] == restrictionTopic) {
                if (abi.decode(logs[i].data, (bool))) sawRestriction = true;
            }
        }
        assertTrue(sawAllowance, "CreatorAllowanceUpdated(owner, true) missing");
        assertTrue(sawRestriction, "CreationRestrictionUpdated(true) missing");
    }

    function testShouldDeployDispatcherAtExecutorAddressAndAck() public requiresFactory {
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("d1");
        address predicted = factory.computeExecutorAddress(creator, userSalt);
        assertEq(predicted.code.length, 0, "predicted address empty before");

        _deliverTicket(_makeTicket(1, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);

        assertGt(predicted.code.length, 0, "dispatcher deployed at the predicted (executor) address");
        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_ACK), "ACK sent");
        assertEq(_lastAckDispatcher(), predicted, "ACK carries the deployed dispatcher address");
        assertTrue(
            StargateCrosschainFactory(payable(address(factory))).assetFrozen(ASSET_ID),
            "destination deployment freezes its asset config"
        );
    }

    function testShouldRejectOccupiedAddressWithNackNeverAck() public requiresFactory {
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("occ");
        address predicted = factory.computeExecutorAddress(creator, userSalt);
        // Squat the predicted address with foreign code the factory never deployed.
        vm.etch(predicted, hex"60006000fd");

        _deliverTicket(_makeTicket(1, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);

        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_NACK), "NACK, never ACK");
        assertEq(_lastNackReason(), uint8(NackReason.REJECTED_OCCUPIED), "reason REJECTED_OCCUPIED");

        // Re-delivery re-NACKs (permanent), still never an ACK.
        _deliverTicket(_makeTicket(1, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);
        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_NACK), "re-NACK on replay");
    }

    function testShouldNotFreezeAssetOnRejectedOccupiedNack() public requiresFactory {
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("occ-freeze");
        address predicted = factory.computeExecutorAddress(creator, userSalt);
        vm.etch(predicted, hex"60006000fd");

        _deliverTicket(_makeTicket(1, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);

        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_NACK), "NACK path taken");
        assertEq(_lastNackReason(), uint8(NackReason.REJECTED_OCCUPIED), "reason REJECTED_OCCUPIED");
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        assertFalse(f.assetFrozen(ASSET_ID), "a NACK must not freeze the asset");

        // Re-delivery (re-NACK) must not freeze either, and the asset config stays changeable.
        _deliverTicket(_makeTicket(1, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);
        assertFalse(f.assetFrozen(ASSET_ID), "re-NACK must not freeze the asset");
        factory.scheduleAssetConfig(ASSET_ID, address(usdc), address(pool));
        vm.warp(block.timestamp + f.CONFIG_DELAY());
        factory.executeAssetConfig(ASSET_ID);
    }

    function testShouldNotFreezeNeverConfiguredAssetOnRejectedOccupiedNack() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        bytes32 neverAsset = keccak256("NEVER");
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("occ-never");
        DeploymentTicket memory ticket = _makeTicket(1, creator, userSalt, REMOTE_CHAIN);
        ticket.assetId = neverAsset;
        ticket.immutableParamsHash = keccak256(
            abi.encode(admin, guardian, uint256(3 days), REMOTE_CHAIN, DEST_CHAIN, neverAsset)
        );
        vm.etch(ticket.executor, hex"60006000fd");

        _deliverTicket(ticket, REMOTE_EID);

        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_NACK), "NACK path taken");
        assertEq(_lastNackReason(), uint8(NackReason.REJECTED_OCCUPIED), "reason REJECTED_OCCUPIED");
        assertFalse(f.assetFrozen(neverAsset), "a NACK must not freeze a never-configured asset");

        factory.scheduleAssetConfig(neverAsset, address(usdc), address(pool));
        vm.warp(block.timestamp + f.CONFIG_DELAY());
        factory.executeAssetConfig(neverAsset);
    }

    function testShouldFreezeAssetOnlyAfterSuccessfulDeployment() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        assertFalse(f.assetFrozen(ASSET_ID), "not frozen before any deployment");
        _deliverTicket(_makeTicket(1, address(0xC0FFEE), keccak256("fz"), REMOTE_CHAIN), REMOTE_EID);
        assertTrue(f.assetFrozen(ASSET_ID), "frozen after a successful deployment");
    }

    function testShouldNotFreezeAssetWhenDeploymentRevertsOnDisabledAsset() public requiresFactory {
        bytes32 disabledAsset = keccak256("DISABLED");
        address creator = address(0xC0FFEE);
        DeploymentTicket memory ticket = _makeTicket(1, creator, keccak256("dis"), REMOTE_CHAIN);
        ticket.assetId = disabledAsset;
        ticket.immutableParamsHash = keccak256(
            abi.encode(admin, guardian, uint256(3 days), REMOTE_CHAIN, DEST_CHAIN, disabledAsset)
        );

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.AssetConfigNotEnabled.selector, disabledAsset));
        _deliverTicket(ticket, REMOTE_EID);

        assertFalse(
            StargateCrosschainFactory(payable(address(factory))).assetFrozen(disabledAsset),
            "a reverted deployment must not freeze the asset"
        );
    }

    function testShouldKeepAssetFrozenAfterAdoption() public requiresFactory {
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("adopt-freeze");
        _deliverTicket(_makeTicket(1, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);
        _deliverTicket(_makeTicket(2, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);

        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_ACK), "adoption ACKed");
        assertTrue(
            StargateCrosschainFactory(payable(address(factory))).assetFrozen(ASSET_ID),
            "still frozen after adoption"
        );
    }

    function testShouldReAckIdenticalReDelivery() public requiresFactory {
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("d1");
        DeploymentTicket memory ticket = _makeTicket(1, creator, userSalt, REMOTE_CHAIN);
        _deliverTicket(ticket, REMOTE_EID);
        uint256 sentAfterFirst = endpoint.sentCount();

        // Identical re-delivery (same ticketKey, same data): re-send the SAME ACK, no second deploy.
        _deliverTicket(ticket, REMOTE_EID);
        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_ACK), "re-ACK");
        assertEq(endpoint.sentCount(), sentAfterFirst + 1, "exactly one extra message (the re-ACK)");
    }

    function testShouldAdoptReRequestForOwnDeployment() public requiresFactory {
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("d1");
        _deliverTicket(_makeTicket(1, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);
        address predicted = factory.computeExecutorAddress(creator, userSalt);

        // A NEW requestId (=2) for the same predicted address the factory already deployed -> ADOPT + ACK.
        _deliverTicket(_makeTicket(2, creator, userSalt, REMOTE_CHAIN), REMOTE_EID);
        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_ACK), "adopted re-request ACKed");
        assertEq(_lastAckDispatcher(), predicted, "ACK still points at the existing dispatcher");
    }

    function testShouldNamespaceTicketKeyBySource() public requiresFactory {
        // Same numeric requestId from two different source EIDs must NOT collide: both deploy independently.
        factory.schedulePathConfig(10, 30111, _factoryPathOptions(30111)); // a second peer chain
        _warpConfigDelay();
        factory.executePathConfig(10);

        address creatorA = address(0xAAA1);
        address creatorB = address(0xBBB2);
        address predictedA = factory.computeExecutorAddress(creatorA, keccak256("a"));
        address predictedB = factory.computeExecutorAddress(creatorB, keccak256("b"));

        _deliverTicket(_makeTicket(1, creatorA, keccak256("a"), REMOTE_CHAIN), REMOTE_EID);
        _deliverTicket(_makeTicket(1, creatorB, keccak256("b"), 10), 30111);

        assertGt(predictedA.code.length, 0, "ticket A (requestId 1) deployed");
        assertGt(predictedB.code.length, 0, "ticket B (requestId 1, different source) deployed independently");
        assertTrue(predictedA != predictedB, "distinct dispatchers");
    }

    function testShouldRejectTicketWithBadImmutableParamsHash() public requiresFactory {
        DeploymentTicket memory ticket = _makeTicket(1, address(0xC0FFEE), keccak256("d1"), REMOTE_CHAIN);
        bytes32 expectedHash = ticket.immutableParamsHash; // the commitment the factory recomputes from the ticket fields
        ticket.immutableParamsHash = keccak256("bogus");
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.ImmutableParamsHashMismatch.selector,
                expectedHash,
                keccak256("bogus")
            )
        );
        _deliverTicket(ticket, REMOTE_EID);
        assertEq(ticket.executor.code.length, 0, "no dispatcher deployed");
        // The rejected ticket was not consumed: the same ticket with the correct hash is still accepted.
        ticket.immutableParamsHash = expectedHash;
        _deliverTicket(ticket, REMOTE_EID);
        assertGt(ticket.executor.code.length, 0, "the valid ticket deploys afterwards");
    }

    function testShouldRejectTicketForWrongDestinationChain() public requiresFactory {
        DeploymentTicket memory ticket = _makeTicket(1, address(0xC0FFEE), keccak256("d1"), REMOTE_CHAIN);
        ticket.dstChainId = 999; // != block.chainid
        ticket.immutableParamsHash = keccak256(
            abi.encode(admin, guardian, uint256(3 days), REMOTE_CHAIN, uint256(999), ASSET_ID)
        );
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.TicketWrongDestinationChain.selector, uint256(999), DEST_CHAIN)
        );
        _deliverTicket(ticket, REMOTE_EID);
    }

    // ---------------------------------------------------------------------
    // Source: request -> ACK -> readiness + auto UPDATE_VAULTS / NACK / TTL-cancel
    // ---------------------------------------------------------------------

    function _createExecutorAndRequest() internal returns (ICrosschainExecutor exec, bytes32 ticketHash) {
        exec = ICrosschainExecutor(factory.createExecutor(keccak256("src"), _params(manager)));
        vm.deal(address(exec), 100 ether);
        vm.prank(manager);
        exec.registerChain(REMOTE_CHAIN, REMOTE_EID, _commandLaneOptions(REMOTE_EID));

        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults);

        // The factory's outbound CREATE_DISPATCHER is the last recorded message; recover its ticket hash.
        (, , bytes memory data) = _split(endpoint.lastMessage());
        ticketHash = keccak256(abi.encode(CrosschainMessages.decodeDeploymentTicket(data)));
    }

    function testShouldFlipReadyAndAutoSendUpdateVaultsOnAck() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "not ready before ACK");
        uint256 sentBefore = endpoint.sentCount();

        DeploymentAck memory ack = DeploymentAck({
            requestId: 1,
            ticketHash: ticketHash,
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );

        assertTrue(exec.isDispatcherReady(REMOTE_CHAIN), "readiness flipped on authenticated ACK");
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.DEPLOYED));
        // The executor auto-sent the initial UPDATE_VAULTS (one extra message beyond the ACK handling).
        assertGt(endpoint.sentCount(), sentBefore, "initial UPDATE_VAULTS auto-sent");
        assertEq(uint8(_lastSentType()), uint8(MsgType.UPDATE_VAULTS), "auto initial UPDATE_VAULTS");
    }

    function testShouldNotFlipReadyOnNack() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        DeploymentNack memory nack = DeploymentNack({
            requestId: 1,
            ticketHash: ticketHash,
            reason: uint8(NackReason.REJECTED_OCCUPIED)
        });
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentNack(nack)
        );
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "readiness never flips on NACK");
        // The executor's callback marks its request FAILED for either NACK reason; the REJECTED_OCCUPIED
        // distinction is retained factory-side (pendingDeployment), not on the executor's record.
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.FAILED));
    }

    function testShouldRejectAckWithWrongDstChainId() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        // §8 P3 item 1: the ACK's own dstChainId field must equal the pending request's destination.
        DeploymentAck memory ack = DeploymentAck({
            requestId: 1,
            ticketHash: ticketHash,
            dispatcher: address(exec),
            dstChainId: 999
        });
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.DeploymentAckChainMismatch.selector, REMOTE_CHAIN, uint256(999))
        );
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "readiness never flips on a mismatched ACK");
    }

    function testShouldRejectNackWithUnknownReason() public requiresFactory {
        (, bytes32 ticketHash) = _createExecutorAndRequest();
        // §8 P3 item 2: an unrecognized NACK reason is rejected, not silently mapped to generic FAILED.
        DeploymentNack memory nack = DeploymentNack({requestId: 1, ticketHash: ticketHash, reason: 99});
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidNackReason.selector, uint8(99)));
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentNack(nack)
        );
    }

    function testShouldAcceptNackWithDestinationValidationReason() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        // DESTINATION_VALIDATION is a valid reason and resolves the request to FAILED.
        DeploymentNack memory nack = DeploymentNack({
            requestId: 1,
            ticketHash: ticketHash,
            reason: uint8(NackReason.DESTINATION_VALIDATION)
        });
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentNack(nack)
        );
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.FAILED));
    }

    function testShouldTtlCancelAndRejectLateAckWithWrongHash() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();

        vm.warp(block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1); // past TTL + margin
        vm.prank(manager);
        exec.cancelDispatcherRequest(1);
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED));

        // A late ACK that does not match the cancelled ticket is rejected.
        bytes32 wrong = bytes32(uint256(ticketHash) ^ 1);
        DeploymentAck memory ack = DeploymentAck({
            requestId: 1,
            ticketHash: wrong,
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.TicketCommitmentMismatch.selector, ticketHash, wrong));
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );
    }

    // ---------------------------------------------------------------------
    // IL-8485: late-ACK recovery end to end (TTL cancel -> re-request -> adoption -> ACK on the source)
    // ---------------------------------------------------------------------

    /// @dev Source-side half of the recovery. Request #1, TTL cancel, late ACK #1 rejected, request #2 with
    ///      identical creator / salt / immutable params. Returns the two outbound tickets as sent on the wire.
    function _sourceCancelAndReRequest()
        internal
        returns (ICrosschainExecutor exec, DeploymentTicket memory ticket1, DeploymentTicket memory ticket2)
    {
        bytes32 ticketHash1;
        (exec, ticketHash1) = _createExecutorAndRequest();
        (, , bytes memory data1) = _split(endpoint.lastMessage());
        ticket1 = CrosschainMessages.decodeDeploymentTicket(data1);

        vm.warp(block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1); // past TTL + margin
        vm.prank(manager);
        exec.cancelDispatcherRequest(1);
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "request #1 cancelled");

        // (1) A late ACK #1 that does not match the cancelled ticket is rejected (a matching one is accepted,
        //     see `testShouldAcceptLateAckAfterCancelWithoutSecondSlotRelease`; here it never arrives).
        DeploymentAck memory lateAck = DeploymentAck({
            requestId: 1,
            ticketHash: bytes32(uint256(ticketHash1) ^ 1),
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        bytes memory lateAckMsg = CrosschainMessages.encodeDeploymentAck(lateAck);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.TicketCommitmentMismatch.selector,
                ticketHash1,
                bytes32(uint256(ticketHash1) ^ 1)
            )
        );
        endpoint.deliverLz(address(factory), REMOTE_EID, _factoryPeer(), GUID, lateAckMsg);

        // (2) Re-request #2 (the destination address is derived from creator + salt, so it is the same).
        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults);
        (, , bytes memory data2) = _split(endpoint.lastMessage());
        ticket2 = CrosschainMessages.decodeDeploymentTicket(data2);
        assertEq(ticket2.requestId, 2, "re-request is #2");
        assertEq(ticket2.executor, ticket1.executor, "same destination address");
        assertEq(ticket2.immutableParamsHash, ticket1.immutableParamsHash, "identical immutable params");
    }

    /// @notice A dispatcher deployed for request #1 whose ACK arrived only after the TTL cancel is recovered
    ///         by re-requesting: the destination adopts its own deployment, and the adoption ACK completes
    ///         request #2 on the source (readiness + automatic initial UPDATE_VAULTS).
    /// @dev The factory under test plays both roles, so the two chains are simulated by snapshot replay: the
    ///      source half runs once to capture the tickets, the state is rolled back to the pre-request state
    ///      (the executor address is then free on the "destination"), the destination half runs under the
    ///      destination chain id and yields the adoption ACK, and the state is rolled back again so the
    ///      source half can be replayed and receive that ACK. Tickets and the ACK travel through memory.
    function testShouldRecoverViaAdoptionAfterTtlCancelAndLateAck() public requiresFactory {
        uint256 clean = vm.snapshotState();
        (, DeploymentTicket memory ticket1, DeploymentTicket memory ticket2) = _sourceCancelAndReRequest();

        // ---- Destination half: ticket #1 deploys (its ACK is the one that arrived late), ticket #2 adopts.
        vm.revertToState(clean);
        clean = vm.snapshotState();
        vm.chainId(REMOTE_CHAIN);
        factory.schedulePathConfig(LOCAL_CHAIN, LOCAL_EID, _factoryPathOptions(LOCAL_EID));
        _warpConfigDelay();
        factory.executePathConfig(LOCAL_CHAIN);

        // Ticket #1 reaches the destination inside its validity window (IL-8623); only its ACK is lost / late.
        vm.warp(ticket1.expiresAt - 1);
        _deliverTicket(ticket1, LOCAL_EID);
        assertGt(ticket1.executor.code.length, 0, "dispatcher deployed for request #1");
        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_ACK), "ACK #1 (lost / late)");

        vm.recordLogs();
        _deliverTicket(ticket2, LOCAL_EID);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool adopted;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(factory) &&
                logs[i].topics[0] == StargateCrosschainFactory.DispatcherTicketAdopted.selector
            ) adopted = true;
        }
        assertTrue(adopted, "DispatcherTicketAdopted emitted");
        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_ACK), "adoption ACK #2");
        assertEq(_lastAckDispatcher(), ticket2.executor, "ACK points at the existing dispatcher");
        bytes memory ackMsg2 = endpoint.lastMessage();

        // ---- Source half replayed: request #2 is pending and receives the adoption ACK.
        vm.revertToState(clean);
        vm.chainId(LOCAL_CHAIN);
        (ICrosschainExecutor exec, , ) = _sourceCancelAndReRequest();
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "not ready before the adoption ACK");
        uint256 sentBefore = endpoint.sentCount();

        endpoint.deliverLz(address(factory), REMOTE_EID, _factoryPeer(), GUID, ackMsg2);

        assertTrue(exec.isDispatcherReady(REMOTE_CHAIN), "dispatcher ready via the adoption ACK");
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "request #1 stays CANCELLED");
        assertEq(uint8(exec.deploymentStatus(2)), uint8(DeploymentStatus.DEPLOYED), "request #2 DEPLOYED");
        assertGt(endpoint.sentCount(), sentBefore, "initial UPDATE_VAULTS auto-sent");
        assertEq(uint8(_lastSentType()), uint8(MsgType.UPDATE_VAULTS), "auto initial UPDATE_VAULTS");
    }

    /// @notice Recovery is bound to the immutable commitment: a re-request whose immutable params differ
    ///         from the ones the dispatcher was deployed with is not adopted (and so gets no ACK).
    function testShouldRejectAdoptionWhenImmutableParamsChanged() public requiresFactory {
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("d1");
        DeploymentTicket memory ticket1 = _makeTicket(1, creator, userSalt, REMOTE_CHAIN);
        _deliverTicket(ticket1, REMOTE_EID);

        DeploymentTicket memory ticket2 = _makeTicket(2, creator, userSalt, REMOTE_CHAIN);
        // A different rescue delay, with the commitment recomputed so the ticket itself is self-consistent
        // (a bare bogus hash is rejected earlier, by `ImmutableParamsHashMismatch`).
        ticket2.rescueDelay = 4 days;
        ticket2.immutableParamsHash = keccak256(
            abi.encode(admin, guardian, uint256(4 days), REMOTE_CHAIN, DEST_CHAIN, ASSET_ID)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.TicketAdoptionCommitmentMismatch.selector,
                ticket1.immutableParamsHash,
                ticket2.immutableParamsHash
            )
        );
        _deliverTicket(ticket2, REMOTE_EID);
    }

    // ---------------------------------------------------------------------
    // IL-8259: TTL cancel is permissionless, so a stuck ticket does not wait on the vault's `execute()`
    // ---------------------------------------------------------------------

    function testShouldLetAnyoneCancelPendingDeploymentAfterTtl() public requiresFactory {
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest();
        StargateCrosschainFactory realFactory = StargateCrosschainFactory(payable(address(factory)));
        assertEq(realFactory.pendingCountByAsset(ASSET_ID), 1, "asset config frozen by the pending ticket");
        assertEq(realFactory.pendingCountByChain(REMOTE_CHAIN), 1, "path config frozen by the pending ticket");

        // past TTL + margin + the exclusive grace (IL-8649)
        vm.warp(
            block.timestamp +
                1 days +
                CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN +
                CrosschainConstants.DEPLOYMENT_CANCEL_GRACE
        );
        vm.prank(address(0xBEEF)); // neither the executor nor its manager
        realFactory.cancelPendingDeployment(1);

        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "executor resolved to CANCELLED");
        assertEq(realFactory.pendingCountByAsset(ASSET_ID), 0, "asset config released");
        assertEq(realFactory.pendingCountByChain(REMOTE_CHAIN), 0, "path config released");
    }

    function testShouldRejectCancelPendingDeploymentByAnyoneBeforeTtlPlusMargin() public requiresFactory {
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest();
        StargateCrosschainFactory realFactory = StargateCrosschainFactory(payable(address(factory)));
        uint256 executableAt = block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;

        vm.warp(executableAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.DeploymentTtlNotElapsed.selector,
                uint256(1),
                block.timestamp,
                executableAt
            )
        );
        realFactory.cancelPendingDeployment(1); // the owner is not exempt from the margin

        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.PENDING), "request still pending");
        assertEq(realFactory.pendingCountByChain(REMOTE_CHAIN), 1, "path config still frozen");
    }

    // ---------------------------------------------------------------------
    // IL-8649: exclusive grace for the owner / manager, then third parties
    // ---------------------------------------------------------------------

    function testShouldRejectThirdPartyCancelInsideGraceButAllowOwnerAndManager() public requiresFactory {
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest();
        StargateCrosschainFactory realFactory = StargateCrosschainFactory(payable(address(factory)));
        uint256 executableAt = block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        uint256 publicAt = executableAt + CrosschainConstants.DEPLOYMENT_CANCEL_GRACE;

        vm.warp(publicAt - 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.DeploymentTtlNotElapsed.selector,
                uint256(1),
                block.timestamp,
                publicAt
            )
        );
        realFactory.cancelPendingDeployment(1);

        vm.warp(executableAt);
        vm.prank(manager);
        realFactory.cancelPendingDeployment(1); // the executor's manager, directly
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "manager cancel inside grace");
    }

    function testShouldAllowOwnerCancelInsideGraceAndThirdPartyAfterIt() public requiresFactory {
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest();
        StargateCrosschainFactory realFactory = StargateCrosschainFactory(payable(address(factory)));
        uint256 executableAt = block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        vm.warp(executableAt);
        realFactory.cancelPendingDeployment(1); // this test contract owns the factory
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "owner cancel inside grace");
    }

    // ---------------------------------------------------------------------
    // IL-8649: a late ACK matching a CANCELLED request is accepted
    // ---------------------------------------------------------------------

    function _cancelByOwner() internal {
        vm.warp(block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1);
        StargateCrosschainFactory(payable(address(factory))).cancelPendingDeployment(1);
    }

    function testShouldAcceptLateAckAfterCancelWithoutSecondSlotRelease() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        StargateCrosschainFactory realFactory = StargateCrosschainFactory(payable(address(factory)));
        _cancelByOwner();
        assertEq(realFactory.pendingCountByAsset(ASSET_ID), 0, "released at cancel");

        // A second pending request (another executor, same asset and chain) holds both counters at 1; an
        // unconditional `_releasePending` in the late-ACK path would drive them to 0.
        ICrosschainExecutor other = ICrosschainExecutor(factory.createExecutor(keccak256("other"), _params(manager)));
        vm.deal(address(other), 100 ether);
        vm.startPrank(manager);
        other.registerChain(REMOTE_CHAIN, REMOTE_EID, _commandLaneOptions(REMOTE_EID));
        address[] memory otherVaults = new address[](1);
        otherVaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V2", "V2"));
        other.createDispatcher(REMOTE_CHAIN, otherVaults);
        vm.stopPrank();
        assertEq(realFactory.pendingCountByAsset(ASSET_ID), 1, "second request holds the asset counter");
        assertEq(realFactory.pendingCountByChain(REMOTE_CHAIN), 1, "second request holds the chain counter");

        DeploymentAck memory ack = DeploymentAck({
            requestId: 1,
            ticketHash: ticketHash,
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        vm.expectEmit(address(factory));
        emit StargateCrosschainFactory.DispatcherRequestLateAcked(1, REMOTE_CHAIN, address(exec));
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );

        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.DEPLOYED), "late ACK promoted the request");
        assertTrue(exec.isDispatcherReady(REMOTE_CHAIN), "dispatcher usable");
        assertEq(realFactory.pendingCountByAsset(ASSET_ID), 1, "no second release");
        assertEq(realFactory.pendingCountByChain(REMOTE_CHAIN), 1, "no second release");
        assertTrue(realFactory.assetFrozen(ASSET_ID), "asset frozen by the deployment");
        assertEq(realFactory.deploymentAttempts(address(exec), REMOTE_CHAIN), 0, "attempts cleared by the ACK");

        // It is single use: the request is DEPLOYED now.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DeploymentNotPending.selector, uint256(1)));
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );
    }

    /// @dev The executor refuses a late ACK once a newer request is pending (it would flip readiness under it);
    ///      the ACK stays retained and the newer request's own ACK still completes normally.
    function testShouldRefuseLateAckWhileNewerRequestPending() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        _cancelByOwner();
        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults); // request #2 pending

        DeploymentAck memory ack = DeploymentAck({
            requestId: 1,
            ticketHash: ticketHash,
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DeploymentRequestInvalid.selector, uint256(1)));
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "not ready");
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "request #1 stays CANCELLED");
    }

    /// @dev Pins the `hasDispatcher` branch of the executor's markReady: R1 cancelled, R2 requested and ACKed
    ///      (DEPLOYED), then R1's retained ACK must not be promoted on top of the existing dispatcher.
    function testShouldRefuseLateAckOfCancelledRequestAfterNewerRequestDeployed() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash1) = _createExecutorAndRequest();
        _cancelByOwner();
        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults); // request #2
        (, , bytes memory data) = _split(endpoint.lastMessage());
        bytes32 ticketHash2 = keccak256(abi.encode(CrosschainMessages.decodeDeploymentTicket(data)));

        DeploymentAck memory ack2 = DeploymentAck({
            requestId: 2,
            ticketHash: ticketHash2,
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack2)
        );
        assertEq(uint8(exec.deploymentStatus(2)), uint8(DeploymentStatus.DEPLOYED), "request #2 deployed");

        DeploymentAck memory ack1 = DeploymentAck({
            requestId: 1,
            ticketHash: ticketHash1,
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DeploymentRequestInvalid.selector, uint256(1)));
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack1)
        );
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "request #1 stays CANCELLED");
    }

    function testShouldKeepRejectingLateAckWithNonMatchingHashAfterCancel() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        _cancelByOwner();

        DeploymentAck memory ack = DeploymentAck({
            requestId: 1,
            ticketHash: bytes32(uint256(ticketHash) ^ 1),
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.TicketCommitmentMismatch.selector,
                ticketHash,
                bytes32(uint256(ticketHash) ^ 1)
            )
        );
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );

        ack = DeploymentAck({
            requestId: 1,
            ticketHash: ticketHash,
            dispatcher: address(0xBAD),
            dstChainId: REMOTE_CHAIN
        });
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.DispatcherAddressMismatch.selector, address(exec), address(0xBAD))
        );
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "still not ready");
    }

    /// @dev The griefing sequence of IL-8649: the ACK is retained by LayerZero because the executor's
    ///      callback reverts (unfunded UPDATE_VAULTS send); a stranger cancels to kill it; the operator funds the
    ///      executor and retries the same packet, which now ends DEPLOYED.
    function testShouldEndDeployedWhenCancelFrontRunsRetryOfRetainedAck() public requiresFactory {
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        DeploymentAck memory ack = DeploymentAck({
            requestId: 1,
            ticketHash: ticketHash,
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        bytes memory packet = CrosschainMessages.encodeDeploymentAck(ack);

        vm.deal(address(exec), 0); // unfunded: the initial UPDATE_VAULTS send reverts
        uint256 fee = endpoint.messagingFee();
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InsufficientNativeBudget.selector, 0, fee));
        endpoint.deliverLz(address(factory), REMOTE_EID, _factoryPeer(), GUID, packet);
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.PENDING), "ACK retained, still pending");

        vm.warp(
            block.timestamp +
                1 days +
                CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN +
                CrosschainConstants.DEPLOYMENT_CANCEL_GRACE
        );
        vm.prank(address(0xBEEF));
        StargateCrosschainFactory(payable(address(factory))).cancelPendingDeployment(1); // the griefer's cancel
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.CANCELLED), "cancelled by a stranger");

        vm.deal(address(exec), 100 ether); // the operator funds the executor and retries the retained packet
        endpoint.deliverLz(address(factory), REMOTE_EID, _factoryPeer(), GUID, packet);
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.DEPLOYED), "retry ends DEPLOYED");
        assertTrue(exec.isDispatcherReady(REMOTE_CHAIN), "dispatcher usable");
    }

    // ---------------------------------------------------------------------
    // IL-8261: a rescue cannot call the factory as the executor
    // ---------------------------------------------------------------------

    function testShouldRejectExecutorRescueCallingFactoryRequestDispatcher() public requiresFactory {
        ICrosschainExecutor exec = ICrosschainExecutor(factory.createExecutor(keccak256("src"), _params(manager)));
        vm.prank(manager);
        exec.registerChain(REMOTE_CHAIN, REMOTE_EID, _commandLaneOptions(REMOTE_EID));
        StargateCrosschainFactory realFactory = StargateCrosschainFactory(payable(address(factory)));

        // A ticket with rescue roles the executor does not have and no executor-side request record.
        address foreignAdmin = address(0xBAD1);
        address foreignGuardian = address(0xBAD2);
        uint256 foreignDelay = 5 minutes;
        DeploymentRequest memory request = DeploymentRequest({
            executor: address(exec),
            dstChainId: REMOTE_CHAIN,
            assetId: ASSET_ID,
            admin: foreignAdmin,
            rescueGuardian: foreignGuardian,
            rescueDelay: foreignDelay,
            immutableParamsHash: keccak256(
                abi.encode(foreignAdmin, foreignGuardian, foreignDelay, block.chainid, REMOTE_CHAIN, ASSET_ID)
            )
        });
        bytes memory cd = abi.encodeCall(ICrosschainFactory.requestDispatcher, (request));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueFactoryCall.selector, address(realFactory)));
        RescueModule(address(exec)).scheduleRescue(address(realFactory), 0, cd);

        assertEq(RescueModule(address(exec)).rescueCount(), 0, "nothing queued");
        assertEq(realFactory.requestCount(), 0, "no ticket opened");
        assertEq(realFactory.pendingCountByChain(REMOTE_CHAIN), 0, "path config not frozen");
    }

    // ---------------------------------------------------------------------
    // IL-8763: the factory's own rescue cannot call its executors' onlyFactory callbacks
    // ---------------------------------------------------------------------

    function _scheduleFactoryRescue(address target_, uint256 value_, bytes memory cd_) internal returns (uint256) {
        vm.prank(admin);
        return RescueModule(address(factory)).scheduleRescue(target_, value_, cd_);
    }

    /// @notice IL-8851 (G12): the shared `RescueLogicLib` rejects a `runWithContext` rescue on the Stargate factory
    ///         and on the Stargate executor (both hosts reach it through `RescueModule`), at schedule time.
    function testShouldRejectRunWithContextRescueOnStargateFactoryAndExecutor() public requiresFactory {
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest();
        address contextManager = address(0xC0C0);
        address[] memory targets = new address[](1);
        targets[0] = address(0xBEEF);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature("approve(address,uint256)", admin, type(uint256).max);
        bytes memory cd = abi.encodeCall(
            ContextManager.runWithContext,
            (ExecuteData({targets: targets, datas: datas}))
        );

        uint256 factoryCountBefore = RescueModule(address(factory)).rescueCount();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueContextCall.selector, contextManager));
        RescueModule(address(factory)).scheduleRescue(contextManager, 0, cd);
        assertEq(RescueModule(address(factory)).rescueCount(), factoryCountBefore, "factory: nothing queued");

        uint256 execCountBefore = RescueModule(address(exec)).rescueCount();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueContextCall.selector, contextManager));
        RescueModule(address(exec)).scheduleRescue(contextManager, 0, cd);
        assertEq(RescueModule(address(exec)).rescueCount(), execCountBefore, "executor: nothing queued");
    }

    function testShouldRejectFactoryRescueForgingOnDispatcherCreated() public requiresFactory {
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest();
        vm.warp(block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1);
        vm.prank(manager);
        exec.cancelDispatcherRequest(1); // CANCELLED on both sides, no ACK will ever arrive
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "not ready before the attack");

        bytes memory cd = abi.encodeCall(ICrosschainExecutor.onDispatcherCreated, (1, REMOTE_CHAIN, address(exec)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueExecutorCall.selector, address(exec)));
        RescueModule(address(factory)).scheduleRescue(address(exec), 0, cd);

        assertEq(RescueModule(address(factory)).rescueCount(), 0, "nothing queued");
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "no forged readiness");

        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V2", "V2"));
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults); // a real request is still possible
    }

    function testShouldRejectFactoryRescueOnAnyExecutorCall() public requiresFactory {
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest(); // request #1 PENDING
        RescueModule rm = RescueModule(address(factory));
        bytes[2] memory calls = [
            abi.encodeCall(ICrosschainExecutor.onDispatcherRequestFailed, (1)),
            abi.encodeCall(ICrosschainExecutor.onDispatcherRequestCancelled, (1))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueExecutorCall.selector, address(exec)));
            rm.scheduleRescue(address(exec), 0, calls[i]);
        }
        // Whole-target ban: a plain native transfer (empty calldata, value > 0) is rejected as well.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueExecutorCall.selector, address(exec)));
        rm.scheduleRescue(address(exec), 1 wei, "");

        assertEq(rm.rescueCount(), 0, "nothing queued");
        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.PENDING), "record untouched");
    }

    function testShouldRejectFactoryRescueOnExecutorCreatedAfterSchedule() public requiresFactory {
        bytes32 salt = keccak256("src");
        address future = factory.computeExecutorAddress(address(this), salt);
        assertEq(future.code.length, 0, "no code yet");
        RescueModule rm = RescueModule(address(factory));
        bytes memory cd = abi.encodeCall(ICrosschainExecutor.onDispatcherCreated, (1, REMOTE_CHAIN, future));
        uint256 rescueId = _scheduleFactoryRescue(future, 0, cd); // passes: not an executor yet

        ICrosschainExecutor exec = ICrosschainExecutor(factory.createExecutor(salt, _params(manager)));
        assertEq(address(exec), future, "CREATE3 address as predicted");
        vm.prank(manager);
        exec.registerChain(REMOTE_CHAIN, REMOTE_EID, _commandLaneOptions(REMOTE_EID));
        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults); // request #1 PENDING

        vm.warp(block.timestamp + rm.RESCUE_DELAY());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueExecutorCall.selector, address(exec)));
        rm.executeRescue(rescueId, cd);

        assertEq(uint8(exec.deploymentStatus(1)), uint8(DeploymentStatus.PENDING), "record stays PENDING");
        assertFalse(exec.isDispatcherReady(REMOTE_CHAIN), "hasDispatcher stays false");
    }

    function testFactoryRescueStillSweepsUnrelatedToken() public requiresFactory {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(factory), 5 ether);
        RescueModule rm = RescueModule(address(factory));
        bytes memory cd = abi.encodeCall(IERC20.transfer, (address(0xCAFE), 5 ether));
        uint256 rescueId = _scheduleFactoryRescue(address(other), 0, cd);
        vm.warp(block.timestamp + rm.RESCUE_DELAY());
        vm.prank(admin);
        rm.executeRescue(rescueId, cd);
        assertEq(other.balanceOf(address(0xCAFE)), 5 ether, "unrelated token swept");
    }

    // ---------------------------------------------------------------------
    // IL-8050: factory-held native fee ceiling (owner config surface)
    // ---------------------------------------------------------------------

    function testShouldLetOwnerSetMaxNativeFeeAndEmit() public requiresFactory {
        StargateCrosschainFactory realFactory = StargateCrosschainFactory(payable(address(factory)));
        vm.expectEmit(false, false, false, true, address(realFactory));
        emit StargateCrosschainFactory.MaxNativeFeeSet(7, 3 ether);
        realFactory.setMaxNativeFee(7, 3 ether);
        assertEq(realFactory.maxNativeFee(7), 3 ether, "ceiling stored");
    }

    function testShouldRejectMaxNativeFeeSetByNonOwner() public requiresFactory {
        StargateCrosschainFactory realFactory = StargateCrosschainFactory(payable(address(factory)));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        realFactory.setMaxNativeFee(7, 3 ether);
    }

    // ---------------------------------------------------------------------
    // IL-8565 / IL-8605: bounded deployment attempts and the factory's own fee ceiling
    // ---------------------------------------------------------------------

    function _requestAndCancel(ICrosschainExecutor exec_) internal {
        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        vm.prank(manager);
        exec_.createDispatcher(REMOTE_CHAIN, vaults);
        vm.warp(block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1);
        StargateCrosschainFactory(payable(address(factory))).cancelPendingDeployment(
            StargateCrosschainFactory(payable(address(factory))).requestCount()
        );
    }

    function testShouldRevertAfterMaxDeploymentAttempts() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest(); // attempt 1
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), 1, "first attempt counted");
        vm.warp(block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1);
        f.cancelPendingDeployment(1);
        _requestAndCancel(exec); // attempt 2
        _requestAndCancel(exec); // attempt 3
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), f.MAX_DEPLOYMENT_ATTEMPTS(), "cap reached");

        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        uint256 sentBefore = endpoint.sentCount();
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainFactory.DeploymentAttemptsExhausted.selector,
                address(exec),
                REMOTE_CHAIN,
                uint8(3)
            )
        );
        exec.createDispatcher(REMOTE_CHAIN, vaults);
        assertEq(endpoint.sentCount(), sentBefore, "no fee paid for the fourth ticket");
    }

    function testShouldNotResetAttemptsOnNackOrTtlCancel() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        DeploymentNack memory nack = DeploymentNack({
            requestId: 1,
            ticketHash: ticketHash,
            reason: uint8(NackReason.DESTINATION_VALIDATION)
        });
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentNack(nack)
        );
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), 1, "NACK keeps the counter");
        _requestAndCancel(exec);
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), 2, "TTL cancel keeps the counter");
    }

    function testShouldClearAttemptsOnSuccessfulAck() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        (ICrosschainExecutor exec, bytes32 ticketHash) = _createExecutorAndRequest();
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), 1, "counted while pending");
        DeploymentAck memory ack = DeploymentAck({
            requestId: 1,
            ticketHash: ticketHash,
            dispatcher: address(exec),
            dstChainId: REMOTE_CHAIN
        });
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            _factoryPeer(),
            GUID,
            CrosschainMessages.encodeDeploymentAck(ack)
        );
        assertTrue(exec.isDispatcherReady(REMOTE_CHAIN), "ready after ACK");
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), 0, "ACK deletes the counter");
    }

    function testShouldResetAttemptsOnlyByOwner() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        f.resetDeploymentAttempts(address(exec), REMOTE_CHAIN);
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), 1, "stranger changed nothing");

        vm.expectEmit(false, false, false, true, address(f));
        emit StargateCrosschainFactory.DeploymentAttemptsReset(address(exec), REMOTE_CHAIN);
        f.resetDeploymentAttempts(address(exec), REMOTE_CHAIN);
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), 0, "owner reset");
    }

    function testShouldCapFactoryOwnNativeFee() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        uint256 fee = endpoint.messagingFee();
        ICrosschainExecutor exec = ICrosschainExecutor(factory.createExecutor(keccak256("src"), _params(manager)));
        vm.deal(address(exec), 100 ether);
        vm.prank(manager);
        exec.registerChain(REMOTE_CHAIN, REMOTE_EID, _commandLaneOptions(REMOTE_EID));
        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));

        // One wei below the quote: the factory's own CREATE_DISPATCHER send is refused.
        f.setMaxNativeFee(REMOTE_CHAIN, fee - 1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NativeFeeTooHigh.selector, fee, fee - 1));
        exec.createDispatcher(REMOTE_CHAIN, vaults);

        // At the ceiling it goes out.
        f.setMaxNativeFee(REMOTE_CHAIN, fee);
        uint256 sentBefore = endpoint.sentCount();
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults);
        assertEq(endpoint.sentCount(), sentBefore + 1, "ticket sent at the ceiling");

        // The destination-side ACK is capped the same way (it answers to the ticket's source chain).
        f.setMaxNativeFee(REMOTE_CHAIN, 0);
        DeploymentTicket memory ticket = _makeTicket(1, address(0xAAA1), keccak256("a"), REMOTE_CHAIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NativeFeeTooHigh.selector, fee, uint256(0)));
        _deliverTicket(ticket, REMOTE_EID);
    }

    function testShouldAllowRequestAgainAfterOwnerReset() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        (ICrosschainExecutor exec, ) = _createExecutorAndRequest(); // attempt 1
        vm.warp(block.timestamp + 1 days + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1);
        f.cancelPendingDeployment(1);
        _requestAndCancel(exec); // attempt 2
        _requestAndCancel(exec); // attempt 3
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), f.MAX_DEPLOYMENT_ATTEMPTS(), "cap reached");

        f.resetDeploymentAttempts(address(exec), REMOTE_CHAIN);

        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        uint256 sentBefore = endpoint.sentCount();
        vm.prank(manager);
        exec.createDispatcher(REMOTE_CHAIN, vaults);
        assertEq(endpoint.sentCount(), sentBefore + 1, "fourth request goes out after the reset");
        assertEq(f.deploymentAttempts(address(exec), REMOTE_CHAIN), 1, "counter restarts at one");
    }

    function testShouldCapFactoryNackNativeFee() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        uint256 fee = endpoint.messagingFee();
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("occ-nack-cap");
        vm.etch(factory.computeExecutorAddress(creator, userSalt), hex"60006000fd");

        // The NACK answers to the ticket's source chain; a zero ceiling there blocks it.
        f.setMaxNativeFee(REMOTE_CHAIN, 0);
        uint256 sentBefore = endpoint.sentCount();
        DeploymentTicket memory ticket = _makeTicket(1, creator, userSalt, REMOTE_CHAIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NativeFeeTooHigh.selector, fee, uint256(0)));
        _deliverTicket(ticket, REMOTE_EID);
        assertEq(endpoint.sentCount(), sentBefore, "no NACK sent");
    }

    function testShouldDeployAfterRaisingCeilingAndRedelivering() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        uint256 fee = endpoint.messagingFee();
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("raise-and-redeliver");
        address predicted = factory.computeExecutorAddress(creator, userSalt);
        DeploymentTicket memory ticket = _makeTicket(1, creator, userSalt, REMOTE_CHAIN);

        f.setMaxNativeFee(REMOTE_CHAIN, 0);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NativeFeeTooHigh.selector, fee, uint256(0)));
        _deliverTicket(ticket, REMOTE_EID);
        assertEq(predicted.code.length, 0, "the reverted receive left no dispatcher behind");

        f.setMaxNativeFee(REMOTE_CHAIN, type(uint256).max);
        _deliverTicket(ticket, REMOTE_EID);
        assertGt(predicted.code.length, 0, "dispatcher deployed on redelivery");
        assertEq(uint8(_lastSentType()), uint8(MsgType.DEPLOYMENT_ACK), "ACK sent");
        assertEq(_lastAckDispatcher(), predicted, "ACK carries the deployed dispatcher");
    }

    function testShouldKeepAttemptCountersIndependentPerChainAndExecutor() public requiresFactory {
        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        (ICrosschainExecutor execA, ) = _createExecutorAndRequest(); // execA, REMOTE_CHAIN

        ICrosschainExecutor execB = ICrosschainExecutor(factory.createExecutor(keccak256("src-b"), _params(manager)));
        vm.deal(address(execB), 100 ether);
        vm.prank(manager);
        execB.registerChain(REMOTE_CHAIN, REMOTE_EID, _commandLaneOptions(REMOTE_EID));

        // A second registered path, so the same executor can request toward another chain.
        uint256 otherChain = 10;
        uint32 otherEid = 40010;
        f.schedulePathConfig(otherChain, otherEid, _factoryPathOptions(otherEid));
        _warpConfigDelay();
        f.executePathConfig(otherChain);
        vm.prank(manager);
        execA.registerChain(otherChain, otherEid, _commandLaneOptions(otherEid));

        address[] memory vaults = new address[](1);
        vaults[0] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        vm.prank(manager);
        execB.createDispatcher(REMOTE_CHAIN, vaults);
        vm.prank(manager);
        execA.createDispatcher(otherChain, vaults);

        assertEq(f.deploymentAttempts(address(execA), REMOTE_CHAIN), 1, "A / remote");
        assertEq(f.deploymentAttempts(address(execB), REMOTE_CHAIN), 1, "B / remote independent of A");
        assertEq(f.deploymentAttempts(address(execA), otherChain), 1, "A / other independent of A / remote");

        f.resetDeploymentAttempts(address(execA), REMOTE_CHAIN);
        assertEq(f.deploymentAttempts(address(execA), REMOTE_CHAIN), 0, "A / remote reset");
        assertEq(f.deploymentAttempts(address(execB), REMOTE_CHAIN), 1, "B untouched by A reset");
        assertEq(f.deploymentAttempts(address(execA), otherChain), 1, "A / other untouched by remote reset");
    }
}
