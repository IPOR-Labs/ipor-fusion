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
        require(commands_.length == state_.length, "MockDelegateEnsoShortcuts: length mismatch");

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

            // Execute based on call type
            if (callType == 0x01) {
                // FLAG_CT_CALL - regular call
                // For any call, try to decode the first parameter as a token address and approve max
                // This is a simplified approach for testing
                if (stateData.length >= 32) {
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

                (bool success, bytes memory returnData) = target.call(abi.encodePacked(selector, stateData));
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
                (bool success, ) = target.call{value: value}(abi.encodePacked(selector, stateData));
                require(success, "MockDelegateEnsoShortcuts: value call failed");
            }
            // Skip STATICCALL (0x02) in this mock
        }

        emit ShortcutExecuted(accountId_, requestId_, commands_.length);
    }
}
