// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AaveV2SupplyFuse, AaveV2SupplyFuseEnterData, AaveV2SupplyFuseExitData} from "../../../contracts/fuses/aave_v2/AaveV2SupplyFuse.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract AaveV2SupplyFuseMock {
    using Address for address;

    AaveV2SupplyFuse public fuse;

    constructor(address fuseInput) {
        fuse = AaveV2SupplyFuse(fuseInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        AaveV2SupplyFuseEnterData memory data
    ) external returns (bytes memory executionStatus) {
        address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        AaveV2SupplyFuseExitData memory data
    ) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        MarketConfigurationLib.grandSubstratesAsAssetsToMarket(marketId, assets);
    }
}