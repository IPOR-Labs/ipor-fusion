// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MErc20} from "./ext/MErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

library MoonwellHelperLib {
    error MoonwellSupplyFuseUnsupportedAsset(address asset);

    /// @dev Gets the mToken address for a given asset
    /// @param assetsRaw_ Raw bytes32 array of market substrates
    /// @param asset_ Underlying asset address
    /// @return Address of the corresponding mToken
    function getMToken(bytes32[] memory assetsRaw_, address asset_) internal view returns (address) {
        uint256 len = assetsRaw_.length;
        if (len == 0) {
            revert MoonwellSupplyFuseUnsupportedAsset(asset_);
        }
        address mToken;
        for (uint256 i; i < len; ++i) {
            mToken = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw_[i]);
            if (MErc20(mToken).underlying() == asset_) {
                return mToken;
            }
        }
        revert MoonwellSupplyFuseUnsupportedAsset(asset_);
    }
}
