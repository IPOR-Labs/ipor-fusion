// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CallbackData} from "../../libraries/CallbackHandlerLib.sol";

/// @title Callback handler for the Morpho protocol
contract CallbackHandlerMorpho {
    /// @notice Callback called when a supply occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of supplied assets.
    /// @param data Arbitrary data passed to the `supply` function.
    //solhint-disable-next-line
    function onMorphoSupply(uint256 assets, bytes calldata data) external pure returns (CallbackData memory) {
        return abi.decode(data, (CallbackData));
    }

    /// @notice Callback called when a flash loan occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of assets that was flash loaned.
    /// @param data Arbitrary data passed to the `flashLoan` function.
    //solhint-disable-next-line
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external pure returns (CallbackData memory) {
        return abi.decode(data, (CallbackData));
    }
}
