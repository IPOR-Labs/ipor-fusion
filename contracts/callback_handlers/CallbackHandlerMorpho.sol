// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {FuseAction} from "../vaults/PlasmaVault.sol";

contract CallbackHandlerMorpho {
    /// @notice Callback called when a supply occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of supplied assets.
    /// @param data Arbitrary data passed to the `supply` function.
    //solhint-disable-next-line
    function onMorphoSupply(uint256 assets, bytes calldata data) external pure returns (FuseAction[] memory) {
        return abi.decode(data, (FuseAction[]));
    }
}
