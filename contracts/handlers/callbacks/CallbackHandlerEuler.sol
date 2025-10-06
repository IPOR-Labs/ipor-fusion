// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CallbackData} from "../../libraries/CallbackHandlerLib.sol";
/// @title Callback handler for the Morpho protocol
contract CallbackHandlerEuler {
    //solhint-disable-next-line
    function onEulerFlashLoan(bytes calldata data_) external view returns (CallbackData memory) {
        return abi.decode(data_, (CallbackData));
    }
}
