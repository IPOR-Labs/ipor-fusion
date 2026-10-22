// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    MsgType,
    BusinessAction,
    CommandResolution,
    ReturnRejectReason,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    DeploymentTicket,
    DeploymentAck,
    DeploymentNack,
    UpdateVaults,
    OutboundTransfer,
    TransferSettled,
    ReturnAssetsRequest,
    ReturnStarted,
    ReturnRejected,
    Command,
    RetryCommand,
    CancelCommand,
    CommandAck,
    CommandNack
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title CrosschainMessagesTest
/// @notice Round-trips every wire struct through its envelope codec (encode -> decodeEnvelope -> decodeX)
///         and asserts `decodeEnvelope` rejects bad versions and NONE/out-of-range message types. Also
///         round-trips the per-action business payloads. This is the foundational codec contract (spec §3).
contract CrosschainMessagesTest is Test {
    // A thin wrapper so `bytes calldata` slicing in the codec has a calldata source where needed.
    function decodeEnvelopeExt(bytes calldata raw_) external pure returns (MsgType, bytes memory) {
        return CrosschainMessages.decodeEnvelope(raw_);
    }

    // ---------------------------------------------------------------------
    // Envelope round-trips per message type
    // ---------------------------------------------------------------------

    function testShouldRoundTripDeploymentTicket() public {
        DeploymentTicket memory t = DeploymentTicket({
            requestId: 7,
            salt: keccak256("salt"),
            executor: address(0xE1),
            srcChainId: 1,
            dstChainId: 42161,
            assetId: keccak256("USDC"),
            admin: address(0xAD),
            guardian: address(0x6A),
            rescueDelay: 3 days,
            immutableParamsHash: keccak256("imm"),
            expiresAt: 1_900_000_000
        });
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeDeploymentTicket(t));
        assertEq(uint8(mt), uint8(MsgType.CREATE_DISPATCHER), "msgType");
        DeploymentTicket memory d = CrosschainMessages.decodeDeploymentTicket(data);
        assertEq(d.requestId, t.requestId);
        assertEq(d.salt, t.salt);
        assertEq(d.executor, t.executor);
        assertEq(d.srcChainId, t.srcChainId);
        assertEq(d.dstChainId, t.dstChainId);
        assertEq(d.assetId, t.assetId);
        assertEq(d.admin, t.admin);
        assertEq(d.guardian, t.guardian);
        assertEq(d.rescueDelay, t.rescueDelay);
        assertEq(d.immutableParamsHash, t.immutableParamsHash);
        assertEq(d.expiresAt, t.expiresAt);
    }

    function testShouldRoundTripDeploymentAck() public {
        DeploymentAck memory a =
            DeploymentAck({requestId: 3, ticketHash: keccak256("th"), dispatcher: address(0xD1), dstChainId: 10});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeDeploymentAck(a));
        assertEq(uint8(mt), uint8(MsgType.DEPLOYMENT_ACK));
        DeploymentAck memory d = CrosschainMessages.decodeDeploymentAck(data);
        assertEq(d.requestId, a.requestId);
        assertEq(d.ticketHash, a.ticketHash);
        assertEq(d.dispatcher, a.dispatcher);
        assertEq(d.dstChainId, a.dstChainId);
    }

    function testShouldRoundTripDeploymentNack() public {
        DeploymentNack memory n = DeploymentNack({requestId: 5, ticketHash: keccak256("th2"), reason: 1});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeDeploymentNack(n));
        assertEq(uint8(mt), uint8(MsgType.DEPLOYMENT_NACK));
        DeploymentNack memory d = CrosschainMessages.decodeDeploymentNack(data);
        assertEq(d.requestId, n.requestId);
        assertEq(d.ticketHash, n.ticketHash);
        assertEq(d.reason, n.reason);
    }

    function testShouldRoundTripUpdateVaults() public {
        address[] memory vaults = new address[](2);
        vaults[0] = address(0x71);
        vaults[1] = address(0x72);
        UpdateVaults memory u = UpdateVaults({
            commandId: keccak256("c"), sequence: 4, newConfigEpoch: 9, minExecutionGas: 1_234_567, vaults: vaults
        });
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeUpdateVaults(u));
        assertEq(uint8(mt), uint8(MsgType.UPDATE_VAULTS));
        UpdateVaults memory d = CrosschainMessages.decodeUpdateVaults(data);
        assertEq(d.commandId, u.commandId);
        assertEq(d.sequence, u.sequence);
        assertEq(d.newConfigEpoch, u.newConfigEpoch);
        assertEq(d.minExecutionGas, 1_234_567, "the budget survives the codec");
        assertEq(d.vaults.length, 2);
        assertEq(d.vaults[0], vaults[0]);
        assertEq(d.vaults[1], vaults[1]);
    }

    function testShouldRoundTripOutboundTransfer() public {
        OutboundTransfer memory o = OutboundTransfer({transferId: keccak256("tid")});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeOutboundTransfer(o));
        assertEq(uint8(mt), uint8(MsgType.OUTBOUND_TRANSFER));
        assertEq(CrosschainMessages.decodeOutboundTransfer(data).transferId, o.transferId);
    }

    function testShouldRoundTripTransferSettled() public {
        TransferSettled memory t = TransferSettled({
            transferId: keccak256("tid"), guid: keccak256("guid"), amountReceivedSD: 123456, stateVersion: 8
        });
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeTransferSettled(t));
        assertEq(uint8(mt), uint8(MsgType.TRANSFER_SETTLED));
        TransferSettled memory d = CrosschainMessages.decodeTransferSettled(data);
        assertEq(d.transferId, t.transferId);
        assertEq(d.guid, t.guid);
        assertEq(d.amountReceivedSD, t.amountReceivedSD);
        assertEq(d.stateVersion, t.stateVersion);
    }

    function testShouldRoundTripReturnAssetsRequest() public {
        ReturnAssetsRequest memory r =
            ReturnAssetsRequest({requestId: keccak256("rid"), amountSD: 1000, maxAccountedSD: 900, minReturnSD: 850});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeReturnAssetsRequest(r));
        assertEq(uint8(mt), uint8(MsgType.RETURN_ASSETS_REQUEST));
        ReturnAssetsRequest memory d = CrosschainMessages.decodeReturnAssetsRequest(data);
        assertEq(d.requestId, r.requestId);
        assertEq(d.amountSD, r.amountSD);
        assertEq(d.maxAccountedSD, r.maxAccountedSD);
        assertEq(d.minReturnSD, r.minReturnSD);
    }

    function testShouldRoundTripReturnStarted() public {
        ReturnStarted memory r = ReturnStarted({
            requestId: keccak256("rid"),
            guid: keccak256("guid"),
            amountSentSD: 500,
            amountReceivedSD: 480,
            stateVersion: 12,
            remoteBalanceSD: 77
        });
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeReturnStarted(r));
        assertEq(uint8(mt), uint8(MsgType.RETURN_STARTED));
        ReturnStarted memory d = CrosschainMessages.decodeReturnStarted(data);
        assertEq(d.requestId, r.requestId);
        assertEq(d.guid, r.guid);
        assertEq(d.amountSentSD, r.amountSentSD);
        assertEq(d.amountReceivedSD, r.amountReceivedSD);
        assertEq(d.stateVersion, r.stateVersion);
        assertEq(d.remoteBalanceSD, r.remoteBalanceSD);
    }

    function testShouldRoundTripReturnRejected() public {
        ReturnRejected memory r =
            ReturnRejected({requestId: keccak256("rid"), reason: ReturnRejectReason.NO_TRACKED_IDLE});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeReturnRejected(r));
        assertEq(uint8(mt), uint8(MsgType.RETURN_REJECTED));
        ReturnRejected memory d = CrosschainMessages.decodeReturnRejected(data);
        assertEq(d.requestId, r.requestId);
        assertEq(uint8(d.reason), uint8(r.reason));
    }

    /// @notice IL-8119: the new `BELOW_MINIMUM` reason round-trips like any other enum value — no encoder,
    ///         decoder or handler switches on it (assessment §3).
    function testShouldRoundTripReturnRejectedBelowMinimum() public {
        ReturnRejected memory r =
            ReturnRejected({requestId: keccak256("rid-below-min"), reason: ReturnRejectReason.BELOW_MINIMUM});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeReturnRejected(r));
        assertEq(uint8(mt), uint8(MsgType.RETURN_REJECTED));
        ReturnRejected memory d = CrosschainMessages.decodeReturnRejected(data);
        assertEq(d.requestId, r.requestId);
        assertEq(uint8(d.reason), uint8(r.reason));
    }

    /// @notice IL-8119 bumped CODEC_VERSION 2 -> 3 because an old executor cannot `abi.decode` the new
    ///         `BELOW_MINIMUM` enum member. Pin the value so an accidental revert of the bump is caught.
    ///         IL-8625 bumped it 3 -> 4: `Command` and `UpdateVaults` gained `minExecutionGas`, so an old dispatcher would
    ///         mis-decode the new layout and must reject the envelope instead.
    function testShouldHaveCodecVersionFour() public pure {
        assertEq(CrosschainConstants.CODEC_VERSION, 4);
    }

    function testShouldRoundTripCommand() public {
        bytes memory actionData = CrosschainMessages.encodeDepositAction(address(0xAA), 111, 222);
        Command memory c = Command({
            commandId: keccak256("cid"),
            sequence: 6,
            commandConfigEpoch: 2,
            action: uint8(BusinessAction.DEPOSIT),
            minExecutionGas: 1_234_567,
            actionData: actionData
        });
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeCommand(c));
        assertEq(uint8(mt), uint8(MsgType.COMMAND));
        Command memory d = CrosschainMessages.decodeCommand(data);
        assertEq(d.commandId, c.commandId);
        assertEq(d.sequence, c.sequence);
        assertEq(d.commandConfigEpoch, c.commandConfigEpoch);
        assertEq(d.action, c.action);
        assertEq(d.minExecutionGas, 1_234_567, "the budget survives the codec");
        assertEq(keccak256(d.actionData), keccak256(c.actionData));
    }

    /// @notice IL-8625: `commandGasBudget` = lane gas - (Stargate: lane / 64) - BASE - PER_WORD * words, refused below
    ///         the floor; `laneGasFor` is its exact inverse.
    function testShouldDeriveTheBudgetFromTheLaneGasAndThePayloadSize() public {
        uint256 base = CrosschainConstants.COMMAND_PRE_CALL_BASE;
        uint256 perWord = CrosschainConstants.COMMAND_PRE_CALL_PER_WORD;
        uint256 floor = CrosschainConstants.COMMAND_EXECUTION_MIN_GAS;
        // CCIP form: no 1/64 term.
        assertEq(this.budgetExt(4_000_000, 10, false), 4_000_000 - base - perWord * 10);
        // Stargate form: the real endpoint keeps lane / 64 back.
        assertEq(this.budgetExt(4_000_000, 10, true), 4_000_000 - 4_000_000 / 64 - base - perWord * 10);
        assertEq(this.budgetExt(type(uint256).max, 0, false), type(uint64).max, "capped, never wraps");
        for (uint256 w; w <= 60; w += 5) {
            for (uint256 s; s < 2; ++s) {
                bool sf = s == 1;
                uint256 minLane = CrosschainMessages.laneGasFor(floor, w, sf);
                assertEq(this.budgetExt(minLane, w, sf) >= floor ? 1 : 0, 1, "minimum lane yields the floor");
                assertEq(this.budgetExt(minLane, w, sf) - floor < 2_000 ? 1 : 0, 1, "and is tight");
                vm.expectRevert(
                    abi.encodeWithSelector(CrosschainErrors.CommandLaneGasTooLow.selector, minLane - 1, minLane)
                );
                this.budgetExt(minLane - 1, w, sf);
            }
        }
        assertEq(CrosschainMessages.payloadWords(0), 0);
        assertEq(CrosschainMessages.payloadWords(1), 1);
        assertEq(CrosschainMessages.payloadWords(32), 1);
        assertEq(CrosschainMessages.payloadWords(33), 2);
    }

    function budgetExt(uint256 laneGas_, uint256 words_, bool sixtyFourth_) external pure returns (uint64) {
        return CrosschainMessages.commandGasBudget(laneGas_, words_, sixtyFourth_);
    }

    function testShouldRoundTripRetryCommand() public {
        RetryCommand memory r = RetryCommand({commandId: keccak256("cid"), minExecutionGas: 7_654_321});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeRetryCommand(r));
        assertEq(uint8(mt), uint8(MsgType.RETRY_COMMAND));
        assertEq(CrosschainMessages.decodeRetryCommand(data).commandId, r.commandId);
        assertEq(CrosschainMessages.decodeRetryCommand(data).minExecutionGas, 7_654_321, "the raise survives the codec");
    }

    function testShouldRoundTripCancelCommand() public {
        CancelCommand memory c = CancelCommand({commandId: keccak256("cid")});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeCancelCommand(c));
        assertEq(uint8(mt), uint8(MsgType.CANCEL_COMMAND));
        assertEq(CrosschainMessages.decodeCancelCommand(data).commandId, c.commandId);
    }

    function testShouldRoundTripCommandAck() public {
        CommandAck memory a = CommandAck({
            commandId: keccak256("cid"),
            sequence: 3,
            stateVersion: 4,
            dispatcherConfigEpoch: 9,
            resolution: CommandResolution.SUCCEEDED,
            valueDeltaSD: -777
        });
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeCommandAck(a));
        assertEq(uint8(mt), uint8(MsgType.ACK));
        CommandAck memory d = CrosschainMessages.decodeCommandAck(data);
        assertEq(d.commandId, a.commandId);
        assertEq(d.sequence, a.sequence);
        assertEq(d.stateVersion, a.stateVersion);
        assertEq(d.dispatcherConfigEpoch, a.dispatcherConfigEpoch);
        assertEq(uint8(d.resolution), uint8(CommandResolution.SUCCEEDED));
        assertEq(d.valueDeltaSD, a.valueDeltaSD);
    }

    function testShouldRoundTripCancelResolutionCommandAck() public {
        // A cancel resolution reuses the ACK envelope; only `resolution` distinguishes it on the wire.
        CommandAck memory a = CommandAck({
            commandId: keccak256("cid"),
            sequence: 3,
            stateVersion: 4,
            dispatcherConfigEpoch: 9,
            resolution: CommandResolution.CANCELLED,
            valueDeltaSD: 0
        });
        (, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeCommandAck(a));
        assertEq(uint8(CrosschainMessages.decodeCommandAck(data).resolution), uint8(CommandResolution.CANCELLED));
    }

    function testShouldRejectCommandAckWithOutOfRangeResolution() public {
        // An enum byte outside {SUCCEEDED, CANCELLED} must not decode to a valid resolution.
        bytes memory raw = abi.encode(keccak256("cid"), uint64(3), uint64(4), uint64(9), uint8(7), int256(0));
        vm.expectRevert();
        this.decodeCommandAckExt(raw);
    }

    function decodeCommandAckExt(bytes calldata data_) external pure returns (CommandAck memory) {
        return CrosschainMessages.decodeCommandAck(data_);
    }

    function testShouldRoundTripCommandNack() public {
        CommandNack memory n = CommandNack({commandId: keccak256("cid"), sequence: 3});
        (MsgType mt, bytes memory data) = this.decodeEnvelopeExt(CrosschainMessages.encodeCommandNack(n));
        assertEq(uint8(mt), uint8(MsgType.NACK));
        CommandNack memory d = CrosschainMessages.decodeCommandNack(data);
        assertEq(d.commandId, n.commandId);
        assertEq(d.sequence, n.sequence);
    }

    // ---------------------------------------------------------------------
    // Business action payload round-trips
    // ---------------------------------------------------------------------

    function testShouldRoundTripDepositAction() public pure {
        (address v, uint256 a, uint256 m) =
            CrosschainMessages.decodeDepositAction(CrosschainMessages.encodeDepositAction(address(0xAA), 111, 222));
        assertEq(v, address(0xAA));
        assertEq(a, 111);
        assertEq(m, 222);
    }

    function testShouldRoundTripRedeemAction() public pure {
        (address v, uint256 s, uint256 m) =
            CrosschainMessages.decodeRedeemAction(CrosschainMessages.encodeRedeemAction(address(0xBB), 333, 444));
        assertEq(v, address(0xBB));
        assertEq(s, 333);
        assertEq(m, 444);
    }

    function testShouldRoundTripRequestSharesAction() public pure {
        (address wm, address pv, uint256 s, uint256 maxFee) = CrosschainMessages.decodeRequestSharesAction(
            CrosschainMessages.encodeRequestSharesAction(address(0xC1), address(0xC2), 555, 7)
        );
        assertEq(wm, address(0xC1));
        assertEq(pv, address(0xC2));
        assertEq(s, 555);
        assertEq(maxFee, 7, "fee ceiling round-trips");
    }

    /// @dev IL-8603 wire-format change: the former three-word REQUEST_SHARES encoding no longer decodes.
    function testShouldRejectLegacyThreeWordRequestSharesAction() public {
        vm.expectRevert(bytes(""));
        this.decodeRequestSharesExternal(abi.encode(address(0xC1), address(0xC2), uint256(555)));
    }

    function decodeRequestSharesExternal(bytes memory data_)
        external
        pure
        returns (address, address, uint256, uint256)
    {
        return CrosschainMessages.decodeRequestSharesAction(data_);
    }

    function testShouldRoundTripRedeemFromRequestAction() public pure {
        (address wm, address pv, uint256 s, uint256 m, address r) = CrosschainMessages.decodeRedeemFromRequestAction(
            CrosschainMessages.encodeRedeemFromRequestAction(address(0xC1), address(0xC2), 555, 666, address(0xC3))
        );
        assertEq(wm, address(0xC1));
        assertEq(pv, address(0xC2));
        assertEq(s, 555);
        assertEq(m, 666);
        assertEq(r, address(0xC3));
    }

    // ---------------------------------------------------------------------
    // decodeEnvelope rejections
    // ---------------------------------------------------------------------

    function testShouldRevertOnUnsupportedCodecVersion() public {
        uint8 unsupported = CrosschainConstants.CODEC_VERSION + 1;
        bytes memory raw = abi.encode(unsupported, uint8(MsgType.COMMAND), bytes(""));
        vm.expectRevert(abi.encodeWithSelector(CrosschainMessages.UnsupportedCodecVersion.selector, unsupported));
        this.decodeEnvelopeExt(raw);
    }

    function testShouldRejectSupersededCodecVersionOne() public {
        // v1 `CommandAck` carried no resolution/config-epoch fields, so a v1 peer must never interoperate
        // with any later one: the version bump is what turns a mixed deployment into a loud failure.
        bytes memory raw = abi.encode(uint8(1), uint8(MsgType.ACK), bytes(""));
        vm.expectRevert(abi.encodeWithSelector(CrosschainMessages.UnsupportedCodecVersion.selector, uint8(1)));
        this.decodeEnvelopeExt(raw);
    }

    function testShouldRevertOnNoneMsgType() public {
        bytes memory raw = abi.encode(CrosschainConstants.CODEC_VERSION, uint8(MsgType.NONE), bytes(""));
        vm.expectRevert(abi.encodeWithSelector(CrosschainMessages.UnsupportedMsgType.selector, uint8(0)));
        this.decodeEnvelopeExt(raw);
    }

    function testShouldRevertOnOutOfRangeMsgType() public {
        uint8 bad = uint8(MsgType.RETURN_REJECTED) + 1;
        bytes memory raw = abi.encode(CrosschainConstants.CODEC_VERSION, bad, bytes(""));
        vm.expectRevert(abi.encodeWithSelector(CrosschainMessages.UnsupportedMsgType.selector, bad));
        this.decodeEnvelopeExt(raw);
    }

    function testShouldAcceptEveryValidMsgType() public view {
        // Sanity: every currently defined discriminator decodes without reverting.
        for (uint8 t = uint8(MsgType.CREATE_DISPATCHER); t <= uint8(MsgType.RETURN_REJECTED); ++t) {
            bytes memory raw = abi.encode(CrosschainConstants.CODEC_VERSION, t, bytes(""));
            (MsgType mt,) = this.decodeEnvelopeExt(raw);
            assertEq(uint8(mt), t);
        }
    }
}
