// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";
import {FuseAction, PlasmaVault} from "../vaults/PlasmaVault.sol";

library CallbackHandlerLib {
    using Address for address;

    event CallbackHandlerUpdated(address indexed handler, address indexed sender, bytes4 indexed sig);

    error HandlerNotFound();

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
        FuseAction[] memory calls = abi.decode(data, (FuseAction[]));
        PlasmaVault(address(this)).executeInternal(calls);
    }

    function updateCallbackHandler(address handler_, address sender_, bytes4 sig_) internal {
        PlasmaVaultStorageLib.getCallbackHandler().callbackHandler[
            keccak256(abi.encodePacked(sender_, sig_))
        ] = handler_;
        emit CallbackHandlerUpdated(handler_, sender_, sig_);
    }
}
