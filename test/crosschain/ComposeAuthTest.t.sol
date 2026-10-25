// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {CrosschainMessages, OutboundTransfer} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {IOAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";

/// @title ComposeAuthTest
/// @notice The four-fold `lzCompose` authentication each failing independently (wrong endpoint caller,
///         `_from` != pool, forged `composeFrom`, unregistered `srcEid`), the executor-side chain-binding
///         (`srcEid` bound to the pending recall's chain), and `lzReceive` wrong-peer / unregistered-eid
///         (plan §4.4 / risk #14).
contract ComposeAuthTest is CrosschainTestBase {
    uint256 internal constant OTHER_CHAIN = 10;
    uint32 internal constant OTHER_EID = 30111;

    bytes32 internal constant GUID = keccak256("compose-guid");

    function setUp() public {
        _baseSetUp();
    }

    function _envelope(bytes32 requestId_) internal pure returns (bytes memory) {
        return CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: requestId_}));
    }

    // ---------------------------------------------------------------------
    // Four-fold lzCompose check (each failing independently)
    // ---------------------------------------------------------------------

    function testShouldRejectComposeFromWrongEndpointCaller() public {
        _readyDispatcher();
        bytes memory msg_ = LzComposeBuilder.build(address(executor), REMOTE_EID, 40e6, _envelope(bytes32(uint256(1))));
        // Called directly (not via the endpoint): msg.sender != endpoint.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedEndpoint.selector, address(this)));
        executor.lzCompose(address(pool), GUID, msg_, address(0), "");
    }

    function testShouldRejectComposeFromNonPool() public {
        _readyDispatcher();
        bytes memory msg_ = LzComposeBuilder.build(address(executor), REMOTE_EID, 40e6, _envelope(bytes32(uint256(1))));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedStargatePool.selector, address(0xBAD)));
        endpoint.deliverCompose(address(executor), address(0xBAD), GUID, msg_);
    }

    function testShouldRejectForgedComposeFrom() public {
        _readyDispatcher();
        bytes32 forged = bytes32(uint256(uint160(address(0xBEEF))));
        bytes memory msg_ = LzComposeBuilder.buildRawFrom(forged, REMOTE_EID, 40e6, _envelope(bytes32(uint256(1))));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedComposeFrom.selector, forged));
        endpoint.deliverCompose(address(executor), address(pool), GUID, msg_);
    }

    function testShouldRejectComposeFromUnregisteredSrcEid() public {
        _readyDispatcher();
        bytes memory msg_ = LzComposeBuilder.build(address(executor), OTHER_EID, 40e6, _envelope(bytes32(uint256(1))));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnknownEid.selector, OTHER_EID));
        endpoint.deliverCompose(address(executor), address(pool), GUID, msg_);
    }

    // ---------------------------------------------------------------------
    // Executor-side chain binding: a compose from chain C cannot satisfy a recall bound to chain B
    // ---------------------------------------------------------------------

    function testShouldRejectComposeBoundToDifferentChain() public {
        _readyDispatcher();
        // Register a second chain C so its EID maps to a registered chain (auth passes the base).
        factory.setPath(OTHER_CHAIN, OTHER_EID);
        vm.prank(manager);
        executor.registerChain(OTHER_CHAIN, OTHER_EID, _commandLaneOptions(OTHER_EID));

        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0); // bound to REMOTE_CHAIN

        // A well-formed compose that authenticates but arrives tagged as chain C must be rejected.
        bytes memory msg_ = LzComposeBuilder.build(address(executor), OTHER_EID, 40e6, _envelope(requestId));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WrongSourceChain.selector, REMOTE_CHAIN, OTHER_CHAIN));
        endpoint.deliverCompose(address(executor), address(pool), GUID, msg_);
    }

    function testShouldAcceptFullyAuthenticatedCompose() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        // All four checks pass -> reaches _onReturnCompose (compose-first order -> reserve).
        usdc.mint(address(executor), 40e6);
        bytes memory msg_ = LzComposeBuilder.build(address(executor), REMOTE_EID, 40e6, _envelope(requestId));
        endpoint.deliverCompose(address(executor), address(pool), GUID, msg_);
        assertEq(executor.pendingArrivalReserve(), 40e6, "authenticated compose reached business logic");
    }

    // ---------------------------------------------------------------------
    // Compose integrity reverts (IL-9067): ReturnNotFound / GuidMismatch revert on purpose
    // ---------------------------------------------------------------------

    /// @dev Recall 40e6 and deliver the authenticated `RETURN_STARTED` first (order (a)) with guid `RGUID`.
    function _orderAReturnStarted() internal returns (bytes32 requestId) {
        _readyDispatcher();
        _settle100();
        (requestId, , ) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
    }

    function testShouldRejectComposeForUnknownReturn() public {
        _readyDispatcher();
        _settle100();
        bytes32 unknown = bytes32(uint256(0xDEAD));
        usdc.mint(address(executor), 40e6);
        bytes memory msg_ = LzComposeBuilder.build(address(executor), REMOTE_EID, 40e6, _envelope(unknown));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ReturnNotFound.selector, unknown));
        endpoint.deliverCompose(address(executor), address(pool), GUID, msg_);
        assertEq(executor.idleLedger(), 0, "nothing booked");
        assertEq(executor.pendingArrivalReserve(), 0, "no reserve booked");
    }

    function testShouldRejectOrderAComposeWithWrongGuid() public {
        bytes32 requestId = _orderAReturnStarted();
        uint256 inFlightBefore = executor.returnInFlight(REMOTE_CHAIN);
        uint256 pendingBefore = executor.pendingTransferCount(REMOTE_CHAIN);
        assertEq(inFlightBefore, 40e6, "expected credit is in flight");

        // The compose carries a guid that differs from the RETURN_STARTED metadata guid.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.GuidMismatch.selector, RGUID, GUID));
        _deliverReturnCompose(requestId, GUID, 40e6);

        // The whole delivery rolled back: no bucket moved and the record did not record the compose.
        assertEq(executor.idleLedger(), 0, "idle unchanged");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), inFlightBefore, "in-flight unchanged");
        assertEq(executor.pendingArrivalReserve(), 0, "reserve unchanged");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), pendingBefore, "slot count unchanged");

        // The retained compose, delivered with the metadata guid, finalizes (it would be a silent
        // duplicate no-op if the rejected delivery had left `composeArrived` set).
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.idleLedger(), 40e6, "idle credited by the actual amount");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "expected credit removed from in-flight");
        assertEq(executor.pendingArrivalReserve(), 0, "no reserve in order (a)");

        // The record is finalized: a further compose is a no-op.
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.idleLedger(), 40e6, "finalized record ignores a duplicate");
    }

    function testShouldExitMismatchingComposeThroughDropFromNav() public {
        bytes32 requestId = _orderAReturnStarted();
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.GuidMismatch.selector, RGUID, GUID));
        _deliverReturnCompose(requestId, GUID, 40e6);

        // The documented exit: the timelocked DROP_FROM_NAV finalizes the record and removes the credit.
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, requestId, ResolveOutcome.DROP_FROM_NAV);
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "credit dropped from NAV");

        // Retrying the retained, still mismatching compose is now a no-op instead of a revert.
        _deliverReturnCompose(requestId, GUID, 40e6);
        assertEq(executor.idleLedger(), 0, "tokens stay untracked surplus");
        assertEq(executor.pendingArrivalReserve(), 0, "no reserve booked");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "in-flight stays dropped");
    }

    // ---------------------------------------------------------------------
    // lzReceive peer checks
    // ---------------------------------------------------------------------

    function testShouldRejectLzReceiveFromWrongPeer() public {
        _readyDispatcher();
        bytes32 wrongSender = bytes32(uint256(uint160(address(0xBAD))));
        bytes memory envelope = _envelope(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, REMOTE_EID, wrongSender));
        endpoint.deliverLz(address(executor), REMOTE_EID, wrongSender, GUID, envelope);
    }

    function testShouldRejectLzReceiveFromUnregisteredEid() public {
        _readyDispatcher();
        bytes memory envelope = _envelope(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, OTHER_EID));
        endpoint.deliverLz(address(executor), OTHER_EID, _selfPeer(), GUID, envelope);
    }
}
