// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {StargateForkBase} from "./StargateForkBase.sol";

/// @title StargateLzRecoveryForkTest
/// @notice LayerZero failure paths on the REAL EndpointV2 for the Stargate transport apps (IL-8458):
///         - a failed `lzReceive` (out of gas, or a reverting handler) leaves the payload verified, and anyone can
///           re-execute it once the cause is fixed;
///         - `skip`, `clear` and `nilify` work for these apps. `StargateLzOAppBase` clears the LayerZero delegate
///           in its constructor, so the only caller the endpoint accepts is the app itself; the tests prove the
///           generic timelocked rescue (`scheduleRescue(endpoint, 0, calldata)` -> `executeRescue`) reaches the
///           endpoint, passes `_requireNotFactoryTarget` / `_requireSafeProtectedTokenCall` and the
///           post-rescue tracked-ledger invariant, and that the endpoint accepts the app as the caller.
contract StargateLzRecoveryForkTest is StargateForkBase {
    bytes32 internal constant NIL_PAYLOAD_HASH = bytes32(type(uint256).max);

    uint128 internal constant UNDER_FLOOR_GAS = 200_000;

    function setUp() public {
        _createForks();
        _deployApps();
        _bringUp();
    }

    /// @notice A delivery budget under the dispatcher's gas floor (200k, not a registrable lane any more) is below
    ///         what the dispatcher needs for a real UPDATE_VAULTS (~0.6M, see `StargateRoundTripForkTest`). Delivery
    ///         with that budget fails, the payload stays verified, and a permissionless re-execution with more gas
    ///         succeeds — so an under-provisioned lane delays delivery but does not lose messages.
    function testForkOutOfGasLzReceiveStaysVerifiedAndAnyoneRetriesWithMoreGas() public {
        Packet memory packet = _pendingUpdateVaults();

        vm.selectFork(arbitrumFork);
        Origin memory origin = _verify(packet);
        (bool ok,) = _lzReceive(origin, packet, UNDER_FLOOR_GAS);
        assertFalse(ok, "200k is not enough for the dispatcher's UPDATE_VAULTS");
        _assertStillVerified(packet);
        assertEq(dispatcher.commandConfigEpoch(), 1, "nothing applied");

        vm.prank(makeAddr("anyone"));
        (ok,) = _lzReceive(origin, packet, COMMAND_LANE_GAS);
        assertTrue(ok, "permissionless re-execution with enough gas succeeds");
        assertEq(dispatcher.commandConfigEpoch(), 2, "UPDATE_VAULTS applied on retry");
    }

    /// @notice A handler that reverts (dispatcher cannot pay its ACK: no native budget) leaves the payload
    ///         verified; after the budget is topped up the same payload executes.
    function testForkRevertingLzReceiveRetriesAfterCauseIsFixed() public {
        Packet memory packet = _pendingUpdateVaults();

        vm.selectFork(arbitrumFork);
        vm.deal(APP, 0);
        Origin memory origin = _verify(packet);
        (bool ok,) = _lzReceive(origin, packet, COMMAND_LANE_GAS);
        assertFalse(ok, "reverts: the ACK cannot be paid");
        _assertStillVerified(packet);

        vm.deal(APP, 1 ether);
        (ok,) = _lzReceive(origin, packet, COMMAND_LANE_GAS);
        assertTrue(ok, "same payload executes after the top-up");
        assertEq(dispatcher.commandConfigEpoch(), 2);
    }

    /// @notice `skip` of the next, not-yet-verified nonce through the dispatcher's timelocked generic rescue.
    function testForkDispatcherSkipsANonceThroughGenericRescue() public {
        Packet memory packet = _pendingUpdateVaults();
        uint64 nonce = packet.origin.nonce;

        vm.selectFork(arbitrumFork);
        assertEq(ENDPOINT.inboundNonce(APP, ETHEREUM_EID, bytes32(uint256(uint160(APP)))), nonce - 1);
        bytes memory callData =
            abi.encodeCall(ENDPOINT.skip, (APP, ETHEREUM_EID, bytes32(uint256(uint160(APP))), nonce));

        // The app has no LayerZero delegate, so the admin cannot call the endpoint directly: the rescue is the
        // only route.
        (bool ok, bytes memory ret) = LZ_ENDPOINT.staticcall(abi.encodeWithSignature("delegates(address)", APP));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), address(0), "no LayerZero delegate");
        vm.prank(admin);
        (ok,) = LZ_ENDPOINT.call(callData);
        assertFalse(ok, "the endpoint rejects the admin as caller");
        _rescueThroughEndpoint(callData, dispatcher.RESCUE_DELAY());

        assertEq(ENDPOINT.lazyInboundNonce(APP, ETHEREUM_EID, bytes32(uint256(uint160(APP)))), nonce, "skipped");
        (address receiveLib,) = ENDPOINT.getReceiveLibrary(APP, ETHEREUM_EID);
        vm.prank(receiveLib);
        vm.expectRevert(); // the skipped nonce can no longer be verified
        ENDPOINT.verify(packet.origin, APP, keccak256(abi.encodePacked(packet.guid, packet.message)));
    }

    /// @notice `clear` of a verified payload (burn it without executing) through the dispatcher's rescue.
    function testForkDispatcherClearsAVerifiedPayloadThroughGenericRescue() public {
        Packet memory packet = _pendingUpdateVaults();

        vm.selectFork(arbitrumFork);
        Origin memory origin = _verify(packet);
        bytes memory callData = abi.encodeCall(ENDPOINT.clear, (APP, origin, packet.guid, packet.message));
        _rescueThroughEndpoint(callData, dispatcher.RESCUE_DELAY());

        assertEq(
            ENDPOINT.inboundPayloadHash(APP, ETHEREUM_EID, bytes32(uint256(uint160(APP))), origin.nonce),
            bytes32(0),
            "payload cleared"
        );
        assertEq(ENDPOINT.lazyInboundNonce(APP, ETHEREUM_EID, bytes32(uint256(uint160(APP)))), origin.nonce);
        (bool ok,) = _lzReceive(origin, packet, COMMAND_LANE_GAS);
        assertFalse(ok, "a cleared payload cannot execute");
        assertEq(dispatcher.commandConfigEpoch(), 1, "never applied");
    }

    /// @notice `nilify` of a verified receipt on the EXECUTOR through its timelocked generic rescue.
    function testForkExecutorNilifiesAVerifiedReceiptThroughGenericRescue() public {
        Packet memory packet = _pendingUpdateVaults();
        vm.selectFork(arbitrumFork);
        _deliver(packet, COMMAND_LANE_GAS);
        Packet memory ack = _takePacket(APP);

        vm.selectFork(ethereumFork);
        Origin memory origin = _verify(ack);
        bytes32 payloadHash = keccak256(abi.encodePacked(ack.guid, ack.message));
        bytes memory callData = abi.encodeCall(
            ENDPOINT.nilify, (APP, ARBITRUM_EID, bytes32(uint256(uint160(APP))), origin.nonce, payloadHash)
        );
        _rescueThroughEndpoint(callData, executor.RESCUE_DELAY());

        assertEq(
            ENDPOINT.inboundPayloadHash(APP, ARBITRUM_EID, bytes32(uint256(uint160(APP))), origin.nonce),
            NIL_PAYLOAD_HASH,
            "payload nilified"
        );
        (bool ok,) = _lzReceive(origin, ack, COMMAND_LANE_GAS);
        assertFalse(ok, "a nilified payload cannot execute");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev A second UPDATE_VAULTS from the executor, captured but not delivered.
    function _pendingUpdateVaults() internal returns (Packet memory packet) {
        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.updatePlasmaVaults(ARBITRUM_CHAIN_ID, new address[](0));
        packet = _takePacket(APP);
    }

    function _assertStillVerified(Packet memory packet_) internal view {
        bytes32 sender = packet_.origin.sender;
        uint32 srcEid = packet_.origin.srcEid;
        assertEq(
            ENDPOINT.inboundPayloadHash(APP, srcEid, sender, packet_.origin.nonce),
            keccak256(abi.encodePacked(packet_.guid, packet_.message)),
            "payload still verified"
        );
        assertEq(ENDPOINT.lazyInboundNonce(APP, srcEid, sender), packet_.origin.nonce - 1, "not consumed");
    }

    /// @dev Schedule and execute a generic rescue of the app on the CURRENT fork that calls the endpoint.
    function _rescueThroughEndpoint(bytes memory callData_, uint256 rescueDelay_) internal {
        vm.prank(admin);
        (bool ok, bytes memory ret) = APP.call(
            abi.encodeWithSignature("scheduleRescue(address,uint256,bytes)", LZ_ENDPOINT, uint256(0), callData_)
        );
        require(ok, "scheduleRescue reverted");
        uint256 rescueId = abi.decode(ret, (uint256));
        vm.warp(block.timestamp + rescueDelay_ + 1);
        vm.prank(admin);
        (ok, ret) = APP.call(abi.encodeWithSignature("executeRescue(uint256,bytes)", rescueId, callData_));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
