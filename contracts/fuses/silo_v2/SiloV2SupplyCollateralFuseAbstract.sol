// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SiloIndex} from "./SiloIndex.sol";
import {ISilo} from "./ext/ISilo.sol";
import {ISiloConfig} from "./ext/ISiloConfig.sol";

struct SiloV2SupplyCollateralFuseEnterData {
    /// @dev Silo Config address - contract that manages the Silo
    address siloConfig;
    /// @dev Specify which silo to supply Silo0 or Silo1
    SiloIndex siloIndex;
    /// @dev amount of Silo underlying asset to supply
    uint256 siloAssetAmount;
    /// @dev minimum amount of Silo underlying asset to supply
    uint256 minSiloAssetAmount;
}

struct SiloV2SupplyCollateralFuseExitData {
    /// @dev Silo Config address - contract that manages the Silo
    address siloConfig;
    /// @dev Specify which silo to withdraw Silo0 or Silo1
    SiloIndex siloIndex;
    /// @dev amount of Silo shares to withdraw
    uint256 siloShares;
    /// @dev minimum amount of Silo shares to withdraw
    uint256 minSiloShares;
}

abstract contract SiloV2SupplyCollateralFuseAbstract is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event SiloV2SupplyCollateralFuseEnter(
        address version,
        ISilo.CollateralType collateralType,
        address siloConfig,
        address silo,
        uint256 siloShares,
        uint256 siloAssetAmount
    );

    event SiloV2SupplyCollateralFuseExit(
        address version,
        ISilo.CollateralType collateralType,
        address siloConfig,
        address silo,
        uint256 siloShares,
        uint256 siloAssetAmount
    );

    error SiloV2SupplyCollateralFuseUnsupportedSiloConfig(string action, address siloConfig);
    error SiloV2SupplyCollateralFuseInsufficientSiloAssetAmount(uint256 finalSiloAssetAmount, uint256 minAmount);
    error SiloV2SupplyCollateralFuseInsufficientSiloShares(uint256 finalSiloShares, uint256 minSiloShares);

    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function _enter(
        ISilo.CollateralType collateralType_,
        SiloV2SupplyCollateralFuseEnterData memory data_
    )
        internal
        returns (
            ISilo.CollateralType collateralType,
            address siloConfig,
            address silo,
            uint256 siloShares,
            uint256 siloAssetAmount
        )
    {
        if (data_.siloAssetAmount == 0) {
            return (collateralType_, data_.siloConfig, address(0), 0, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.siloConfig)) {
            revert SiloV2SupplyCollateralFuseUnsupportedSiloConfig("enter", data_.siloConfig);
        }

        (address silo0, address silo1) = ISiloConfig(data_.siloConfig).getSilos();

        silo = data_.siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        address siloAssetAddress = ISilo(silo).asset();

        siloAssetAmount = IporMath.min(ERC20(siloAssetAddress).balanceOf(address(this)), data_.siloAssetAmount);

        if (siloAssetAmount < data_.minSiloAssetAmount) {
            revert SiloV2SupplyCollateralFuseInsufficientSiloAssetAmount(siloAssetAmount, data_.minSiloAssetAmount);
        }

        IERC20(siloAssetAddress).forceApprove(silo, siloAssetAmount);

        siloShares = ISilo(silo).deposit(siloAssetAmount, address(this), collateralType_);

        IERC20(siloAssetAddress).forceApprove(silo, 0);

        collateralType = collateralType_;
        siloConfig = data_.siloConfig;

        emit SiloV2SupplyCollateralFuseEnter(VERSION, collateralType, siloConfig, silo, siloShares, siloAssetAmount);
    }

    function _exit(
        ISilo.CollateralType collateralType_,
        SiloV2SupplyCollateralFuseExitData memory data_
    )
        internal
        returns (
            ISilo.CollateralType collateralType,
            address siloConfig,
            address silo,
            uint256 siloShares,
            uint256 siloAssetAmount
        )
    {
        if (data_.siloShares == 0) {
            return (collateralType_, data_.siloConfig, address(0), 0, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.siloConfig)) {
            revert SiloV2SupplyCollateralFuseUnsupportedSiloConfig("exit", data_.siloConfig);
        }

        (address silo0, address silo1) = ISiloConfig(data_.siloConfig).getSilos();

        silo = data_.siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        siloShares = IporMath.min(ISilo(silo).maxRedeem(address(this), collateralType_), data_.siloShares);

        if (siloShares < data_.minSiloShares) {
            revert SiloV2SupplyCollateralFuseInsufficientSiloShares(siloShares, data_.minSiloShares);
        }

        siloAssetAmount = ISilo(silo).redeem(siloShares, address(this), address(this), collateralType_);

        collateralType = collateralType_;
        siloConfig = data_.siloConfig;

        emit SiloV2SupplyCollateralFuseExit(VERSION, collateralType, siloConfig, silo, siloShares, siloAssetAmount);
    }
}
