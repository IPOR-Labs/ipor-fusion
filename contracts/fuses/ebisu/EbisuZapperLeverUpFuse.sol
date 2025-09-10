// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {EbisuMathLibrary} from "./EbisuMathLibrary.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";

/// @notice Data for lever-up action
struct EbisuLeverUpData {
    address zapper;
    address wethEthAdapter;
    uint256 flashLoanAmount;
    uint256 ebusdAmount;     // BOLD/EBUSD to add as debt
    uint256 maxUpfrontFee;   // safety bound for zapper
}

contract EbisuZapperLeverUpFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();
    error TargetIsNotAContract();

    event EbisuZapperFuseLeverUp(address zapper, uint256 ownerIndex, uint256 flashLoanAmount, uint256 ebusdAmount);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function execute(EbisuLeverUpData memory data) external {
        _requireWhitelistedContract(MARKET_ID, data.zapper);

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();
        uint256 troveId = troveData.troveIds[data.zapper];

        ILeverageZapper.LeverUpTroveParams memory params = ILeverageZapper.LeverUpTroveParams({
            troveId: troveId,
            flashLoanAmount: data.flashLoanAmount,
            boldAmount: data.ebusdAmount,
            maxUpfrontFee: data.maxUpfrontFee
        });

        ILeverageZapper(data.zapper).leverUpTrove(params);

        emit EbisuZapperFuseLeverUp(data.zapper, troveData.latestOwnerId, data.flashLoanAmount, data.ebusdAmount);
    }

    // --- internals ---

    function _requireWhitelistedContract(uint256 marketId, address target) internal view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(marketId, target)) revert UnsupportedSubstrate();
        // native solidity check instead of OZ Address.isContract
        if (target.code.length == 0) revert TargetIsNotAContract();
    }
}
