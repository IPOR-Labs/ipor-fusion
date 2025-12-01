// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IHarvestController} from "./ext/IHarvestController.sol";
import {IHarvestVault} from "./ext/IHarvestVault.sol";

/// @notice Data for performing hard work on Harvest vaults
/// @param vaults Array of vault addresses to perform hard work on
struct HarvestDoHardWorkFuseEnterData {
    address[] vaults;
}

/// @title HarvestDoHardWorkFuse
/// @notice Fuse responsible for performing harvest operations on vaults
/// @dev This fuse handles the harvesting of rewards and performing hard work on vaults
/// @author IPOR Labs
contract HarvestDoHardWorkFuse is IFuseCommon {
    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    /// @notice Emitted after performing hard work on a Harvest vault
    /// @param version Address of the fuse implementation that executed the hard work
    /// @param vault Address of the vault that had hard work performed
    /// @param comptroller Address of the comptroller that executed the hard work
    event HarvestDoHardWorkFuseEnter(address indexed version, address indexed vault, address indexed comptroller);

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
    /// @return vaults Array of vault addresses that had hard work performed
    /// @return comptrollers Array of comptroller addresses corresponding to each vault
    function enter(
        HarvestDoHardWorkFuseEnterData memory data_
    ) public returns (address[] memory vaults, address[] memory comptrollers) {
        uint256 len = data_.vaults.length;
        vaults = new address[](len);
        comptrollers = new address[](len);
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

            vaults[i] = vault;
            comptrollers[i] = comptroller;

            emit HarvestDoHardWorkFuseEnter(VERSION, vault, comptroller);
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads vaults array from transient storage (first element is length, subsequent elements are vault addresses)
    ///      Writes returned vaults and comptrollers arrays to transient storage outputs
    function enterTransient() external {
        bytes32 lengthBytes32 = TransientStorageLib.getInput(VERSION, 0);
        uint256 len = TypeConversionLib.toUint256(lengthBytes32);

        if (len == 0) {
            bytes32[] memory emptyOutputs = new bytes32[](1);
            emptyOutputs[0] = TypeConversionLib.toBytes32(uint256(0));
            TransientStorageLib.setOutputs(VERSION, emptyOutputs);
            return;
        }

        address[] memory vaults = new address[](len);
        for (uint256 i; i < len; ++i) {
            bytes32 vaultBytes32 = TransientStorageLib.getInput(VERSION, i + 1);
            vaults[i] = TypeConversionLib.toAddress(vaultBytes32);
        }

        HarvestDoHardWorkFuseEnterData memory data = HarvestDoHardWorkFuseEnterData({vaults: vaults});

        (address[] memory returnedVaults, address[] memory returnedComptrollers) = enter(data);

        bytes32[] memory outputs = new bytes32[](1 + len * 2);
        outputs[0] = TypeConversionLib.toBytes32(len);
        for (uint256 i; i < len; ++i) {
            outputs[1 + i] = TypeConversionLib.toBytes32(returnedVaults[i]);
            outputs[1 + len + i] = TypeConversionLib.toBytes32(returnedComptrollers[i]);
        }

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
