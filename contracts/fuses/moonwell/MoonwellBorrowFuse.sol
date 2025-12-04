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

/// @notice Data structure for borrowing assets from Moonwell
/// @dev This structure contains the asset address and amount to borrow from Moonwell markets
struct MoonwellBorrowFuseEnterData {
    /// @notice The address of the underlying asset to borrow
    address asset;
    /// @notice The amount of underlying asset to borrow (in asset decimals)
    uint256 amount;
}

/// @notice Data structure for repaying borrowed assets to Moonwell
/// @dev This structure contains the asset address and amount to repay to Moonwell markets
struct MoonwellBorrowFuseExitData {
    /// @notice The address of the borrowed asset to repay
    address asset;
    /// @notice The amount of borrowed asset to repay (in asset decimals)
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

    /**
     * @notice Borrows assets from Moonwell protocol
     * @param data_ Struct containing the asset address and amount to borrow
     * @return asset The address of the borrowed asset
     * @return market The address of the mToken (market) where the asset was borrowed
     * @return amount The amount of assets borrowed (in asset decimals)
     * @dev This function:
     *      1. Validates that the amount is non-zero (returns early if zero)
     *      2. Retrieves the mToken address for the given asset from market substrates
     *      3. Calls the mToken's borrow function to borrow the specified amount
     *      4. Reverts if the borrow operation fails (non-zero error code)
     *      5. Emits an event with the borrow details including the mToken address
     */
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

    /**
     * @notice Repays borrowed assets to Moonwell protocol
     * @param data_ Struct containing the asset address and amount to repay
     * @return asset The address of the repaid asset
     * @return market The address of the mToken (market) where the asset was repaid
     * @return amount The amount of assets repaid (in asset decimals)
     * @dev This function:
     *      1. Validates that the amount is non-zero (returns early if zero)
     *      2. Retrieves the mToken address for the given asset from market substrates
     *      3. Approves the mToken to spend the repayment amount
     *      4. Calls the mToken's repayBorrow function to repay the specified amount
     *      5. Reverts if the repay operation fails (non-zero error code)
     *      6. Revokes the approval after repayment
     *      7. Emits an event with the repay details including the mToken address
     */
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

    /**
     * @notice Enters (borrows) assets from Moonwell using transient storage for parameters
     * @dev Reads asset and amount from transient storage inputs.
     *      Input 0: asset address (bytes32)
     *      Input 1: amount (bytes32)
     *      Writes returned asset, market, and amount to transient storage outputs.
     */
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

    /**
     * @notice Exits (repays) assets to Moonwell using transient storage for parameters
     * @dev Reads asset and amount from transient storage inputs.
     *      Input 0: asset address (bytes32)
     *      Input 1: amount (bytes32)
     *      Writes returned asset, market, and amount to transient storage outputs.
     */
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
