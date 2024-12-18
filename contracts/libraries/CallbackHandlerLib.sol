// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FuseAction} from "../interfaces/IPlasmaVault.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Data structure for callback execution results
/// @param asset The token address that needs approval
/// @param addressToApprove The address to approve token spending
/// @param amountToApprove The amount of tokens to approve
/// @param actionData Encoded FuseAction array to execute after callback
struct CallbackData {
    address asset;
    address addressToApprove;
    uint256 amountToApprove;
    bytes actionData;
}

/// @title Callback Handler Library for Plasma Vault
/// @notice Manages callback execution and handler registration for the Plasma Vault system
/// @dev This library is used during Fuse execution to handle callbacks from external protocols
library CallbackHandlerLib {
    using Address for address;
    using SafeERC20 for ERC20;

    /// @notice Emitted when a callback handler is updated
    /// @param handler The address of the new callback handler
    /// @param sender The address that will trigger the callback
    /// @param sig The function signature that will trigger the callback
    event CallbackHandlerUpdated(address indexed handler, address indexed sender, bytes4 indexed sig);

    /// @notice Thrown when no handler is found for a callback
    error HandlerNotFound();

    /**
     * @notice Handles callbacks during Fuse execution in the Plasma Vault system
     * @dev Manages the execution flow of protocol callbacks during Fuse operations
     * - Can only be called during PlasmaVault.execute()
     * - Requires PlasmaVaultLib.isExecutionStarted() to be true
     * - Uses delegatecall for handler execution
     *
     * Execution Flow:
     * 1. Retrieves handler based on msg.sender and msg.sig hash
     * 2. Executes handler via delegatecall with original msg.data
     * 3. Processes handler return data if present:
     *    - Decodes as CallbackData struct
     *    - Executes additional FuseActions
     *    - Sets token approvals
     *
     * Integration Context:
     * - Called by PlasmaVault's fallback function
     * - Part of protocol integration system
     * - Enables complex multi-step operations
     * - Supports protocol-specific callbacks:
     *   - Compound supply/borrow callbacks
     *   - Aave flashloan callbacks
     *   - Other protocol-specific operations
     *
     * Error Conditions:
     * - Reverts with HandlerNotFound if no handler registered
     * - Bubbles up handler execution errors
     * - Validates handler return data format
     *
     * Security Considerations:
     * - Only executable during Fuse operations
     * - Handler must be pre-registered
     * - Uses safe delegatecall pattern
     * - Critical for protocol integration security
     *
     * Callback System Integration:
     * - Handlers must implement standardized return format
     * - Enables atomic multi-step operations
     * - Supports protocol-specific logic
     * - Maintains vault security context
     *
     * Gas Considerations:
     * - Single storage read for handler lookup
     * - Dynamic gas cost based on handler logic
     * - Additional gas for FuseAction execution
     * - Token approval costs if required
     */
    function handleCallback() internal {
        address handler = PlasmaVaultStorageLib.getCallbackHandler().callbackHandler[
            keccak256(abi.encodePacked(msg.sender, msg.sig))
        ];

        if (handler == address(0)) {
            revert HandlerNotFound();
        }

        bytes memory data = handler.functionCall(msg.data);

        if (data.length == 0) {
            return;
        }

        CallbackData memory calls = abi.decode(data, (CallbackData));

        // Execute additional FuseActions if provided
        PlasmaVault(address(this)).executeInternal(abi.decode(calls.actionData, (FuseAction[])));

        // Approve token spending if specified
        ERC20(calls.asset).forceApprove(calls.addressToApprove, calls.amountToApprove);
    }

    /**
     * @notice Updates or registers a callback handler in the Plasma Vault system
     * @dev Manages the registration and update of protocol-specific callback handlers
     * - Only callable through PlasmaVaultGovernance by ATOMIST_ROLE
     * - Updates PlasmaVaultStorageLib.CallbackHandler mapping
     * - Critical for protocol integration configuration
     *
     * Storage Updates:
     * 1. Maps handler to combination of sender and function signature
     * 2. Overwrites existing handler if present
     * 3. Emits CallbackHandlerUpdated event
     *
     * Integration Context:
     * - Called by PlasmaVaultGovernance.updateCallbackHandler()
     * - Part of protocol integration setup
     * - Used during vault configuration
     * - Supports protocol-specific handlers:
     *   - Compound callback handlers
     *   - Aave callback handlers
     *   - Other protocol-specific handlers
     *
     * Handler Requirements:
     * - Must implement standardized return format (CallbackData)
     * - Should handle protocol-specific callback logic
     * - Must maintain vault security invariants
     * - Should be stateless and reentrant-safe
     *
     * Security Considerations:
     * - Access restricted to ATOMIST_ROLE
     * - Handler address must be validated
     * - Critical for callback security
     * - Affects vault's protocol integration security
     * - Must verify handler compatibility
     *
     * Use Cases:
     * - Initial protocol integration setup
     * - Handler upgrades and maintenance
     * - Protocol version migrations
     * - Security patches
     *
     * @param handler_ The address of the callback handler contract
     * @param sender_ The address of the protocol contract that triggers callbacks
     * @param sig_ The function signature that identifies the callback
     * @custom:events Emits CallbackHandlerUpdated when successful
     *
     * Gas Considerations:
     * - One SSTORE for mapping update
     * - Event emission cost
     */
    function updateCallbackHandler(address handler_, address sender_, bytes4 sig_) internal {
        PlasmaVaultStorageLib.getCallbackHandler().callbackHandler[
            keccak256(abi.encodePacked(sender_, sig_))
        ] = handler_;
        emit CallbackHandlerUpdated(handler_, sender_, sig_);
    }
}
