// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract CompoundV3SupplyFuseMock {
    using Address for address;

    CompoundV3SupplyFuse public fuse;

    constructor(address fuseInput) {
        fuse = CompoundV3SupplyFuse(fuseInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        CompoundV3SupplyFuseEnterData memory data
    ) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        CompoundV3SupplyFuseExitData memory data
    ) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        PlasmaVaultConfigLib.grandSubstratesAsAssetsToMarket(marketId, assets);
    }
}
