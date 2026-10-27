// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainMessages, ReturnRejected} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {ReturnRejectReason} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateReturnRejectedIdentityTest
/// @notice IL-9174 (stargate-exec C-016): `RETURN_REJECTED` must be bound to the recall's chain. A rejection for a
///         live recall of chain B that arrives from another registered chain C would otherwise finalize the recall
///         (clearing the active request and the pending record) without B ever having refused it.
contract StargateReturnRejectedIdentityTest is CrosschainTestBase {
    uint256 internal constant CHAIN_C = 10;
    uint32 internal constant EID_C = 30111;

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100();
        _readyChainC();
    }

    function _readyChainC() internal {
        factory.setPath(CHAIN_C, EID_C);
        vm.prank(manager);
        executor.registerChain(CHAIN_C, EID_C, _commandLaneOptions(EID_C));
        vm.prank(manager);
        executor.createDispatcher(CHAIN_C, new address[](0));
        factory.ackDispatcher(address(executor), 2, CHAIN_C);
    }

    function _rejectedFromC(bytes32 requestId_) internal {
        endpoint.deliverLz(
            address(executor),
            EID_C,
            _selfPeer(),
            keccak256("guid-c"),
            CrosschainMessages.encodeReturnRejected(
                ReturnRejected({requestId: requestId_, reason: ReturnRejectReason.NO_TRACKED_IDLE})
            )
        );
    }

    /// @dev While the recall is live, a second recall for the same chain is refused naming this request.
    function _assertRecallStillActive(bytes32 requestId_) internal {
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ActiveReturnRequestExists.selector, REMOTE_CHAIN, requestId_)
        );
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e6, 0, "");
    }

    function testReturnRejectedFromAnotherRegisteredChainIsRefused() public {
        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "precondition: recall pending");
        _assertRecallStillActive(requestId);
        uint64 frontierB = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        uint64 frontierC = executor.acknowledgedRemoteStateVersion(CHAIN_C);

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WrongSourceChain.selector, REMOTE_CHAIN, CHAIN_C));
        _rejectedFromC(requestId);

        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "recall record still pending");
        assertEq(executor.pendingTransferCount(CHAIN_C), 0, "nothing pending on C");
        _assertRecallStillActive(requestId);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), frontierB, "frontier B unchanged");
        assertEq(executor.acknowledgedRemoteStateVersion(CHAIN_C), frontierC, "frontier C unchanged");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "settled unchanged");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "no return in flight");
    }

    /// @notice Control: the genuine rejection from B (after the refused one) ends the recall.
    function testAuthenticReturnRejectedFromTheRecallChainFinalizes() public {
        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WrongSourceChain.selector, REMOTE_CHAIN, CHAIN_C));
        _rejectedFromC(requestId);

        _deliverReturnRejected(requestId);

        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "recall record finalized");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "rejected recall moved no value");
        // The active request slot is free again: a new recall is accepted.
        (bytes32 requestId2, , ) = _requestAssets(10e6, 0);
        assertTrue(requestId2 != requestId, "a fresh recall is allowed");
    }
}
