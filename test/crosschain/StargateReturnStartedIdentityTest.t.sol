// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainMessages, ReturnStarted} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateReturnStartedIdentityTest
/// @notice IL-9172 (stargate-exec C-014): `RETURN_STARTED` identity. Metadata for a recall of chain B that arrives
///         from another registered chain C is refused for an open record and for a terminal (`DROP_FROM_NAV`)
///         record, and metadata whose guid differs from the one a compose-first delivery already bound is refused
///         with `GuidMismatch`. Every refusal leaves buckets, pending count and both frontiers untouched.
contract StargateReturnStartedIdentityTest is CrosschainTestBase {
    uint256 internal constant CHAIN_C = 10;
    uint32 internal constant EID_C = 30111;
    bytes32 internal constant GUID_A = keccak256("return-guid-A");
    bytes32 internal constant GUID_B = keccak256("return-guid-B");

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100(); // settled B = 100e6, frontier B = 1
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

    function _startedFromC(bytes32 requestId_, bytes32 guid_, uint64 version_) internal {
        endpoint.deliverLz(
            address(executor),
            EID_C,
            _selfPeer(),
            keccak256("guid-c"),
            CrosschainMessages.encodeReturnStarted(
                ReturnStarted({
                    requestId: requestId_,
                    guid: guid_,
                    amountSentSD: 40e6,
                    amountReceivedSD: 40e6,
                    stateVersion: version_,
                    remoteBalanceSD: 0
                })
            )
        );
    }

    function _dropFromNav(bytes32 id_) internal {
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id_, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id_, ResolveOutcome.DROP_FROM_NAV);
    }

    struct Snapshot {
        uint64 frontierB;
        uint64 frontierC;
        uint256 settledB;
        uint256 returnInFlightB;
        uint256 idle;
        uint256 reserve;
        uint256 pendingB;
        uint256 pendingC;
    }

    function _snap() internal view returns (Snapshot memory s) {
        s.frontierB = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        s.frontierC = executor.acknowledgedRemoteStateVersion(CHAIN_C);
        s.settledB = executor.settledRemoteBalance(REMOTE_CHAIN);
        s.returnInFlightB = executor.returnInFlight(REMOTE_CHAIN);
        s.idle = executor.idleLedger();
        s.reserve = executor.pendingArrivalReserve();
        s.pendingB = executor.pendingTransferCount(REMOTE_CHAIN);
        s.pendingC = executor.pendingTransferCount(CHAIN_C);
    }

    function _assertUnchanged(Snapshot memory a_) internal view {
        Snapshot memory b = _snap();
        assertEq(b.frontierB, a_.frontierB, "frontier B unchanged");
        assertEq(b.frontierC, a_.frontierC, "frontier C unchanged");
        assertEq(b.settledB, a_.settledB, "settledRemoteBalance B unchanged");
        assertEq(b.returnInFlightB, a_.returnInFlightB, "returnInFlight B unchanged");
        assertEq(b.idle, a_.idle, "idleLedger unchanged");
        assertEq(b.reserve, a_.reserve, "pendingArrivalReserve unchanged");
        assertEq(b.pendingB, a_.pendingB, "pendingTransferCount B unchanged");
        assertEq(b.pendingC, a_.pendingC, "pendingTransferCount C unchanged");
    }

    /// @notice Open record (`:1319`): metadata from C is refused, the genuine one then books the return.
    function testReturnStartedFromAnotherChainIsRefusedForAnOpenRecord() public {
        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        Snapshot memory before = _snap();

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WrongSourceChain.selector, REMOTE_CHAIN, CHAIN_C));
        _startedFromC(requestId, GUID_A, 2);
        _assertUnchanged(before);

        _deliverReturnStarted(requestId, GUID_A, 40e6, 40e6, 2);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "authentic metadata advances frontier B");
        assertEq(executor.acknowledgedRemoteStateVersion(CHAIN_C), 0, "frontier C untouched");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "authentic metadata debits settled");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "authentic metadata books return in flight");
    }

    /// @notice Terminal record after `DROP_FROM_NAV` (`:1264`): late metadata from C is refused; the genuine one
    ///         from B still applies its late debit.
    function testReturnStartedFromAnotherChainIsRefusedForADroppedRecord() public {
        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        _dropFromNav(requestId);
        Snapshot memory before = _snap();

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WrongSourceChain.selector, REMOTE_CHAIN, CHAIN_C));
        _startedFromC(requestId, GUID_A, 2);
        _assertUnchanged(before);

        _deliverReturnStarted(requestId, GUID_A, 40e6, 40e6, 2);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "late metadata advances frontier B");
        assertEq(executor.acknowledgedRemoteStateVersion(CHAIN_C), 0, "frontier C untouched");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "late debit applied once");
    }

    /// @notice Compose-first with guid A, then metadata carrying guid B (`:1358`): refused, nothing moves.
    function testReturnStartedWithAGuidDifferingFromTheComposeIsRefused() public {
        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, GUID_A, 40e6);
        assertEq(executor.pendingArrivalReserve(), 40e6, "precondition: compose reserved");
        Snapshot memory before = _snap();

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.GuidMismatch.selector, GUID_A, GUID_B));
        _deliverReturnStarted(requestId, GUID_B, 40e6, 40e6, 2);
        _assertUnchanged(before);

        _deliverReturnStarted(requestId, GUID_A, 40e6, 40e6, 2);
        assertEq(executor.idleLedger(), 40e6, "authentic metadata finalizes into idle");
        assertEq(executor.pendingArrivalReserve(), 0, "reserve released");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "settled debited");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "record resolved");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "frontier B advanced");
    }
}
