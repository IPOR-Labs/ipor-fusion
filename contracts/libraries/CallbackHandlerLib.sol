// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {FuseAction} from "../interfaces/IPlasmaVault.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

struct CallbackData {
    address asset;
    address addressToApprove;
    uint256 amountToApprove;
    bytes actionData;
}

/// @title Callback Handler Library responsible for handling callbacks in the Plasma Vault
library CallbackHandlerLib {
    using Address for address;

    event CallbackHandlerUpdated(address indexed handler, address indexed sender, bytes4 indexed sig);

    error HandlerNotFound();

    /// @notice Handles the callback from the contract
    function handleCallback() internal {
        address handler = PlasmaVaultStorageLib.getCallbackHandler().callbackHandler[
            /// @dev msg.sender - is the address of a contract which execute callback, msg.sig - is the signature of the function
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
        PlasmaVault(address(this)).executeInternal(abi.decode(calls.actionData, (FuseAction[])));

        ERC20(calls.asset).approve(calls.addressToApprove, calls.amountToApprove);
    }

    /// @notice Updates the callback handler for the contract
    /// @param handler_ The address of the handler
    /// @param sender_ The address of the sender
    /// @param sig_ The signature of the function which will be called from msg.sender
    function updateCallbackHandler(address handler_, address sender_, bytes4 sig_) internal {
        PlasmaVaultStorageLib.getCallbackHandler().callbackHandler[
            /// @dev msg.sender - is the address of a contract which execute callback, msg.sig - is the signature of the function
            keccak256(abi.encodePacked(sender_, sig_))
        ] = handler_;
        emit CallbackHandlerUpdated(handler_, sender_, sig_);
    }
}
