// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {EbisuMathLibrary} from "./EbisuMathLibrary.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";

/// @notice Data for lever-down action
struct EbisuLeverDownData {
    address zapper;
    address wethEthAdapter;
    uint256 flashLoanAmount;
    uint256 minBoldAmount;  // minimum BOLD/EBUSD to receive when deleveraging
}

contract EbisuZapperLeverDownFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();
    error TargetIsNotAContract();

    event EbisuZapperFuseLeverDown(address zapper, uint256 ownerIndex, uint256 flashLoanAmount, uint256 minBoldAmount);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function execute(EbisuLeverDownData memory data) external {
        _requireWhitelistedContract(MARKET_ID, data.zapper);

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();
        uint256 troveId = troveData.troveIds[data.zapper];

        ILeverageZapper.LeverDownTroveParams memory params = ILeverageZapper.LeverDownTroveParams({
            troveId: troveId,
            flashLoanAmount: data.flashLoanAmount,
            minBoldAmount: data.minBoldAmount
        });

        ILeverageZapper(data.zapper).leverDownTrove(params);

        emit EbisuZapperFuseLeverDown(data.zapper, troveData.latestOwnerId, data.flashLoanAmount, data.minBoldAmount);
    }

    // --- internals ---

    function _requireWhitelistedContract(uint256 marketId, address target) internal view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(marketId, target)) revert UnsupportedSubstrate();
        if (target.code.length == 0) revert TargetIsNotAContract();
    }
}
