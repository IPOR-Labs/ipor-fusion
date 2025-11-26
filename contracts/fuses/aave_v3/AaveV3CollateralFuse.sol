// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPool} from "./ext/IPool.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";

/// @title AaveV3CollateralFuse
/// @notice Fuse for Aave V3 responsible for managing isolated collateral in Aave V3
/// @author IPOR Labs
contract AaveV3CollateralFuse is IFuseCommon {
    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice The address of the Aave V3 Pool Addresses Provider
    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    /// @notice Error thrown when the asset is not supported by the fuse
    /// @param action The action being performed (enter/exit)
    /// @param asset The address of the asset
    error AaveV3CollateralFuseUnsupportedAsset(string action, address asset);

    /// @notice Emitted when the Aave V3 Collateral Fuse is enabled for an asset
    /// @param version The address of the fuse version
    /// @param asset The address of the collateral asset
    event AaveV3EnableCollateralFuse(address version, address asset);

    /// @notice Emitted when the Aave V3 Collateral Fuse is disabled for an asset
    /// @param version The address of the fuse version
    /// @param asset The address of the collateral asset
    event AaveV3DisableCollateralFuse(address version, address asset);

    /// @notice Constructor for AaveV3CollateralFuse
    /// @param marketId_ The Market ID associated with the Fuse
    /// @param aaveV3PoolAddressesProvider_ The address of the Aave V3 Pool Addresses Provider
    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert Errors.WrongAddress();
        }
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    /// @notice Enters the Aave V3 Collateral Fuse with the specified asset address, enabling isolated collateral
    /// @param assetAddress_ collateral asset address
    function enter(address assetAddress_) public {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, assetAddress_)) {
            revert AaveV3CollateralFuseUnsupportedAsset("enter", assetAddress_);
        }

        IPool pool = IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool());
        pool.setUserUseReserveAsCollateral(assetAddress_, true);

        emit AaveV3EnableCollateralFuse(VERSION, assetAddress_);
    }

    /// @notice Enters the Aave V3 Collateral Fuse using transient storage for inputs
    /// @dev Reads asset from transient storage
    /// @dev Writes returned asset to transient storage outputs
    function enterTransient() external {
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 0);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32);

        enter(asset);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(asset);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Aave V3 Collateral Fuse with the specified asset address, disabling isolated collateral
    /// @param assetAddress_ collateral asset address
    function exit(address assetAddress_) public {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, assetAddress_)) {
            revert AaveV3CollateralFuseUnsupportedAsset("exit", assetAddress_);
        }

        IPool pool = IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool());
        pool.setUserUseReserveAsCollateral(assetAddress_, false);

        emit AaveV3DisableCollateralFuse(VERSION, assetAddress_);
    }

    /// @notice Exits the Aave V3 Collateral Fuse using transient storage for inputs
    /// @dev Reads asset from transient storage
    /// @dev Writes returned asset to transient storage outputs
    function exitTransient() external {
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 0);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32);

        exit(asset);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(asset);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
