// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {CErc20} from "./ext/CErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

struct CompoundV2SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

struct CompoundV2SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @title CompoundV2SupplyFuse
/// @notice Fuse for Compound V2 protocol responsible for supplying and withdrawing assets
/// @dev Substrates in this fuse are the cTokens that are used in the Compound V2 protocol for a given MARKET_ID
/// @author IPOR Labs
contract CompoundV2SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice The address of the version of the fuse
    address public immutable VERSION;

    /// @notice The market ID for the fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the Compound V2 supply fuse
    /// @param version The version of the fuse
    /// @param asset The asset address
    /// @param market The market address
    /// @param amount The amount of assets supplied
    event CompoundV2SupplyEnterFuse(address version, address asset, address market, uint256 amount);

    /// @notice Emitted when exiting the Compound V2 supply fuse
    /// @param version The version of the fuse
    /// @param asset The asset address
    /// @param market The market address
    /// @param amount The amount of assets withdrawn
    event CompoundV2SupplyExitFuse(address version, address asset, address market, uint256 amount);

    /// @notice Emitted when exiting the Compound V2 supply fuse fails
    /// @param version The version of the fuse
    /// @param asset The asset address
    /// @param market The market address
    /// @param amount The amount of assets attempted to withdraw
    event CompoundV2SupplyExitFailed(address version, address asset, address market, uint256 amount);

    /// @notice Error thrown when the asset is not supported
    /// @param asset The asset address
    error CompoundV2SupplyFuseUnsupportedAsset(address asset);

    /// @notice Constructor
    /// @param marketId_ The market ID
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters the Compound V2 supply fuse
    /// @param data_ The input data for entering the fuse
    /// @return asset The asset address
    /// @return cToken The cToken address
    /// @return amount The amount of assets supplied
    function enter(
        CompoundV2SupplyFuseEnterData memory data_
    ) public returns (address asset, address cToken, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, address(0), 0);
        }

        cToken = _getCToken(MARKET_ID, data_.asset);

        ERC20(data_.asset).forceApprove(address(cToken), data_.amount);

        CErc20(cToken).mint(data_.amount);

        asset = data_.asset;
        amount = data_.amount;

        emit CompoundV2SupplyEnterFuse(VERSION, asset, cToken, amount);
    }

    /// @notice Enters the Compound V2 supply fuse using transient storage for input/output
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address asset = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address assetUsed, address cToken, uint256 amountUsed) = enter(
            CompoundV2SupplyFuseEnterData({asset: asset, amount: amount})
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(assetUsed);
        outputs[1] = TypeConversionLib.toBytes32(cToken);
        outputs[2] = TypeConversionLib.toBytes32(amountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Compound V2 supply fuse
    /// @param data_ The input data for exiting the fuse
    /// @return asset The asset address
    /// @return cToken The cToken address
    /// @return amount The amount of assets withdrawn
    function exit(
        CompoundV2SupplyFuseExitData calldata data_
    ) external returns (address asset, address cToken, uint256 amount) {
        return _exit(data_, false);
    }

    /// @notice Exits the Compound V2 supply fuse using transient storage for input/output
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address asset = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address assetUsed, address cToken, uint256 amountUsed) = _exit(
            CompoundV2SupplyFuseExitData({asset: asset, amount: amount}),
            false
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(assetUsed);
        outputs[1] = TypeConversionLib.toBytes32(cToken);
        outputs[2] = TypeConversionLib.toBytes32(amountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Instant withdraw
    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    /// @param params_ The parameters for instant withdraw
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(CompoundV2SupplyFuseExitData(asset, amount), true);
    }

    /// @notice Internal exit logic
    /// @param data_ The input data for exiting the fuse
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return asset The asset address
    /// @return cToken The cToken address
    /// @return amount The amount of assets withdrawn
    function _exit(
        CompoundV2SupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, address cToken, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, address(0), 0);
        }

        cToken = _getCToken(MARKET_ID, data_.asset);

        uint256 balance = CErc20(cToken).balanceOfUnderlying(address(this));
        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw == 0) {
            return (data_.asset, cToken, 0);
        }

        _performWithdraw(data_.asset, cToken, amountToWithdraw, catchExceptions_);

        return (data_.asset, cToken, amountToWithdraw);
    }

    /// @notice Internal helper to get the cToken address for a given asset
    /// @param marketId_ The market ID
    /// @param asset_ The asset address
    /// @return The cToken address
    function _getCToken(uint256 marketId_, address asset_) internal view returns (address) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        uint256 len = assetsRaw.length;
        if (len == 0) {
            revert CompoundV2SupplyFuseUnsupportedAsset(asset_);
        }
        for (uint256 i; i < len; ++i) {
            address cToken = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            if (CErc20(cToken).underlying() == asset_) {
                return cToken;
            }
        }
        revert CompoundV2SupplyFuseUnsupportedAsset(asset_);
    }

    /// @notice Internal helper to perform the withdrawal
    /// @param asset_ The asset address
    /// @param cToken_ The cToken address
    /// @param amountToWithdraw_ The amount to withdraw
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    function _performWithdraw(
        address asset_,
        address cToken_,
        uint256 amountToWithdraw_,
        bool catchExceptions_
    ) private {
        if (catchExceptions_) {
            try CErc20(cToken_).redeemUnderlying(amountToWithdraw_) returns (uint256 successFlag) {
                if (successFlag == 0) {
                    emit CompoundV2SupplyExitFuse(VERSION, asset_, cToken_, amountToWithdraw_);
                } else {
                    emit CompoundV2SupplyExitFailed(VERSION, asset_, cToken_, amountToWithdraw_);
                }
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit CompoundV2SupplyExitFailed(VERSION, asset_, cToken_, amountToWithdraw_);
            }
        } else {
            uint256 successFlag = CErc20(cToken_).redeemUnderlying(amountToWithdraw_);
            if (successFlag == 0) {
                emit CompoundV2SupplyExitFuse(VERSION, asset_, cToken_, amountToWithdraw_);
            } else {
                emit CompoundV2SupplyExitFailed(VERSION, asset_, cToken_, amountToWithdraw_);
            }
        }
    }
}
