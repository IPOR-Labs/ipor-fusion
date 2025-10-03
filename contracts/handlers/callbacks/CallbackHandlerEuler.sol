// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CallbackData} from "../../libraries/CallbackHandlerLib.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Callback handler for the Morpho protocol
contract CallbackHandlerEuler {
    //solhint-disable-next-line
    function onEulerFlashLoan(bytes calldata data_) external view returns (CallbackData memory) {
        console2.log("onEulerFlashLoan");
        console2.log(
            ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).balanceOf(
                address(0xB8a451107A9f87FDe481D4D686247D6e43Ed715e)
            )
        );
        return
            CallbackData(
                address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
                address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
                0,
                data_
            );
    }
}
