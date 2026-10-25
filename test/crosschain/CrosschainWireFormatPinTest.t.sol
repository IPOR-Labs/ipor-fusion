// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    MsgType,
    BusinessAction,
    CommandStatus,
    CommandResolution,
    NackReason,
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

/// @title CrosschainWireFormatPinTest
/// @notice IL-9129 (C-021): pins the literal discriminator of every wire enum and the exact bytes of every
///         envelope / business-action encoder. The existing codec tests compare an enum with itself, so a
///         reorder or renumber (or any encoding change) passed them; here it fails.
/// @dev Golden vectors were generated once from the current encoders with `cast abi-encode` (independent of the
///      Solidity codec) and the envelope layout `abi.encode(uint8 codecVersion = 4, uint8 msgType, bytes data)`
///      was checked by hand: word 0 = 4, word 1 = msgType, word 2 = 0x60 (offset of `data`), word 3 = length.
///      Changing a golden value is a wire-format change and needs the codec version to be bumped.
contract CrosschainWireFormatPinTest is Test {
    address internal constant A1 = address(0xA1);
    address internal constant A2 = address(0xA2);
    address internal constant A3 = address(0xA3);

    bytes internal constant ACTION_DEPOSIT =
        hex"00000000000000000000000000000000000000000000000000000000000000a100000000000000000000000000000000000000000000000000000000000f424000000000000000000000000000000000000000000000000000000000000f1b30";
    bytes internal constant ACTION_REDEEM =
        hex"00000000000000000000000000000000000000000000000000000000000000a100000000000000000000000000000000000000000000000000000000001e848000000000000000000000000000000000000000000000000000000000001cfde0";
    bytes internal constant ACTION_REQUEST_SHARES =
        hex"00000000000000000000000000000000000000000000000000000000000000a200000000000000000000000000000000000000000000000000000000000000a100000000000000000000000000000000000000000000000000000000002dc6c0000000000000000000000000000000000000000000000000000000000000000f";
    bytes internal constant ACTION_REDEEM_FROM_REQUEST =
        hex"00000000000000000000000000000000000000000000000000000000000000a200000000000000000000000000000000000000000000000000000000000000a100000000000000000000000000000000000000000000000000000000002dc6c000000000000000000000000000000000000000000000000000000000002c402000000000000000000000000000000000000000000000000000000000000000a3";

    // ---------------------------------------------------------------------
    // Enum discriminator pins
    // ---------------------------------------------------------------------

    function test_msgTypeValuesArePinned() public pure {
        assertEq(uint8(MsgType.NONE), 0);
        assertEq(uint8(MsgType.CREATE_DISPATCHER), 1);
        assertEq(uint8(MsgType.DEPLOYMENT_ACK), 2);
        assertEq(uint8(MsgType.DEPLOYMENT_NACK), 3);
        assertEq(uint8(MsgType.UPDATE_VAULTS), 4);
        assertEq(uint8(MsgType.OUTBOUND_TRANSFER), 5);
        assertEq(uint8(MsgType.TRANSFER_SETTLED), 6);
        assertEq(uint8(MsgType.RETURN_ASSETS_REQUEST), 7);
        assertEq(uint8(MsgType.RETURN_STARTED), 8);
        assertEq(uint8(MsgType.COMMAND), 9);
        assertEq(uint8(MsgType.RETRY_COMMAND), 10);
        assertEq(uint8(MsgType.CANCEL_COMMAND), 11);
        assertEq(uint8(MsgType.ACK), 12);
        assertEq(uint8(MsgType.NACK), 13);
        assertEq(uint8(MsgType.RETURN_REJECTED), 14);
        // Cardinality: last element + 1 (appending a value must update this pin deliberately).
        assertEq(uint8(type(MsgType).max) + 1, 15);
    }

    function test_businessActionValuesArePinned() public pure {
        assertEq(uint8(BusinessAction.NONE), 0);
        assertEq(uint8(BusinessAction.DEPOSIT), 1);
        assertEq(uint8(BusinessAction.REDEEM), 2);
        assertEq(uint8(BusinessAction.REQUEST_SHARES), 3);
        assertEq(uint8(BusinessAction.REDEEM_FROM_REQUEST), 4);
        assertEq(uint8(type(BusinessAction).max) + 1, 5);
    }

    function test_commandStatusValuesArePinned() public pure {
        assertEq(uint8(CommandStatus.NONE), 0);
        assertEq(uint8(CommandStatus.PENDING), 1);
        assertEq(uint8(CommandStatus.SUCCEEDED), 2);
        assertEq(uint8(CommandStatus.FAILED), 3);
        assertEq(uint8(CommandStatus.CANCELLED), 4);
        assertEq(uint8(type(CommandStatus).max) + 1, 5);
    }

    function test_commandResolutionValuesArePinned() public pure {
        assertEq(uint8(CommandResolution.SUCCEEDED), 0);
        assertEq(uint8(CommandResolution.CANCELLED), 1);
        assertEq(uint8(CommandResolution.EXPIRED), 2);
        assertEq(uint8(type(CommandResolution).max) + 1, 3);
    }

    function test_returnRejectReasonValuesArePinned() public pure {
        assertEq(uint8(ReturnRejectReason.NONE), 0);
        assertEq(uint8(ReturnRejectReason.NO_TRACKED_IDLE), 1);
        assertEq(uint8(ReturnRejectReason.BELOW_MINIMUM), 2);
        assertEq(uint8(ReturnRejectReason.ABOVE_PATH_CREDIT), 3);
        assertEq(uint8(type(ReturnRejectReason).max) + 1, 4);
    }

    function test_nackReasonValuesArePinned() public pure {
        assertEq(uint8(NackReason.NONE), 0);
        assertEq(uint8(NackReason.REJECTED_OCCUPIED), 1);
        assertEq(uint8(NackReason.DESTINATION_VALIDATION), 2);
        assertEq(uint8(NackReason.TICKET_EXPIRED), 3);
        assertEq(uint8(type(NackReason).max) + 1, 4);
    }

    function test_codecVersionIsPinned() public pure {
        assertEq(CrosschainConstants.CODEC_VERSION, 4);
    }

    // ---------------------------------------------------------------------
    // Golden envelope vectors (one per encoder)
    // ---------------------------------------------------------------------

    function test_goldenVector_DeploymentTicket() public pure {
        bytes memory encoded = CrosschainMessages.encodeDeploymentTicket(
            DeploymentTicket({
                requestId: 1,
                salt: bytes32(uint256(0xb1)),
                executor: A1,
                srcChainId: 101,
                dstChainId: 202,
                assetId: bytes32(uint256(0xb2)),
                admin: A2,
                guardian: A3,
                rescueDelay: 3600,
                immutableParamsHash: bytes32(uint256(0xb3)),
                expiresAt: 1700000000
            })
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000b100000000000000000000000000000000000000000000000000000000000000a1000000000000000000000000000000000000000000000000000000000000006500000000000000000000000000000000000000000000000000000000000000ca00000000000000000000000000000000000000000000000000000000000000b200000000000000000000000000000000000000000000000000000000000000a200000000000000000000000000000000000000000000000000000000000000a30000000000000000000000000000000000000000000000000000000000000e1000000000000000000000000000000000000000000000000000000000000000b3000000000000000000000000000000000000000000000000000000006553f100"
            ),
            "DeploymentTicket golden envelope"
        );
        assertEq(uint8(encoded[63]), 1, "DeploymentTicket msgType byte");
    }

    function test_goldenVector_DeploymentAck() public pure {
        bytes memory encoded = CrosschainMessages.encodeDeploymentAck(
            DeploymentAck({requestId: 1, ticketHash: bytes32(uint256(0xb3)), dispatcher: A1, dstChainId: 202})
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000b300000000000000000000000000000000000000000000000000000000000000a100000000000000000000000000000000000000000000000000000000000000ca"
            ),
            "DeploymentAck golden envelope"
        );
        assertEq(uint8(encoded[63]), 2, "DeploymentAck msgType byte");
    }

    function test_goldenVector_DeploymentNack() public pure {
        bytes memory encoded = CrosschainMessages.encodeDeploymentNack(
            DeploymentNack({requestId: 1, ticketHash: bytes32(uint256(0xb3)), reason: uint8(NackReason.TICKET_EXPIRED)})
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000b30000000000000000000000000000000000000000000000000000000000000003"
            ),
            "DeploymentNack golden envelope"
        );
        assertEq(uint8(encoded[63]), 3, "DeploymentNack msgType byte");
    }

    function test_goldenVector_UpdateVaults() public pure {
        address[] memory vaults = new address[](2);
        vaults[0] = A1;
        vaults[1] = A2;
        bytes memory encoded = CrosschainMessages.encodeUpdateVaults(
            UpdateVaults({
                commandId: bytes32(uint256(0xc1)),
                sequence: 7,
                newConfigEpoch: 2,
                minExecutionGas: 500000,
                vaults: vaults
            })
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c100000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000007a12000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000a100000000000000000000000000000000000000000000000000000000000000a2"
            ),
            "UpdateVaults golden envelope"
        );
        assertEq(uint8(encoded[63]), 4, "UpdateVaults msgType byte");
    }

    function test_goldenVector_OutboundTransfer() public pure {
        bytes memory encoded = CrosschainMessages.encodeOutboundTransfer(
            OutboundTransfer({transferId: bytes32(uint256(0xd1))})
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000d1"
            ),
            "OutboundTransfer golden envelope"
        );
        assertEq(uint8(encoded[63]), 5, "OutboundTransfer msgType byte");
    }

    function test_goldenVector_TransferSettled() public pure {
        bytes memory encoded = CrosschainMessages.encodeTransferSettled(
            TransferSettled({
                transferId: bytes32(uint256(0xd1)),
                guid: bytes32(uint256(0xd2)),
                amountReceivedSD: 1000000,
                stateVersion: 9
            })
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000d100000000000000000000000000000000000000000000000000000000000000d200000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000000000000000009"
            ),
            "TransferSettled golden envelope"
        );
        assertEq(uint8(encoded[63]), 6, "TransferSettled msgType byte");
    }

    function test_goldenVector_ReturnAssetsRequest() public pure {
        bytes memory encoded = CrosschainMessages.encodeReturnAssetsRequest(
            ReturnAssetsRequest({
                requestId: bytes32(uint256(0xe1)),
                amountSD: 5000000,
                maxAccountedSD: 4000000,
                minReturnSD: 3000000
            })
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000e100000000000000000000000000000000000000000000000000000000004c4b4000000000000000000000000000000000000000000000000000000000003d090000000000000000000000000000000000000000000000000000000000002dc6c0"
            ),
            "ReturnAssetsRequest golden envelope"
        );
        assertEq(uint8(encoded[63]), 7, "ReturnAssetsRequest msgType byte");
    }

    function test_goldenVector_ReturnStarted() public pure {
        bytes memory encoded = CrosschainMessages.encodeReturnStarted(
            ReturnStarted({
                requestId: bytes32(uint256(0xe1)),
                guid: bytes32(uint256(0xe2)),
                amountSentSD: 4000000,
                amountReceivedSD: 3999000,
                stateVersion: 11,
                remoteBalanceSD: 250000
            })
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"00000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e100000000000000000000000000000000000000000000000000000000000000e200000000000000000000000000000000000000000000000000000000003d090000000000000000000000000000000000000000000000000000000000003d0518000000000000000000000000000000000000000000000000000000000000000b000000000000000000000000000000000000000000000000000000000003d090"
            ),
            "ReturnStarted golden envelope"
        );
        assertEq(uint8(encoded[63]), 8, "ReturnStarted msgType byte");
    }

    function test_goldenVector_Command() public pure {
        bytes memory encoded = CrosschainMessages.encodeCommand(
            Command({
                commandId: bytes32(uint256(0xf1)),
                sequence: 5,
                commandConfigEpoch: 2,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 600000,
                actionData: CrosschainMessages.encodeDepositAction(A1, 1000000, 990000)
            })
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000f100000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000927c000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a100000000000000000000000000000000000000000000000000000000000f424000000000000000000000000000000000000000000000000000000000000f1b30"
            ),
            "Command golden envelope"
        );
        assertEq(uint8(encoded[63]), 9, "Command msgType byte");
    }

    function test_goldenVector_RetryCommand() public pure {
        bytes memory encoded = CrosschainMessages.encodeRetryCommand(
            RetryCommand({commandId: bytes32(uint256(0xf1)), minExecutionGas: 800000})
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000f100000000000000000000000000000000000000000000000000000000000c3500"
            ),
            "RetryCommand golden envelope"
        );
        assertEq(uint8(encoded[63]), 10, "RetryCommand msgType byte");
    }

    function test_goldenVector_CancelCommand() public pure {
        bytes memory encoded = CrosschainMessages.encodeCancelCommand(
            CancelCommand({commandId: bytes32(uint256(0xf1))})
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000b0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000f1"
            ),
            "CancelCommand golden envelope"
        );
        assertEq(uint8(encoded[63]), 11, "CancelCommand msgType byte");
    }

    function test_goldenVector_CommandAck() public pure {
        bytes memory encoded = CrosschainMessages.encodeCommandAck(
            CommandAck({
                commandId: bytes32(uint256(0xf1)),
                sequence: 5,
                stateVersion: 12,
                dispatcherConfigEpoch: 2,
                resolution: CommandResolution.CANCELLED,
                valueDeltaSD: 0
            })
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000f10000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000"
            ),
            "CommandAck golden envelope"
        );
        assertEq(uint8(encoded[63]), 12, "CommandAck msgType byte");
    }

    function test_goldenVector_CommandNack() public pure {
        bytes memory encoded = CrosschainMessages.encodeCommandNack(
            CommandNack({commandId: bytes32(uint256(0xf1)), sequence: 5})
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000d0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000f10000000000000000000000000000000000000000000000000000000000000005"
            ),
            "CommandNack golden envelope"
        );
        assertEq(uint8(encoded[63]), 13, "CommandNack msgType byte");
    }

    function test_goldenVector_ReturnRejected() public pure {
        bytes memory encoded = CrosschainMessages.encodeReturnRejected(
            ReturnRejected({requestId: bytes32(uint256(0xe1)), reason: ReturnRejectReason.ABOVE_PATH_CREDIT})
        );
        assertEq(
            keccak256(encoded),
            keccak256(
                hex"0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e10000000000000000000000000000000000000000000000000000000000000003"
            ),
            "ReturnRejected golden envelope"
        );
        assertEq(uint8(encoded[63]), 14, "ReturnRejected msgType byte");
    }

    function test_goldenVector_envelopeLayout() public pure {
        bytes memory encoded = CrosschainMessages.encodeEnvelope(MsgType.OUTBOUND_TRANSFER, hex"aabb");
        assertEq(
            keccak256(encoded),
            keccak256(
                abi.encodePacked(
                    uint256(4), // codec version
                    uint256(5), // msgType
                    uint256(0x60), // offset of `data`
                    uint256(2), // data length
                    hex"aabb000000000000000000000000000000000000000000000000000000000000"
                )
            ),
            "envelope layout"
        );
    }

    // ---------------------------------------------------------------------
    // Golden business-action vectors
    // ---------------------------------------------------------------------

    function test_goldenVector_depositAction() public pure {
        assertEq(
            keccak256(CrosschainMessages.encodeDepositAction(A1, 1000000, 990000)),
            keccak256(ACTION_DEPOSIT),
            "deposit action"
        );
    }

    function test_goldenVector_redeemAction() public pure {
        assertEq(
            keccak256(CrosschainMessages.encodeRedeemAction(A1, 2000000, 1900000)),
            keccak256(ACTION_REDEEM),
            "redeem action"
        );
    }

    function test_goldenVector_requestSharesAction() public pure {
        assertEq(
            keccak256(CrosschainMessages.encodeRequestSharesAction(A2, A1, 3000000, 15)),
            keccak256(ACTION_REQUEST_SHARES),
            "request shares action"
        );
    }

    function test_goldenVector_redeemFromRequestAction() public pure {
        assertEq(
            keccak256(CrosschainMessages.encodeRedeemFromRequestAction(A2, A1, 3000000, 2900000, A3)),
            keccak256(ACTION_REDEEM_FROM_REQUEST),
            "redeem from request action"
        );
    }
}
