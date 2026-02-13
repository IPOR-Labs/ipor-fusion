// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/**
 * @notice Data structure for lever-up action (enter function)
 * @dev Contains parameters required to increase leverage of an existing Trove
 */
struct EbisuZapperLeverModifyFuseEnterData {
    /// @notice The address of the Ebisu Zapper contract to use for lever-up
    address zapper;
    /// @notice The amount of flash loan requested to increase leverage
    /// @dev This flash loan is used to obtain additional collateral, which is then used to mint more ebUSD
    uint256 flashLoanAmount;
    /// @notice The amount of BOLD/EBUSD to add as debt to the Trove
    /// @dev This is the amount of ebUSD that will be minted and added to the Trove's debt
    uint256 ebusdAmount;
    /// @notice The maximum upfront fee the user is willing to pay (safety bound for zapper)
    /// @dev Used as slippage protection to prevent excessive fees
    uint256 maxUpfrontFee;
}

/**
 * @notice Data structure for lever-down action (exit function)
 * @dev Contains parameters required to decrease leverage of an existing Trove
 */
struct EbisuZapperLeverModifyFuseExitData {
    /// @notice The address of the Ebisu Zapper contract to use for lever-down
    address zapper;
    /// @notice The amount of flash loan requested to decrease leverage
    /// @dev This flash loan is used to obtain collateral, which is swapped for ebUSD to repay debt
    uint256 flashLoanAmount;
    /// @notice The minimum BOLD/EBUSD amount to receive when deleveraging
    /// @dev Used as slippage protection to ensure sufficient ebUSD is obtained from collateral swap
    uint256 minBoldAmount;
}

/**
 * @title Fuse for modifying leverage of existing Troves in Ebisu protocol
 * @notice Provides functionality to increase (lever-up) or decrease (lever-down) leverage of open Troves
 * @dev This fuse operates on Troves that are already open, allowing users to adjust their leverage
 *      without closing and reopening the Trove
 */
contract EbisuZapperLeverModifyFuse is IFuseCommon {
    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates
    uint256 public immutable MARKET_ID;

    /// @notice Thrown when zapper substrate is not granted for the market
    /// @custom:error UnsupportedSubstrate
    error UnsupportedSubstrate();

    /// @notice Emitted when a Trove's leverage is successfully decreased (lever-down)
    /// @param zapper The address of the zapper used for lever-down operation
    /// @param troveId The unique identifier of the Trove being modified
    /// @param flashLoanAmount The amount of flash loan used for the operation
    /// @param minBoldAmount The minimum BOLD/EBUSD amount received from the operation
    event EbisuZapperLeverModifyLeverDown(
        address zapper,
        uint256 troveId,
        uint256 flashLoanAmount,
        uint256 minBoldAmount
    );

    /// @notice Emitted when a Trove's leverage is successfully increased (lever-up)
    /// @param zapper The address of the zapper used for lever-up operation
    /// @param troveId The unique identifier of the Trove being modified
    /// @param flashLoanAmount The amount of flash loan used for the operation
    /// @param ebusdAmount The amount of BOLD/EBUSD added as debt to the Trove
    event EbisuZapperLeverModifyLeverUp(address zapper, uint256 troveId, uint256 flashLoanAmount, uint256 ebusdAmount);

    /**
     * @notice Initializes the EbisuZapperLeverModifyFuse with a market ID
     * @param marketId_ The market ID used to identify the Ebisu protocol market substrates
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Increases leverage of an existing Trove (lever-up action)
     * @dev The Zapper requests a flash loan to obtain more collateral, which is used to mint more ebUSD.
     *      The ebUSD are then swapped for collateral to repay the flash loan.
     *      This operation increases both the debt and the collateral of the Trove.
     *      Any collateral dust remaining after the operation is returned to the PlasmaVault.
     *      Validates that the zapper is granted as a substrate for the market.
     * @param data_ The data structure containing all parameters for the lever-up operation
     * @return zapper The address of the zapper used for the operation
     * @return troveId The unique identifier of the Trove being modified
     * @custom:revert UnsupportedSubstrate When zapper is not granted as substrate
     */
    function enter(EbisuZapperLeverModifyFuseEnterData memory data_) public returns (address zapper, uint256 troveId) {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({
                        substrateType: EbisuZapperSubstrateType.ZAPPER,
                        substrateAddress: data_.zapper
                    })
                )
            )
        ) revert UnsupportedSubstrate();

        troveId = FuseStorageLib.getEbisuTroveIds().troveIds[data_.zapper];

        ILeverageZapper.LeverUpTroveParams memory params = ILeverageZapper.LeverUpTroveParams({
            troveId: troveId,
            flashLoanAmount: data_.flashLoanAmount,
            boldAmount: data_.ebusdAmount,
            maxUpfrontFee: data_.maxUpfrontFee
        });

        ILeverageZapper(data_.zapper).leverUpTrove(params);

        emit EbisuZapperLeverModifyLeverUp(data_.zapper, troveId, data_.flashLoanAmount, data_.ebusdAmount);

        return (data_.zapper, troveId);
    }

    /**
     * @notice Transient version of enter function that reads inputs from transient storage
     * @dev Reads all required parameters from transient storage, calls enter function,
     *      and writes outputs back to transient storage
     */
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        EbisuZapperLeverModifyFuseEnterData memory data;
        data.zapper = TypeConversionLib.toAddress(inputs[0]);
        data.flashLoanAmount = TypeConversionLib.toUint256(inputs[1]);
        data.ebusdAmount = TypeConversionLib.toUint256(inputs[2]);
        data.maxUpfrontFee = TypeConversionLib.toUint256(inputs[3]);

        (address zapper, uint256 troveId) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(zapper);
        outputs[1] = TypeConversionLib.toBytes32(troveId);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /**
     * @notice Decreases leverage of an existing Trove (lever-down action)
     * @dev The Zapper requests a flash loan to obtain collateral, which is swapped for ebUSD.
     *      The ebUSD obtained are used to repay part of the Trove's debt.
     *      This unlocks some collateral from the Trove, which is redeemed to repay the flash loan.
     *      This operation decreases both the debt and the collateral amount of the Trove.
     *      Any dust in ebUSD remaining after the operation is returned to the PlasmaVault.
     *      Validates that the zapper is granted as a substrate for the market.
     * @param data_ The data structure containing all parameters for the lever-down operation
     * @return zapper The address of the zapper used for the operation
     * @return troveId The unique identifier of the Trove being modified
     * @custom:revert UnsupportedSubstrate When zapper is not granted as substrate
     */
    function exit(EbisuZapperLeverModifyFuseExitData memory data_) public returns (address zapper, uint256 troveId) {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({
                        substrateType: EbisuZapperSubstrateType.ZAPPER,
                        substrateAddress: data_.zapper
                    })
                )
            )
        ) revert UnsupportedSubstrate();

        troveId = FuseStorageLib.getEbisuTroveIds().troveIds[data_.zapper];

        ILeverageZapper.LeverDownTroveParams memory params = ILeverageZapper.LeverDownTroveParams({
            troveId: troveId,
            flashLoanAmount: data_.flashLoanAmount,
            minBoldAmount: data_.minBoldAmount
        });

        ILeverageZapper(data_.zapper).leverDownTrove(params);

        emit EbisuZapperLeverModifyLeverDown(data_.zapper, troveId, data_.flashLoanAmount, data_.minBoldAmount);

        return (data_.zapper, troveId);
    }

    /**
     * @notice Transient version of exit function that reads inputs from transient storage
     * @dev Reads all required parameters from transient storage, calls exit function,
     *      and writes outputs back to transient storage
     */
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        EbisuZapperLeverModifyFuseExitData memory data;
        data.zapper = TypeConversionLib.toAddress(inputs[0]);
        data.flashLoanAmount = TypeConversionLib.toUint256(inputs[1]);
        data.minBoldAmount = TypeConversionLib.toUint256(inputs[2]);

        (address zapper, uint256 troveId) = exit(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(zapper);
        outputs[1] = TypeConversionLib.toBytes32(troveId);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
