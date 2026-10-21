// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @title MockDelegateEnsoShortcuts
/// @notice Mock contract simulating Enso's DelegateEnsoShortcuts for testing
/// @dev This contract will be called via delegatecall from EnsoExecutor
contract MockDelegateEnsoShortcuts {
    event ShortcutExecuted(bytes32 accountId, bytes32 requestId, uint256 commandsLength);

    /// @notice Mock function simulating Enso shortcut execution
    /// @dev This function will be called via delegatecall from EnsoExecutor
    /// @param accountId_ The bytes32 value representing an API user
    /// @param requestId_ The bytes32 value representing an API request
    /// @param commands_ An array of bytes32 values that encode calls
    /// @param state_ An array of bytes that are used to generate call data for each command
    function executeShortcut(
        bytes32 accountId_,
        bytes32 requestId_,
        bytes32[] calldata commands_,
        bytes[] calldata state_
    ) external payable {
        // Basic validation
        require(commands_.length > 0, "MockDelegateEnsoShortcuts: no commands");
        // The production VM has no pairing constraint between commands and state - state is a
        // free-form slot array addressed by argument indices. This mock only needs a slot per
        // command for its simplified non-FLAG_DATA path, so it requires no more than that.
        require(state_.length >= commands_.length, "MockDelegateEnsoShortcuts: state too short");

        // Process commands - this is simplified for testing
        for (uint256 i = 0; i < commands_.length; i++) {
            bytes32 command = commands_[i];
            bytes memory stateData = state_[i];

            // Command layout in bytes32:
            // Bytes 0-3: function selector (most significant)
            // Bytes 4: flags
            // Bytes 12-31: address (least significant 160 bits)

            // Extract selector from bytes 0-3 (most significant)
            bytes4 selector = bytes4(command);

            // Extract flags from byte 4 (shift right 192 bits, then mask lowest byte)
            uint256 flags = uint256(uint8(bytes1(command << 32)));
            uint256 callType = flags & 0x03; // FLAG_CT_MASK

            // Extract target address from bytes 12-31 (least significant 160 bits)
            address target = address(uint160(uint256(command)));

            // FLAG_DATA (0x20): the VM ignores the selector encoded in the command word and
            // passes the raw state slot addressed by the first argument-index byte as the WHOLE
            // calldata (the SECOND byte for VALUECALL, whose first index carries the ETH value).
            // Modelled here so the suite exercises the dispatch semantics the production VM has,
            // not only the fuse's validator - this is what makes the IL-8047 follow-up PoC and its
            // negative control meaningful.
            bool rawData = flags & 0x20 != 0;
            bytes memory callData;
            if (rawData) {
                uint256 indexShift = callType == 0x03 ? 48 : 40;
                uint256 dataIndex = uint256(uint8(bytes1(command << indexShift))) & 0x7f;
                require(dataIndex < state_.length, "MockDelegateEnsoShortcuts: state index out of range");
                callData = state_[dataIndex];
            } else {
                callData = abi.encodePacked(selector, stateData);
            }

            // Execute based on call type
            if (callType == 0x01) {
                // FLAG_CT_CALL - regular call
                // For any call, try to decode the first parameter as a token address and approve max
                // This is a simplified approach for testing
                if (!rawData && stateData.length >= 32) {
                    // Read first 32 bytes as bytes32
                    bytes32 firstParam;
                    assembly {
                        firstParam := mload(add(stateData, 32))
                    }
                    // Convert to address (last 20 bytes)
                    address potentialToken = address(uint160(uint256(firstParam)));
                    if (potentialToken != address(0) && potentialToken.code.length == 0) {
                        // It's an EOA or potential token, approve it
                        IERC20(potentialToken).approve(target, type(uint256).max);
                    } else if (potentialToken != address(0)) {
                        // It's a contract, try to approve
                        try IERC20(potentialToken).approve(target, type(uint256).max) {} catch {}
                    }
                }

                (bool success, bytes memory returnData) = target.call(callData);
                if (!success) {
                    // Decode revert reason if available
                    if (returnData.length > 0) {
                        assembly {
                            revert(add(returnData, 32), mload(returnData))
                        }
                    }
                    revert("MockDelegateEnsoShortcuts: call failed");
                }
            } else if (callType == 0x03) {
                // FLAG_CT_VALUECALL - call with ETH value
                uint256 value = address(this).balance;
                (bool success, ) = target.call{value: value}(callData);
                require(success, "MockDelegateEnsoShortcuts: value call failed");
            }
            // Skip STATICCALL (0x02) in this mock
        }

        emit ShortcutExecuted(accountId_, requestId_, commands_.length);
    }
}
