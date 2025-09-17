// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";

/// @notice Data for lever-down action
struct EbisuLeverDownData {
    address zapper;
    uint256 flashLoanAmount;
    uint256 minBoldAmount;  // minimum BOLD/EBUSD to receive when deleveraging
}

/// @notice Data for lever-up action
struct EbisuLeverUpData {
    address zapper;
    uint256 flashLoanAmount;
    uint256 ebusdAmount;     // BOLD/EBUSD to add as debt
    uint256 maxUpfrontFee;   // safety bound for zapper
}

contract EbisuZapperLeverModifyFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();

    event EbisuZapperCreateFuseLeverDown(address zapper, uint256 ownerIndex, uint256 flashLoanAmount, uint256 minBoldAmount);
    event EbisuZapperCreateFuseLeverUp(address zapper, uint256 ownerIndex, uint256 flashLoanAmount, uint256 ebusdAmount);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function enter(EbisuLeverUpData memory data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.zapper)) revert UnsupportedSubstrate();

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();
        uint256 troveId = troveData.troveIds[data.zapper];

        ILeverageZapper.LeverUpTroveParams memory params = ILeverageZapper.LeverUpTroveParams({
            troveId: troveId,
            flashLoanAmount: data.flashLoanAmount,
            boldAmount: data.ebusdAmount,
            maxUpfrontFee: data.maxUpfrontFee
        });

        ILeverageZapper(data.zapper).leverUpTrove(params);

        emit EbisuZapperCreateFuseLeverUp(data.zapper, troveData.latestOwnerId, data.flashLoanAmount, data.ebusdAmount);
    }

    function exit(EbisuLeverDownData memory data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.zapper)) revert UnsupportedSubstrate();

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();
        uint256 troveId = troveData.troveIds[data.zapper];

        ILeverageZapper.LeverDownTroveParams memory params = ILeverageZapper.LeverDownTroveParams({
            troveId: troveId,
            flashLoanAmount: data.flashLoanAmount,
            minBoldAmount: data.minBoldAmount
        });

        ILeverageZapper(data.zapper).leverDownTrove(params);

        emit EbisuZapperCreateFuseLeverDown(data.zapper, troveData.latestOwnerId, data.flashLoanAmount, data.minBoldAmount);
    }
}
