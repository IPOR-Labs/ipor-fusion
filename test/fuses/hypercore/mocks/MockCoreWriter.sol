// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title MockCoreWriter
/// @notice Test double for the HyperEVM CoreWriter precompile-adjacent system contract
/// (`0x3333333333333333333333333333333333333333`). Records every `sendRawAction` call so unit
/// tests can assert on the raw encoded action bytes produced by `HyperCoreLib`.
/// @dev Deployed once and `vm.etch`ed at the CoreWriter address by `HyperCoreTestHelper`.
contract MockCoreWriter {
    /// @notice Raw bytes of the most recent `sendRawAction` call.
    bytes public lastAction;

    /// @notice All raw actions recorded, in call order.
    bytes[] public actions;

    /// @notice Number of times `sendRawAction` was called.
    uint256 public callCount;

    /// @notice Emitted for every recorded action.
    event ActionSent(bytes data);

    /// @notice Records the raw action bytes sent by a HyperCore fuse via `HyperCoreLib.sendRawAction`.
    /// @param data Encoding: `0x01 || bytes3(actionId) || abi.encode(fields)`.
    function sendRawAction(bytes calldata data) external {
        lastAction = data;
        actions.push(data);
        unchecked {
            callCount++;
        }
        emit ActionSent(data);
    }

    /// @notice Number of recorded actions.
    function actionsLength() external view returns (uint256) {
        return actions.length;
    }

    /// @notice Returns the recorded action at `index`.
    function actionAt(uint256 index) external view returns (bytes memory) {
        return actions[index];
    }

    /// @notice Decodes the common CoreWriter action header.
    /// @param data Raw action bytes as recorded by `sendRawAction`.
    /// @return version The leading version byte (`0x01`).
    /// @return actionId The 3-byte big-endian action id.
    /// @return payload The remaining `abi.encode(fields)` payload.
    function decodeHeader(
        bytes memory data
    ) public pure returns (uint8 version, uint24 actionId, bytes memory payload) {
        require(data.length >= 4, "MockCoreWriter: action too short");

        version = uint8(data[0]);
        actionId =
            (uint24(uint8(data[1])) << 16) |
            (uint24(uint8(data[2])) << 8) |
            uint24(uint8(data[3]));

        uint256 payloadLength = data.length - 4;
        payload = new bytes(payloadLength);
        for (uint256 i; i < payloadLength; ++i) {
            payload[i] = data[4 + i];
        }
    }
}
