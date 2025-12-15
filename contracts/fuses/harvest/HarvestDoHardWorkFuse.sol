// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IHarvestController} from "./ext/IHarvestController.sol";
import {IHarvestVault} from "./ext/IHarvestVault.sol";

/**
 * @notice Data structure for performing hard work on Harvest vaults
 * @dev Contains parameters required to trigger harvest operations on multiple Harvest protocol vaults
 */
struct HarvestDoHardWorkFuseEnterData {
    /// @notice Array of Harvest vault addresses to perform hard work on
    /// @dev Each vault address must be granted as a substrate for the market.
    ///      Hard work triggers reward harvesting and strategy rebalancing for each vault.
    address[] vaults;
}

/**
 * @title Fuse for Harvest protocol responsible for performing hard work operations on vaults
 * @notice Triggers harvest operations (doHardWork) on Harvest protocol vaults to harvest rewards and rebalance strategies
 * @dev This fuse iterates through provided vault addresses, validates they are granted substrates,
 *      retrieves the controller (comptroller) for each vault, and calls doHardWork() to trigger
 *      reward harvesting and strategy rebalancing. All vaults must be granted as substrates for the market.
 * @author IPOR Labs
 */
contract HarvestDoHardWorkFuse is IFuseCommon {
    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to validate vault substrates
    uint256 public immutable MARKET_ID;

    /// @notice Emitted after performing hard work on a Harvest vault
    /// @param version The address of this fuse contract version
    /// @param vault The address of the Harvest vault that had hard work performed
    /// @param comptroller The address of the comptroller (controller) that executed the hard work
    event HarvestDoHardWorkFuseEnter(address version, address vault, address comptroller);

    /// @notice Thrown when a vault address is not granted as a substrate for the market
    /// @param vault The address of the vault that is not supported
    /// @custom:error UnsupportedVault
    error UnsupportedVault(address vault);

    /// @notice Thrown when a vault's controller (comptroller) address is zero
    /// @param vault The address of the vault with invalid controller
    /// @custom:error UnsupportedComptroller
    error UnsupportedComptroller(address vault);

    /**
     * @notice Initializes the HarvestDoHardWorkFuse with a market ID
     * @param marketId_ The market ID used to validate vault substrates
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Performs hard work on specified Harvest vaults
     * @dev This function:
     *      1. Iterates through all vault addresses provided in the data structure
     *      2. Validates each vault is granted as a substrate for the market
     *      3. Retrieves the controller (comptroller) address for each vault
     *      4. Validates the controller address is not zero
     *      5. Calls doHardWork() on the controller for each vault to trigger reward harvesting and strategy rebalancing
     *      6. Emits an event for each successful hard work operation
     * @param data_ The data structure containing the array of vault addresses to perform hard work on
     * @return vaults Array of vault addresses that had hard work performed (same order as input)
     * @return comptrollers Array of comptroller addresses corresponding to each vault (same order as input)
     * @custom:revert UnsupportedVault When a vault is not granted as a substrate for the market
     * @custom:revert UnsupportedComptroller When a vault's controller address is zero
     */
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
