// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {MorphoBlueSupplyFuse} from "../../../contracts/fuses/morphoBlue/MorphoBlueSupplyFuse.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract VaultMorphoBlueMock {
    using Address for address;

    MorphoBlueSupplyFuse public fuse;

    constructor(address fuseInput) {
        fuse = MorphoBlueSupplyFuse(fuseInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        MorphoBlueSupplyFuse.MorphoBlueSupplyFuseData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        MorphoBlueSupplyFuse.MorphoBlueSupplyFuseData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, bytes32[] calldata substrates) external {
        MarketConfigurationLib.grandSubstratesToMarket(marketId, substrates);
    }
}
