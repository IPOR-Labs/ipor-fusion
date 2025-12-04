// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IFuseCommon} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {MErc20} from "./ext/MErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {MoonwellHelperLib} from "./MoonwellHelperLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data for supplying assets to Moonwell
/// @param asset Asset address to supply
/// @param amount Amount of asset to supply
struct MoonwellSupplyFuseEnterData {
    address asset;
    uint256 amount;
}

/// @notice Data for withdrawing assets from Moonwell
/// @param asset Asset address to withdraw
/// @param amount Amount of asset to withdraw
struct MoonwellSupplyFuseExitData {
    address asset;
    uint256 amount;
}

/// @title MoonwellSupplyFuse
/// @notice Fuse for supplying and withdrawing assets in the Moonwell protocol
/// @dev Handles supplying assets to Moonwell markets and withdrawing supplied positions
/// @dev Substrates in this fuse are the mTokens used in Moonwell for given assets
contract MoonwellSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;
    using MoonwellHelperLib for uint256;

    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when assets are successfully supplied to Moonwell
    /// @param version The address of this fuse contract version
    /// @param asset The underlying asset address that was supplied
    /// @param market The mToken (market) address where the asset was supplied
    /// @param amount The amount of underlying asset supplied (in asset decimals)
    event MoonwellSupplyEnterFuse(address version, address asset, address market, uint256 amount);

    /// @notice Emitted when assets are successfully withdrawn from Moonwell
    /// @param version The address of this fuse contract version
    /// @param asset The underlying asset address that was withdrawn
    /// @param market The mToken (market) address from which the asset was withdrawn
    /// @param amount The amount of underlying asset withdrawn (in asset decimals)
    event MoonwellSupplyExitFuse(address version, address asset, address market, uint256 amount);

    /// @notice Emitted when asset withdrawal from Moonwell fails
    /// @param version The address of this fuse contract version
    /// @param asset The underlying asset address for which withdrawal was attempted
    /// @param market The mToken (market) address from which withdrawal was attempted
    /// @param amount The amount of underlying asset that was attempted to be withdrawn (in asset decimals)
    event MoonwellSupplyExitFailed(address version, address asset, address market, uint256 amount);

    error MoonwellSupplyFuseMintFailed();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Supply assets to Moonwell
    /// @param data_ Struct containing asset and amount to supply
    /// @return asset Asset address supplied
    /// @return market Market address (mToken)
    /// @return amount Amount supplied
    function enter(
        MoonwellSupplyFuseEnterData memory data_
    ) public returns (address asset, address market, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, address(0), 0);
        }

        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        MErc20 mToken = MErc20(MoonwellHelperLib.getMToken(assetsRaw, data_.asset));
        market = address(mToken);

        uint256 balance = ERC20(data_.asset).balanceOf(address(this));
        uint256 finalAmount = data_.amount > balance ? balance : data_.amount;

        if (finalAmount == 0) {
            return (data_.asset, market, 0);
        }

        asset = data_.asset;
        amount = finalAmount;

        ERC20(asset).forceApprove(market, amount);

        uint256 mintResult = mToken.mint(amount);
        if (mintResult != 0) {
            revert MoonwellSupplyFuseMintFailed();
        }

        emit MoonwellSupplyEnterFuse(VERSION, asset, market, amount);
    }

    /// @notice Withdraw assets from Moonwell
    /// @param data_ Struct containing asset and amount to withdraw
    /// @return asset Asset address withdrawn
    /// @return market Market address (mToken)
    /// @return amount Amount withdrawn (or attempted if failed)
    function exit(
        MoonwellSupplyFuseExitData memory data_
    ) public returns (address asset, address market, uint256 amount) {
        return _exit(data_, false);
    }

    /// @notice Handle instant withdrawals
    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    /// @param params_ Array of parameters for withdrawal
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address asset = TypeConversionLib.toAddress(params_[1]);

        _exit(MoonwellSupplyFuseExitData(asset, amount), true);
    }

    /// @dev Internal function to handle withdrawals
    /// @param data_ Struct containing withdrawal parameters
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return asset Asset address withdrawn
    /// @return market Market address (mToken)
    /// @return amount Amount withdrawn (or attempted if failed)
    function _exit(
        MoonwellSupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, address market, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, address(0), 0);
        }

        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        MErc20 mToken = MErc20(MoonwellHelperLib.getMToken(assetsRaw, data_.asset));
        market = address(mToken);
        asset = data_.asset;

        uint256 balance = mToken.balanceOfUnderlying(address(this));
        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw == 0) {
            return (asset, market, 0);
        }

        amount = _performWithdraw(asset, market, amountToWithdraw, catchExceptions_);
    }

    /// @dev Internal function to perform withdrawal
    /// @param asset_ Asset address
    /// @param mToken_ Market address (mToken)
    /// @param amountToWithdraw_ Amount to withdraw
    /// @param catchExceptions_ Whether to catch exceptions
    /// @return amount Amount withdrawn (or attempted if failed)
    function _performWithdraw(
        address asset_,
        address mToken_,
        uint256 amountToWithdraw_,
        bool catchExceptions_
    ) private returns (uint256 amount) {
        if (catchExceptions_) {
            try MErc20(mToken_).redeemUnderlying(amountToWithdraw_) returns (uint256 redeemResult) {
                if (redeemResult != 0) {
                    amount = redeemResult;
                    emit MoonwellSupplyExitFuse(VERSION, asset_, mToken_, amount);
                } else {
                    amount = amountToWithdraw_;
                    emit MoonwellSupplyExitFailed(VERSION, asset_, mToken_, amount);
                }
            } catch {
                /// @dev if withdraw failed, continue with the next step
                amount = amountToWithdraw_;
                emit MoonwellSupplyExitFailed(VERSION, asset_, mToken_, amount);
            }
        } else {
            uint256 redeemResult = MErc20(mToken_).redeemUnderlying(amountToWithdraw_);
            if (redeemResult != 0) {
                amount = redeemResult;
                emit MoonwellSupplyExitFuse(VERSION, asset_, mToken_, amount);
            } else {
                amount = amountToWithdraw_;
                emit MoonwellSupplyExitFailed(VERSION, asset_, mToken_, amount);
            }
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address asset = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedAsset, address returnedMarket, uint256 returnedAmount) = enter(
            MoonwellSupplyFuseEnterData(asset, amount)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedMarket);
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address asset = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedAsset, address returnedMarket, uint256 returnedAmount) = exit(
            MoonwellSupplyFuseExitData(asset, amount)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedMarket);
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
