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

    function _enter(ISilo.CollateralType collateralType_, SiloV2SupplyCollateralFuseEnterData memory data_) internal {
        if (data_.siloAssetAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.siloConfig)) {
            revert SiloV2SupplyCollateralFuseUnsupportedSiloConfig("enter", data_.siloConfig);
        }

        (address silo0, address silo1) = ISiloConfig(data_.siloConfig).getSilos();

        address silo = data_.siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        address siloAssetAddress = ISilo(silo).asset();

        uint256 finalSiloAssetAmount = IporMath.min(
            ERC20(siloAssetAddress).balanceOf(address(this)),
            data_.siloAssetAmount
        );

        if (finalSiloAssetAmount < data_.minSiloAssetAmount) {
            revert SiloV2SupplyCollateralFuseInsufficientSiloAssetAmount(
                finalSiloAssetAmount,
                data_.minSiloAssetAmount
            );
        }

        IERC20(siloAssetAddress).forceApprove(silo, finalSiloAssetAmount);

        uint256 siloShares = ISilo(silo).deposit(finalSiloAssetAmount, address(this), collateralType_);

        IERC20(siloAssetAddress).forceApprove(silo, 0);

        emit SiloV2SupplyCollateralFuseEnter(
            VERSION,
            collateralType_,
            data_.siloConfig,
            silo,
            siloShares,
            finalSiloAssetAmount
        );
    }

    function _exit(ISilo.CollateralType collateralType_, SiloV2SupplyCollateralFuseExitData calldata data_) internal {
        if (data_.siloShares == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.siloConfig)) {
            revert SiloV2SupplyCollateralFuseUnsupportedSiloConfig("exit", data_.siloConfig);
        }

        (address silo0, address silo1) = ISiloConfig(data_.siloConfig).getSilos();

        address silo = data_.siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        uint256 finalSiloShares = IporMath.min(ISilo(silo).maxRedeem(address(this), collateralType_), data_.siloShares);

        if (finalSiloShares < data_.minSiloShares) {
            revert SiloV2SupplyCollateralFuseInsufficientSiloShares(finalSiloShares, data_.minSiloShares);
        }

        uint256 siloAssetAmount = ISilo(silo).redeem(finalSiloShares, address(this), address(this), collateralType_);

        emit SiloV2SupplyCollateralFuseExit(
            VERSION,
            collateralType_,
            data_.siloConfig,
            silo,
            finalSiloShares,
            siloAssetAmount
        );
    }
}
