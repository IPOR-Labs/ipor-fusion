// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";

/// @notice "enter" is a lever-up action
struct EbisuZapperLeverModifyFuseEnterData {
    address zapper;
    uint256 flashLoanAmount;
    uint256 ebusdAmount; // BOLD/EBUSD to add as debt
    uint256 maxUpfrontFee; // safety bound for zapper
}

/// @notice "exit" is a lever-down action
struct EbisuZapperLeverModifyFuseExitData {
    address zapper;
    uint256 flashLoanAmount;
    uint256 minBoldAmount; // minimum BOLD/EBUSD to receive when deleveraging
}

/// @notice Fuse to operate lever-up and lever-down in the open trove
contract EbisuZapperLeverModifyFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();

    event EbisuZapperLeverModifyLeverDown(
        address zapper,
        uint256 troveId,
        uint256 flashLoanAmount,
        uint256 minBoldAmount
    );
    event EbisuZapperLeverModifyLeverUp(address zapper, uint256 troveId, uint256 flashLoanAmount, uint256 ebusdAmount);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice we model lever-up with the "enter" function
    /// The Zapper requests a flash loan to have more collateral with which it mints more ebUSD
    /// The ebUSD are then swapped for collateral to repay the flash loan
    /// This has the effect of increasing both the debt and the collateral of the trove
    /// Any collateral dust is given back to the plasmaVault
    function enter(EbisuZapperLeverModifyFuseEnterData memory data_) external {
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

        uint256 troveId = FuseStorageLib.getEbisuTroveIds().troveIds[data_.zapper];

        ILeverageZapper.LeverUpTroveParams memory params = ILeverageZapper.LeverUpTroveParams({
            troveId: troveId,
            flashLoanAmount: data_.flashLoanAmount,
            boldAmount: data_.ebusdAmount,
            maxUpfrontFee: data_.maxUpfrontFee
        });

        ILeverageZapper(data_.zapper).leverUpTrove(params);

        emit EbisuZapperLeverModifyLeverUp(data_.zapper, troveId, data_.flashLoanAmount, data_.ebusdAmount);
    }

    /// @notice we model lever-down with the "exit" function
    /// The Zapper requests a flash loan to have some collateral which is swapped to get ebUSD
    /// The ebUSD obtained are used to repay part of the trove debt
    /// This unlocks some collateral from the trove, which is redeemed to repay the flash loan
    /// This has the effect of decreasing both the debt and the collateral amount from the trove
    /// Any dust in ebUSD is given back to the plasmaVault
    function exit(EbisuZapperLeverModifyFuseExitData memory data_) external {
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

        uint256 troveId = FuseStorageLib.getEbisuTroveIds().troveIds[data_.zapper];

        ILeverageZapper.LeverDownTroveParams memory params = ILeverageZapper.LeverDownTroveParams({
            troveId: troveId,
            flashLoanAmount: data_.flashLoanAmount,
            minBoldAmount: data_.minBoldAmount
        });

        ILeverageZapper(data_.zapper).leverDownTrove(params);

        emit EbisuZapperLeverModifyLeverDown(data_.zapper, troveId, data_.flashLoanAmount, data_.minBoldAmount);
    }
}
