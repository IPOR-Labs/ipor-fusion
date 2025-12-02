// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ISilo} from "./ext/ISilo.sol";
import {SiloV2SupplyCollateralFuseAbstract, SiloV2SupplyCollateralFuseEnterData, SiloV2SupplyCollateralFuseExitData} from "./SiloV2SupplyCollateralFuseAbstract.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {SiloIndex} from "./SiloIndex.sol";

/// @title SiloV2SupplyBorrowableCollateralFuse
/// @notice Fuse for supplying borrowable collateral to Silo V2 protocol
/// @author IPOR Labs
contract SiloV2SupplyBorrowableCollateralFuse is SiloV2SupplyCollateralFuseAbstract {
    /// @notice Constructor
    /// @param marketId_ The market ID
    constructor(uint256 marketId_) SiloV2SupplyCollateralFuseAbstract(marketId_) {}

    /// @notice Enters the Fuse by supplying collateral to Silo V2
    /// @param data_ The data structure containing silo config, silo index, and amounts
    /// @return collateralType The type of collateral (Collateral)
    /// @return siloConfig The Silo Config address
    /// @return silo The Silo address
    /// @return siloShares The amount of Silo shares received
    /// @return siloAssetAmount The amount of Silo underlying asset supplied
    function enter(
        SiloV2SupplyCollateralFuseEnterData memory data_
    )
        public
        returns (
            ISilo.CollateralType collateralType,
            address siloConfig,
            address silo,
            uint256 siloShares,
            uint256 siloAssetAmount
        )
    {
        return _enter(ISilo.CollateralType.Collateral, data_);
    }

    /// @notice Exits the Fuse by withdrawing collateral from Silo V2
    /// @param data_ The data structure containing silo config, silo index, and share amounts
    /// @return collateralType The type of collateral (Collateral)
    /// @return siloConfig The Silo Config address
    /// @return silo The Silo address
    /// @return siloShares The amount of Silo shares redeemed
    /// @return siloAssetAmount The amount of Silo underlying asset received
    function exit(
        SiloV2SupplyCollateralFuseExitData memory data_
    )
        public
        returns (
            ISilo.CollateralType collateralType,
            address siloConfig,
            address silo,
            uint256 siloShares,
            uint256 siloAssetAmount
        )
    {
        return _exit(ISilo.CollateralType.Collateral, data_);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address siloConfig = TypeConversionLib.toAddress(inputs[0]);
        SiloIndex siloIndex = SiloIndex(TypeConversionLib.toUint256(inputs[1]));
        uint256 siloAssetAmount = TypeConversionLib.toUint256(inputs[2]);
        uint256 minSiloAssetAmount = TypeConversionLib.toUint256(inputs[3]);

        (
            ISilo.CollateralType collateralType,
            address returnedSiloConfig,
            address silo,
            uint256 siloShares,
            uint256 returnedSiloAssetAmount
        ) = enter(
                SiloV2SupplyCollateralFuseEnterData({
                    siloConfig: siloConfig,
                    siloIndex: siloIndex,
                    siloAssetAmount: siloAssetAmount,
                    minSiloAssetAmount: minSiloAssetAmount
                })
            );

        bytes32[] memory outputs = new bytes32[](5);
        outputs[0] = TypeConversionLib.toBytes32(uint256(collateralType));
        outputs[1] = TypeConversionLib.toBytes32(returnedSiloConfig);
        outputs[2] = TypeConversionLib.toBytes32(silo);
        outputs[3] = TypeConversionLib.toBytes32(siloShares);
        outputs[4] = TypeConversionLib.toBytes32(returnedSiloAssetAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address siloConfig = TypeConversionLib.toAddress(inputs[0]);
        SiloIndex siloIndex = SiloIndex(TypeConversionLib.toUint256(inputs[1]));
        uint256 siloShares = TypeConversionLib.toUint256(inputs[2]);
        uint256 minSiloShares = TypeConversionLib.toUint256(inputs[3]);

        (
            ISilo.CollateralType collateralType,
            address returnedSiloConfig,
            address silo,
            uint256 returnedSiloShares,
            uint256 siloAssetAmount
        ) = exit(
                SiloV2SupplyCollateralFuseExitData({
                    siloConfig: siloConfig,
                    siloIndex: siloIndex,
                    siloShares: siloShares,
                    minSiloShares: minSiloShares
                })
            );

        bytes32[] memory outputs = new bytes32[](5);
        outputs[0] = TypeConversionLib.toBytes32(uint256(collateralType));
        outputs[1] = TypeConversionLib.toBytes32(returnedSiloConfig);
        outputs[2] = TypeConversionLib.toBytes32(silo);
        outputs[3] = TypeConversionLib.toBytes32(returnedSiloShares);
        outputs[4] = TypeConversionLib.toBytes32(siloAssetAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
