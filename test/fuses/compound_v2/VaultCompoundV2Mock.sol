// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {CompoundV2SupplyFuse, CompoundV2SupplyFuseEnterData, CompoundV2SupplyFuseExitData} from "../../../contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract VaultCompoundV2Mock {
    using Address for address;

    CompoundV2SupplyFuse public fuse;
    address public balanceFuse;

    constructor(address fuseInput, address balanceFuseInput) {
        fuse = CompoundV2SupplyFuse(fuseInput);
        balanceFuse = balanceFuseInput;
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        CompoundV2SupplyFuseEnterData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        CompoundV2SupplyFuseExitData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function balanceOf(address plazmaVault) external returns (uint256) {
        return abi.decode(balanceFuse.functionDelegateCall(msg.data), (uint256));
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        MarketConfigurationLib.grandSubstratesAsAssetsToMarket(marketId, assets);
    }
}