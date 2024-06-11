// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@fusion/@openzeppelin/contracts/utils/Address.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract ERC4626SupplyFuseMock {
    using Address for address;

    Erc4626SupplyFuse public fuse;

    constructor(address fuseInput) {
        fuse = Erc4626SupplyFuse(fuseInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        Erc4626SupplyFuseEnterData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        Erc4626SupplyFuseExitData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        PlasmaVaultConfigLib.grandSubstratesAsAssetsToMarket(marketId, assets);
    }
}
