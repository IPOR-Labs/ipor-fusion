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
    uint256 ebusdAmount;     // BOLD/EBUSD to add as debt
    uint256 maxUpfrontFee;   // safety bound for zapper
}

/// @notice "exit" is a lever-down action
struct EbisuZapperLeverModifyFuseExitData {
    address zapper;
    uint256 flashLoanAmount;
    uint256 minBoldAmount;  // minimum BOLD/EBUSD to receive when deleveraging
}

contract EbisuZapperLeverModifyFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();

    event EbisuZapperLeverModifyLeverDown(address zapper, uint256 troveId, uint256 flashLoanAmount, uint256 minBoldAmount);
    event EbisuZapperLeverModifyLeverUp(address zapper, uint256 troveId, uint256 flashLoanAmount, uint256 ebusdAmount);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function enter(EbisuZapperLeverModifyFuseEnterData memory data) external {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, 
            EbisuZapperSubstrateLib.substrateToBytes32(
                EbisuZapperSubstrate({
                    substrateType: EbisuZapperSubstrateType.Zapper,
                    substrateAddress: data.zapper
            })))) revert UnsupportedSubstrate();

        uint256 troveId = FuseStorageLib.getEbisuTroveIds().troveIds[data.zapper];

        ILeverageZapper.LeverUpTroveParams memory params = ILeverageZapper.LeverUpTroveParams({
            troveId: troveId,
            flashLoanAmount: data.flashLoanAmount,
            boldAmount: data.ebusdAmount,
            maxUpfrontFee: data.maxUpfrontFee
        });

        ILeverageZapper(data.zapper).leverUpTrove(params);

        emit EbisuZapperLeverModifyLeverUp(data.zapper, troveId, data.flashLoanAmount, data.ebusdAmount);
    }

    function exit(EbisuZapperLeverModifyFuseExitData memory data) external {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, 
            EbisuZapperSubstrateLib.substrateToBytes32(
                EbisuZapperSubstrate({
                    substrateType: EbisuZapperSubstrateType.Zapper,
                    substrateAddress: data.zapper
            })))) revert UnsupportedSubstrate();

        uint256 troveId = FuseStorageLib.getEbisuTroveIds().troveIds[data.zapper];

        ILeverageZapper.LeverDownTroveParams memory params = ILeverageZapper.LeverDownTroveParams({
            troveId: troveId,
            flashLoanAmount: data.flashLoanAmount,
            minBoldAmount: data.minBoldAmount
        });

        ILeverageZapper(data.zapper).leverDownTrove(params);

        emit EbisuZapperLeverModifyLeverDown(data.zapper, troveId, data.flashLoanAmount, data.minBoldAmount);
    }
}
