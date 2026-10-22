// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

enum CcipMsgType {
    NONE,
    OUTBOUND_TRANSFER,
    TRANSFER_SETTLED,
    RETURN_REQUEST,
    RETURN_TRANSFER,
    COMMAND,
    COMMAND_ACK,
    COMMAND_NACK,
    UPDATE_VAULTS,
    CREATE_DISPATCHER,
    DEPLOYMENT_ACK,
    DEPLOYMENT_NACK,
    UPDATE_VAULTS_ACK, // reserved, never sent (wire order is frozen); the executor ignores it as an unknown type
    BALANCE_REQUEST,
    BALANCE_REPORT,
    RETURN_REJECTED,
    RETRY_COMMAND,
    CANCEL_COMMAND
}

library CcipMessages {
    /// @dev Version 2 (IL-8590): `RETURN_REQUEST` carries a fifth word, the request `deadline`.
    ///      Version 3 (IL-8625): the `Command` inside COMMAND / UPDATE_VAULTS carries `minExecutionGas`. A mixed
    ///      old/new pair fails `InvalidVersion` instead of mis-decoding.
    uint8 internal constant VERSION = 3;

    error InvalidVersion(uint8 version);
    error InvalidMessageType(uint8 messageType);

    function encode(CcipMsgType messageType_, bytes memory data_) internal pure returns (bytes memory) {
        return abi.encode(VERSION, uint8(messageType_), data_);
    }

    function decode(bytes memory envelope_) internal pure returns (CcipMsgType messageType, bytes memory data) {
        (uint8 version, uint8 rawType, bytes memory inner) = abi.decode(envelope_, (uint8, uint8, bytes));
        if (version != VERSION) revert InvalidVersion(version);
        if (rawType == 0 || rawType > uint8(CcipMsgType.CANCEL_COMMAND)) revert InvalidMessageType(rawType);
        return (CcipMsgType(rawType), inner);
    }
}
