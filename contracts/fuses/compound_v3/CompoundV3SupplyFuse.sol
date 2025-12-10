// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IComet} from "./ext/IComet.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

struct CompoundV3SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

struct CompoundV3SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @title Fuse for Compound V3 protocol responsible for supplying and withdrawing assets from the Compound V3 protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the Compound V3 protocol for a given MARKET_ID
contract CompoundV3SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IComet public immutable COMET;
    address public immutable COMPOUND_BASE_TOKEN;

    event CompoundV3SupplyFuseEnter(address version, address asset, address market, uint256 amount);
    event CompoundV3SupplyFuseExit(address version, address asset, address market, uint256 amount);
    event CompoundV3SupplyFuseExitFailed(address version, address asset, address market, uint256 amount);

    error CompoundV3SupplyFuseUnsupportedAsset(string action, address asset);

    constructor(uint256 marketId_, address cometAddress_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        COMET = IComet(cometAddress_);
        COMPOUND_BASE_TOKEN = COMET.baseToken();
    }

    function enter(
        CompoundV3SupplyFuseEnterData memory data_
    ) public returns (address asset, address market, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, address(COMET), 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("enter", data_.asset);
        }

        ERC20(data_.asset).forceApprove(address(COMET), data_.amount);

        COMET.supply(data_.asset, data_.amount);

        emit CompoundV3SupplyFuseEnter(VERSION, data_.asset, address(COMET), data_.amount);

        return (data_.asset, address(COMET), data_.amount);
    }

    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address asset = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address assetUsed, address market, uint256 amountUsed) = enter(
            CompoundV3SupplyFuseEnterData({asset: asset, amount: amount})
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(assetUsed);
        outputs[1] = TypeConversionLib.toBytes32(market);
        outputs[2] = TypeConversionLib.toBytes32(amountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function exit(
        CompoundV3SupplyFuseExitData calldata data_
    ) external returns (address asset, address market, uint256 amount) {
        return _exit(data_, false);
    }

    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address asset = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address assetUsed, address market, uint256 amountUsed) = _exit(
            CompoundV3SupplyFuseExitData({asset: asset, amount: amount}),
            false
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(assetUsed);
        outputs[1] = TypeConversionLib.toBytes32(market);
        outputs[2] = TypeConversionLib.toBytes32(amountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(CompoundV3SupplyFuseExitData(asset, amount), true);
    }

    function _exit(
        CompoundV3SupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, address market, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, address(COMET), 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("exit", data_.asset);
        }

        uint256 finalAmount = IporMath.min(data_.amount, _getBalance(data_.asset));

        if (finalAmount == 0) {
            return (data_.asset, address(COMET), 0);
        }

        _performWithdraw(data_.asset, finalAmount, catchExceptions_);

        return (data_.asset, address(COMET), finalAmount);
    }

    function _getBalance(address asset_) private view returns (uint256) {
        if (asset_ == COMPOUND_BASE_TOKEN) {
            return COMET.balanceOf(address(this));
        } else {
            return COMET.collateralBalanceOf(address(this), asset_);
        }
    }

    function _performWithdraw(address asset_, uint256 finalAmount_, bool catchExceptions_) private {
        if (catchExceptions_) {
            try COMET.withdraw(asset_, finalAmount_) {
                emit CompoundV3SupplyFuseExit(VERSION, asset_, address(COMET), finalAmount_);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit CompoundV3SupplyFuseExitFailed(VERSION, asset_, address(COMET), finalAmount_);
            }
        } else {
            COMET.withdraw(asset_, finalAmount_);
            emit CompoundV3SupplyFuseExit(VERSION, asset_, address(COMET), finalAmount_);
        }
    }
}
