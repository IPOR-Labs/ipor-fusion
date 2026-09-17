// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IComet} from "./ext/IComet.sol";

/// @notice Structure for entering (borrow) to the Compound V3 protocol
/// @dev Compound V3 can only borrow the base token of the Comet, so the asset is fixed by the fuse (COMPOUND_BASE_TOKEN)
struct CompoundV3BorrowFuseEnterData {
    /// @notice amount of the base token to borrow
    uint256 amount;
}

/// @notice Structure for exiting (repay) from the Compound V3 protocol
/// @dev Compound V3 debt is always denominated in the base token of the Comet (COMPOUND_BASE_TOKEN)
struct CompoundV3BorrowFuseExitData {
    /// @notice amount of the base token to repay; a value greater than or equal to the current debt repays the debt in full
    uint256 amount;
}

/// @title Fuse for Compound V3 protocol responsible for borrowing and repaying the base token of a given Comet market
/// @notice Borrows the Comet base token against collateral supplied to the Comet and repays it, never repaying more than the outstanding debt
/// @dev Substrates in this fuse are the assets that are used in the Compound V3 protocol for a given MARKET_ID.
///      The base token of the Comet must be granted as a substrate of MARKET_ID to borrow or repay.
///      Collateral is supplied and withdrawn with CompoundV3SupplyFuse. Health and collateralization checks are
///      performed by the Comet itself (e.g. NotCollateralized, BorrowTooSmall), not by this fuse.
///      The fuse is stateless and executed via delegatecall in the context of the Plasma Vault.
/// @author IPOR Labs
contract CompoundV3BorrowFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice The address of the version of the Fuse
    address public immutable VERSION;

    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice The Compound V3 Comet market used by the Fuse
    IComet public immutable COMET;

    /// @notice The base token of the Comet market, the only asset that can be borrowed and repaid
    address public immutable COMPOUND_BASE_TOKEN;

    /// @notice Emitted when the base token is borrowed from the Comet
    /// @param version The address of the fuse version
    /// @param asset The address of the borrowed asset (Comet base token)
    /// @param market The address of the Comet market
    /// @param amount The amount of the asset borrowed
    event CompoundV3BorrowFuseEnter(address version, address asset, address market, uint256 amount);

    /// @notice Emitted when the base token debt is repaid to the Comet
    /// @param version The address of the fuse version
    /// @param asset The address of the repaid asset (Comet base token)
    /// @param market The address of the Comet market
    /// @param repaidAmount The amount of the asset repaid
    event CompoundV3BorrowFuseExit(address version, address asset, address market, uint256 repaidAmount);

    /// @notice Error thrown when the asset is not granted as a substrate for the MARKET_ID
    /// @param action The action being performed ("enter" or "exit")
    /// @param asset The address of the unsupported asset
    error CompoundV3BorrowFuseUnsupportedAsset(string action, address asset);

    /// @notice Error thrown when market ID is zero
    error CompoundV3BorrowFuseInvalidMarketId();

    /// @notice Error thrown when the Comet address is the zero address
    error CompoundV3BorrowFuseInvalidAddress();

    /// @notice Constructor for CompoundV3BorrowFuse
    /// @dev Validates the inputs before reading the base token from the Comet
    /// @param marketId_ The Market ID associated with the Fuse
    /// @param cometAddress_ The address of the Compound V3 Comet market
    constructor(uint256 marketId_, address cometAddress_) {
        if (marketId_ == 0) {
            revert CompoundV3BorrowFuseInvalidMarketId();
        }
        if (cometAddress_ == address(0)) {
            revert CompoundV3BorrowFuseInvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        COMET = IComet(cometAddress_);
        COMPOUND_BASE_TOKEN = COMET.baseToken();
    }

    /// @notice Borrows the base token from the Comet
    /// @dev Compound V3 keeps a single signed base balance per account: if the Plasma Vault has a positive base supply
    ///      on this Comet, the withdrawal first consumes that supply and only the remainder becomes debt.
    ///      Borrows exceeding the collateralization limit revert in the Comet with NotCollateralized(),
    ///      borrows leaving the total debt below baseBorrowMin revert with BorrowTooSmall().
    /// @param data_ Enter data containing the amount of the base token to borrow
    /// @return asset The address of the borrowed asset (Comet base token)
    /// @return market The address of the Comet market
    /// @return amount The amount of the asset borrowed
    function enter(
        CompoundV3BorrowFuseEnterData memory data_
    ) public returns (address asset, address market, uint256 amount) {
        if (data_.amount == 0) {
            return (COMPOUND_BASE_TOKEN, address(COMET), 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, COMPOUND_BASE_TOKEN)) {
            revert CompoundV3BorrowFuseUnsupportedAsset("enter", COMPOUND_BASE_TOKEN);
        }

        COMET.withdraw(COMPOUND_BASE_TOKEN, data_.amount);

        emit CompoundV3BorrowFuseEnter(VERSION, COMPOUND_BASE_TOKEN, address(COMET), data_.amount);

        return (COMPOUND_BASE_TOKEN, address(COMET), data_.amount);
    }

    /// @notice Borrows the base token from the Comet using transient storage for inputs
    /// @dev Reads the amount from transient storage input[0]
    /// @dev Writes the returned asset, market and amount to transient storage outputs
    function enterTransient() external {
        uint256 amount = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 0));

        (address assetUsed, address market, uint256 amountUsed) = enter(
            CompoundV3BorrowFuseEnterData({amount: amount})
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(assetUsed);
        outputs[1] = TypeConversionLib.toBytes32(market);
        outputs[2] = TypeConversionLib.toBytes32(amountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Repays the base token debt to the Comet, capped at the outstanding debt
    /// @dev If the requested amount is greater than or equal to the current debt, the debt is repaid in full using
    ///      type(uint256).max, which the Comet resolves to the accrued borrow balance, so no base supply position is created.
    ///      The repay amount is not capped to the idle base token balance of the Plasma Vault; if the vault holds less
    ///      than the repay amount, the token transfer reverts. The allowance is revoked after the repay.
    /// @param data_ Exit data containing the amount of the base token to repay
    /// @return asset The address of the repaid asset (Comet base token)
    /// @return market The address of the Comet market
    /// @return amount The amount of the asset repaid
    function exit(
        CompoundV3BorrowFuseExitData memory data_
    ) public returns (address asset, address market, uint256 amount) {
        if (data_.amount == 0) {
            return (COMPOUND_BASE_TOKEN, address(COMET), 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, COMPOUND_BASE_TOKEN)) {
            revert CompoundV3BorrowFuseUnsupportedAsset("exit", COMPOUND_BASE_TOKEN);
        }

        uint256 debt = COMET.borrowBalanceOf(address(this));

        if (debt == 0) {
            return (COMPOUND_BASE_TOKEN, address(COMET), 0);
        }

        uint256 finalAmount = IporMath.min(data_.amount, debt);

        ERC20(COMPOUND_BASE_TOKEN).forceApprove(address(COMET), finalAmount);

        if (data_.amount >= debt) {
            COMET.supply(COMPOUND_BASE_TOKEN, type(uint256).max);
        } else {
            COMET.supply(COMPOUND_BASE_TOKEN, finalAmount);
        }

        ERC20(COMPOUND_BASE_TOKEN).forceApprove(address(COMET), 0);

        emit CompoundV3BorrowFuseExit(VERSION, COMPOUND_BASE_TOKEN, address(COMET), finalAmount);

        return (COMPOUND_BASE_TOKEN, address(COMET), finalAmount);
    }

    /// @notice Repays the base token debt to the Comet using transient storage for inputs
    /// @dev Reads the amount from transient storage input[0]
    /// @dev Writes the returned asset, market and amount to transient storage outputs
    function exitTransient() external {
        uint256 amount = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 0));

        (address assetUsed, address market, uint256 amountUsed) = exit(CompoundV3BorrowFuseExitData({amount: amount}));

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(assetUsed);
        outputs[1] = TypeConversionLib.toBytes32(market);
        outputs[2] = TypeConversionLib.toBytes32(amountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
