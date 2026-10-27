// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainMessages, TransferSettled} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

/// @title StargateTransferSettledIdentityTest
/// @notice IL-9171 (stargate-exec C-013): a live `TRANSFER_SETTLED` must be bound to the record's chain and guid.
///         The executor has two registered chains (B = `REMOTE_CHAIN`, C); an outbound transfer to B is open, and
///         a settlement for it that arrives from C, or from B with a foreign guid, must be refused with the exact
///         selector and arguments while leaving every bucket and both version frontiers untouched.
contract StargateTransferSettledIdentityTest is CrosschainTestBase {
    uint256 internal constant CHAIN_C = 10;
    uint32 internal constant EID_C = 30111;

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
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

    function _settledEnvelope(
        bytes32 transferId_,
        bytes32 guid_,
        uint256 amountSD_,
        uint64 version_
    ) internal pure returns (bytes memory) {
        return
            CrosschainMessages.encodeTransferSettled(
                TransferSettled({
                    transferId: transferId_,
                    guid: guid_,
                    amountReceivedSD: amountSD_,
                    stateVersion: version_
                })
            );
    }

    struct Snapshot {
        uint64 frontierB;
        uint64 frontierC;
        uint256 outboundB;
        uint256 settledB;
        uint256 settledC;
        uint256 pendingB;
    }

    function _snap() internal view returns (Snapshot memory s) {
        s.frontierB = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        s.frontierC = executor.acknowledgedRemoteStateVersion(CHAIN_C);
        s.outboundB = executor.outboundInFlight(REMOTE_CHAIN);
        s.settledB = executor.settledRemoteBalance(REMOTE_CHAIN);
        s.settledC = executor.settledRemoteBalance(CHAIN_C);
        s.pendingB = executor.pendingTransferCount(REMOTE_CHAIN);
    }

    function _assertUnchanged(Snapshot memory a_) internal view {
        Snapshot memory b = _snap();
        assertEq(b.frontierB, a_.frontierB, "frontier B unchanged");
        assertEq(b.frontierC, a_.frontierC, "frontier C unchanged");
        assertEq(b.outboundB, a_.outboundB, "outboundInFlight B unchanged");
        assertEq(b.settledB, a_.settledB, "settledRemoteBalance B unchanged");
        assertEq(b.settledC, a_.settledC, "settledRemoteBalance C unchanged");
        assertEq(b.pendingB, a_.pendingB, "pendingTransferCount B unchanged");
    }

    /// @notice A settlement for B's record that arrives from the other registered chain C is refused.
    function testTransferSettledFromAnotherRegisteredChainIsRefused() public {
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(100e6, 0);
        Snapshot memory before = _snap();
        assertEq(before.outboundB, 100e6, "precondition: transfer open");
        assertEq(before.pendingB, 1, "precondition: one pending record");

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WrongSourceChain.selector, REMOTE_CHAIN, CHAIN_C));
        endpoint.deliverLz(
            address(executor),
            EID_C,
            _selfPeer(),
            keccak256("guid-c"),
            _settledEnvelope(transferId, guid, 100e6, 1)
        );

        _assertUnchanged(before);
    }

    /// @notice A settlement from the right chain but carrying a foreign guid is refused.
    function testTransferSettledWithAForeignGuidIsRefused() public {
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(100e6, 0);
        Snapshot memory before = _snap();
        bytes32 foreignGuid = keccak256("foreign-guid");
        assertTrue(foreignGuid != guid, "precondition: guid differs");

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.GuidMismatch.selector, guid, foreignGuid));
        _deliverTransferSettled(transferId, foreignGuid, 100e6, 1);

        _assertUnchanged(before);
    }

    /// @notice Control: after both refusals the authentic settlement still applies.
    function testAuthenticTransferSettledStillSettlesAfterRefusals() public {
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(100e6, 0);

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WrongSourceChain.selector, REMOTE_CHAIN, CHAIN_C));
        endpoint.deliverLz(
            address(executor),
            EID_C,
            _selfPeer(),
            keccak256("guid-c"),
            _settledEnvelope(transferId, guid, 100e6, 1)
        );
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.GuidMismatch.selector, guid, keccak256("foreign")));
        _deliverTransferSettled(transferId, keccak256("foreign"), 100e6, 1);

        _deliverTransferSettled(transferId, guid, 100e6, 1);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "frontier B advanced");
        assertEq(executor.acknowledgedRemoteStateVersion(CHAIN_C), 0, "frontier C untouched");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "in-flight cleared");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "settled credited");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "record resolved");
    }
}
