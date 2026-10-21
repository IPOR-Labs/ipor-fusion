// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {CrosschainMessages, OutboundTransfer} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
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
