// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AaveV3SupplyFuse} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract AaveV3SupplyFuseMock {
    using Address for address;

    AaveV3SupplyFuse public fuse;

    constructor(address fuseInput) {
        fuse = AaveV3SupplyFuse(fuseInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        AaveV3SupplyFuse.AaveV3SupplyFuseEnterData memory data
    ) external returns (bytes memory executionStatus) {
        address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        AaveV3SupplyFuse.AaveV3SupplyFuseExitData memory data
    ) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        MarketConfigurationLib.grandSubstratesAsAssetsToMarket(marketId, assets);
    }
}