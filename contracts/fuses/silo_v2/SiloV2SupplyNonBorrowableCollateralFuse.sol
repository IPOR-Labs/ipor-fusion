// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ISilo} from "./ext/ISilo.sol";
import {SiloV2SupplyCollateralFuseAbstract, SiloV2SupplyCollateralFuseEnterData, SiloV2SupplyCollateralFuseExitData} from "./SiloV2SupplyCollateralFuseAbstract.sol";

contract SiloV2SupplyNonBorrowableCollateralFuse is SiloV2SupplyCollateralFuseAbstract {
    constructor(uint256 marketId_) SiloV2SupplyCollateralFuseAbstract(marketId_) {}

    function enter(SiloV2SupplyCollateralFuseEnterData memory data_) external {
        _enter(ISilo.CollateralType.Protected, data_);
    }

    function exit(SiloV2SupplyCollateralFuseExitData calldata data_) external {
        _exit(ISilo.CollateralType.Protected, data_);
    }
}
