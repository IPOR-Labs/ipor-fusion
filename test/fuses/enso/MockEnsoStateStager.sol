// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title MockEnsoStateStager
/// @notice Attacker-controlled read-only contract used to restage the weiroll `state` mid-shortcut
/// @dev Every function is `view`, so a shortcut reaches it through an unvalidated STATICCALL. Its
///      return data is written back into `state` by the production VM (`writeOutputs` /
///      `writeTuple`), which is how a slot validated as one calldata can be dispatched as another.
contract MockEnsoStateStager {
    bytes internal _payload;

    function setPayload(bytes calldata payload_) external {
        _payload = payload_;
    }

    /// @notice Returns raw data whose slot content, after a variable-length write, is `_payload` verbatim
    /// @dev `writeOutputs` for a variable-length output index requires the first return word to be
    ///      0x20 and stores everything after it as the slot content. Returning `0x20 ++ payload`
    ///      therefore places arbitrary-length, selector-first calldata into the slot.
    function stagedCalldata() external view returns (bytes memory) {
        bytes memory raw = abi.encodePacked(uint256(32), _payload);
        assembly {
            return(add(raw, 32), mload(raw))
        }
    }

    /// @notice Returns a one-slot state array holding `_payload`, for an IDX_USE_STATE (0xfe) write
    function stagedState() external view returns (bytes[] memory state) {
        state = new bytes[](1);
        state[0] = _payload;
    }

    /// @notice Returns a single word, for a fixed-length (static) write
    function stagedWord() external pure returns (uint256) {
        return 1;
    }
}
