// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPool} from "./ext/IPool.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @title AaveV3CollateralFuse
/// @dev Fuse for Aave V3 responsible for managing isolated collateral in Aave V3
contract AaveV3CollateralFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    error AaveV3CollateralFuseUnsupportedAsset(string action, address asset);

    event AaveV3EnableCollateralFuse(address version, address asset);
    event AaveV3DisableCollateralFuse(address version, address asset);

    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert Errors.WrongAddress();
        }
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    /// @notice Enters the Aave V3 Collateral Fuse with the specified asset address, enabling isolated collateral
    /// @param assetAddress collateral asset address
    function enter(address assetAddress) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, assetAddress)) {
            revert AaveV3CollateralFuseUnsupportedAsset("enter", assetAddress);
        }

        IPool pool = IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool());
        pool.setUserUseReserveAsCollateral(assetAddress, true);

        emit AaveV3EnableCollateralFuse(VERSION, assetAddress);
    }

    /// @notice Exits the Aave V3 Collateral Fuse with the specified asset address, disabling isolated collateral
    /// @param assetAddress collateral asset address
    function exit(address assetAddress) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, assetAddress)) {
            revert AaveV3CollateralFuseUnsupportedAsset("enter", assetAddress);
        }

        IPool pool = IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool());
        pool.setUserUseReserveAsCollateral(assetAddress, false);

        emit AaveV3DisableCollateralFuse(VERSION, assetAddress);
    }
}
