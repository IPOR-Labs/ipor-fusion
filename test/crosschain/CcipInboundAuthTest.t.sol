// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipAppBase} from "../../contracts/crosschain/ccip/base/CcipAppBase.sol";
import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";

/// @title CcipInboundAuthTestBase
/// @notice Shared envelope builder for the CCIP inbound authentication suites (IL-9014).
/// @dev Every negative case uses a WELL-FORMED envelope of a type the host handles, so the revert can only come
///      from the guard under test: an empty or undecodable payload would revert in the envelope decoder even with
///      the guard removed. Each negative case is paired with a positive twin that delivers the SAME envelope and
///      `messageId` from the real peer, which proves the rejection did not consume the `messageId` and that the
///      envelope passes authentication when sent by the right party.
abstract contract CcipInboundAuthTestBase is Test {
    bytes32 internal constant MESSAGE_ID = keccak256("ccip-inbound-auth-message");
    uint64 internal constant UNKNOWN_SELECTOR = 777;
    address internal constant FOREIGN_SENDER = address(0xBAD);

    function _message(
        bytes memory envelope_,
        uint64 selector_,
        address sender_
    ) internal pure returns (CcipClient.Any2EVMMessage memory) {
        return
            CcipClient.Any2EVMMessage({
                messageId: MESSAGE_ID,
                sourceChainSelector: selector_,
                sender: abi.encode(sender_),
                data: envelope_,
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            });
    }
}

/// @title CcipInboundAuthExecutorDispatcherTest
/// @notice IL-9014: the router / selector / peer guards of `CcipAppBase.ccipReceive` on the executor and the
///         dispatcher. The previous `testShouldRejectWrongPeer` sent an empty message and passed with the peer
///         check deleted, so no test protected inbound authentication.
contract CcipInboundAuthExecutorDispatcherTest is CcipExecutorFixture, CcipInboundAuthTestBase {
    /// @dev Executor handles (and ignores) the reserved type; the dispatcher handles BALANCE_REQUEST.
    function _executorEnvelope() internal pure returns (bytes memory) {
        return CcipMessages.encode(CcipMsgType.UPDATE_VAULTS_ACK, "");
    }

    function _dispatcherEnvelope() internal pure returns (bytes memory) {
        return CcipMessages.encode(CcipMsgType.BALANCE_REQUEST, "");
    }

    function setUp() public {
        _fixtureSetUp();
    }

    // ---------------------------------------------------------------------
    // Executor
    // ---------------------------------------------------------------------

    function testExecutorRejectsCallerThatIsNotTheRouter() public {
        CcipClient.Any2EVMMessage memory message = _message(
            _executorEnvelope(),
            DISPATCHER_SELECTOR,
            address(dispatcher)
        );
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipInvalidRouter.selector, address(this)));
        executor.ccipReceive(message);
        assertFalse(executor.processedCcipMessage(MESSAGE_ID));
    }

    function testExecutorRejectsUnknownSelector() public {
        CcipClient.Any2EVMMessage memory message = _message(_executorEnvelope(), UNKNOWN_SELECTOR, address(dispatcher));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipUnknownSelector.selector, UNKNOWN_SELECTOR));
        executor.ccipReceive(message);
        assertFalse(executor.processedCcipMessage(MESSAGE_ID));
    }

    function testExecutorRejectsForeignPeerThenAcceptsTheSameEnvelopeFromThePeer() public {
        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(CcipAppBase.CcipUnauthorizedPeer.selector, DISPATCHER_SELECTOR, FOREIGN_SENDER)
        );
        executor.ccipReceive(_message(_executorEnvelope(), DISPATCHER_SELECTOR, FOREIGN_SENDER));
        assertFalse(executor.processedCcipMessage(MESSAGE_ID), "rejection must not consume the message id");

        vm.prank(address(router));
        executor.ccipReceive(_message(_executorEnvelope(), DISPATCHER_SELECTOR, address(dispatcher)));
        assertTrue(executor.processedCcipMessage(MESSAGE_ID), "same envelope from the peer is accepted");
    }

    // ---------------------------------------------------------------------
    // Dispatcher
    // ---------------------------------------------------------------------

    function testDispatcherRejectsCallerThatIsNotTheRouter() public {
        CcipClient.Any2EVMMessage memory message = _message(
            _dispatcherEnvelope(),
            EXECUTOR_SELECTOR,
            address(executor)
        );
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipInvalidRouter.selector, address(this)));
        dispatcher.ccipReceive(message);
        assertFalse(dispatcher.processedCcipMessage(MESSAGE_ID));
    }

    function testDispatcherRejectsUnknownSelector() public {
        CcipClient.Any2EVMMessage memory message = _message(_dispatcherEnvelope(), UNKNOWN_SELECTOR, address(executor));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipUnknownSelector.selector, UNKNOWN_SELECTOR));
        dispatcher.ccipReceive(message);
        assertFalse(dispatcher.processedCcipMessage(MESSAGE_ID));
    }

    function testDispatcherRejectsForeignPeerThenAcceptsTheSameEnvelopeFromThePeer() public {
        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(CcipAppBase.CcipUnauthorizedPeer.selector, EXECUTOR_SELECTOR, FOREIGN_SENDER)
        );
        dispatcher.ccipReceive(_message(_dispatcherEnvelope(), EXECUTOR_SELECTOR, FOREIGN_SENDER));
        assertFalse(dispatcher.processedCcipMessage(MESSAGE_ID), "rejection must not consume the message id");

        vm.prank(address(router));
        dispatcher.ccipReceive(_message(_dispatcherEnvelope(), EXECUTOR_SELECTOR, address(executor)));
        assertTrue(dispatcher.processedCcipMessage(MESSAGE_ID), "same envelope from the peer is accepted");
    }
}

/// @title CcipInboundAuthFactoryTest
/// @notice IL-9014: the same guards on the CCIP factory. One factory instance is its own peer on the remote chain
///         (same fixture shape as `CcipFactoryDeploymentRecoveryTest`).
contract CcipInboundAuthFactoryTest is CcipInboundAuthTestBase {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant REMOTE_SELECTOR = 15971525489660198786;

    MockCcipRouter internal router;
    CcipCrosschainFactory internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        factory = new CcipCrosschainFactory(address(router), address(this));
        CcipRouteConfig memory route = CcipRouteConfig({
            chainSelector: REMOTE_SELECTOR,
            peer: address(factory),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 700_000,
            maxFee: 0.01 ether,
            enabled: true
        });
        factory.scheduleFactoryRoute(REMOTE_CHAIN, route);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeFactoryRoute(REMOTE_CHAIN, route);
    }

    /// @dev DEPLOYMENT_ACK for an executor the factory never created: past authentication it reaches the payload
    ///      handler and reverts `InvalidExecutor`, which tells "authenticated" apart from "rejected".
    function _envelope() internal pure returns (bytes memory) {
        return CcipMessages.encode(CcipMsgType.DEPLOYMENT_ACK, abi.encode(address(0xE0), REMOTE_CHAIN, bytes32(0)));
    }

    function testFactoryRejectsCallerThatIsNotTheRouter() public {
        CcipClient.Any2EVMMessage memory message = _message(_envelope(), REMOTE_SELECTOR, address(factory));
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipInvalidRouter.selector, address(this)));
        factory.ccipReceive(message);
        assertFalse(factory.processedCcipMessage(MESSAGE_ID));
    }

    function testFactoryRejectsUnknownSelector() public {
        CcipClient.Any2EVMMessage memory message = _message(_envelope(), UNKNOWN_SELECTOR, address(factory));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipUnknownSelector.selector, UNKNOWN_SELECTOR));
        factory.ccipReceive(message);
        assertFalse(factory.processedCcipMessage(MESSAGE_ID));
    }

    function testFactoryRejectsForeignPeerThenTheSameEnvelopeFromThePeerReachesTheHandler() public {
        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(CcipAppBase.CcipUnauthorizedPeer.selector, REMOTE_SELECTOR, FOREIGN_SENDER)
        );
        factory.ccipReceive(_message(_envelope(), REMOTE_SELECTOR, FOREIGN_SENDER));
        assertFalse(factory.processedCcipMessage(MESSAGE_ID), "rejection must not consume the message id");

        // From the real peer the envelope is authenticated and only the payload handler refuses it.
        vm.prank(address(router));
        vm.expectRevert(CcipCrosschainFactory.InvalidExecutor.selector);
        factory.ccipReceive(_message(_envelope(), REMOTE_SELECTOR, address(factory)));
    }
}
