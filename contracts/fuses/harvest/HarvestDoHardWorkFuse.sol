// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IHarvestVault} from "./ext/IHarvestVault.sol";
import {IHarvestController} from "./ext/IHarvestController.sol";

/// @notice Data for performing hard work on Harvest vaults
/// @param vaults Array of vault addresses to perform hard work on
struct HarvestDoHardWorkFuseEnterData {
    address[] vaults;
}

/// @title HarvestDoHardWorkFuse
/// @notice Fuse responsible for performing harvest operations on vaults
/// @dev This fuse handles the harvesting of rewards and performing hard work on vaults
contract HarvestDoHardWorkFuse is IFuseCommon {
    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    event HarvestDoHardWorkFuseEnter(address version, address vault, address comptroller);

    error NotSupported();
    error UnsupportedVault(address vault);
    error UnsupportedComptroller(address vault);

    /// @notice Creates a new instance of HarvestDoHardWorkFuse
    /// @param marketId_ The market ID this fuse is associated with
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Performs hard work on specified Harvest vaults
    /// @param data_ Struct containing array of vault addresses to perform hard work on
    function enter(HarvestDoHardWorkFuseEnterData calldata data_) external {
        uint256 len = data_.vaults.length;
        address vault;
        address comptroller;

        for (uint256 i; i < len; ++i) {
            vault = data_.vaults[i];
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, vault)) {
                revert UnsupportedVault(vault);
            }

            comptroller = IHarvestVault(vault).controller();
            if (comptroller == address(0)) {
                revert UnsupportedComptroller(vault);
            }

            IHarvestController(comptroller).doHardWork(vault);

            emit HarvestDoHardWorkFuseEnter(VERSION, vault, comptroller);
        }
    }

    /// @notice Exit function - not supported in this fuse
    function exit() external {
        revert NotSupported();
    }
}
