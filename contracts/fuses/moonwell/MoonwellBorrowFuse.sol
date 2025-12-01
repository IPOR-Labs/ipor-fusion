// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFuseCommon} from "../IFuse.sol";
import {MErc20} from "./ext/MErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {MoonwellHelperLib} from "./MoonwellHelperLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data for borrowing assets from Moonwell
/// @param asset Asset to borrow
/// @param amount Amount to borrow
struct MoonwellBorrowFuseEnterData {
    address asset;
    uint256 amount;
}

/// @notice Data for repaying borrowed assets to Moonwell
/// @param asset Asset to repay
/// @param amount Amount to repay
struct MoonwellBorrowFuseExitData {
    address asset;
    uint256 amount;
}

/// @title MoonwellBorrowFuse
/// @notice Fuse for borrowing and repaying assets in the Moonwell protocol
/// @dev Handles borrowing assets from Moonwell markets and repaying borrowed positions
contract MoonwellBorrowFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    event MoonwellBorrowEntered(address version, address asset, address market, uint256 amount);
    event MoonwellBorrowExited(address version, address asset, address market, uint256 amount);

    error MoonwellBorrowFuseUnsupportedAsset(address asset);
    error MoonwellBorrowFuseNoAssetsFound();
    error MoonwellBorrowFuseBorrowFailed();
    error MoonwellBorrowFuseRepayFailed();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Borrow assets from Moonwell
    /// @param data_ Struct containing asset and amount to borrow
    /// @return asset Asset address borrowed
    /// @return market Market address (mToken)
    /// @return amount Amount borrowed
    function enter(
        MoonwellBorrowFuseEnterData memory data_
    ) public returns (address asset, address market, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, address(0), 0);
        }

        MErc20 mToken = MErc20(
            MoonwellHelperLib.getMToken(PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID), data_.asset)
        );
        market = address(mToken);
        asset = data_.asset;
        amount = data_.amount;

        if (mToken.borrow(amount) != 0) {
            revert MoonwellBorrowFuseBorrowFailed();
        }

        emit MoonwellBorrowEntered(VERSION, asset, market, amount);
    }

    /// @notice Repay borrowed assets to Moonwell
    /// @param data_ Struct containing asset and amount to repay
    /// @return asset Asset address repaid
    /// @return market Market address (mToken)
    /// @return amount Amount repaid
    function exit(
        MoonwellBorrowFuseExitData memory data_
    ) public returns (address asset, address market, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, address(0), 0);
        }

        MErc20 mToken = MErc20(
            MoonwellHelperLib.getMToken(PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID), data_.asset)
        );
        market = address(mToken);
        asset = data_.asset;
        amount = data_.amount;

        IERC20(asset).forceApprove(market, amount);

        if (mToken.repayBorrow(amount) != 0) {
            revert MoonwellBorrowFuseRepayFailed();
        }

        IERC20(asset).forceApprove(market, 0);

        emit MoonwellBorrowExited(VERSION, asset, market, amount);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address asset = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedAsset, address returnedMarket, uint256 returnedAmount) = enter(
            MoonwellBorrowFuseEnterData(asset, amount)
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
            MoonwellBorrowFuseExitData(asset, amount)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedMarket);
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
