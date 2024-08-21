// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Erc4626SupplyFuse} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "./../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";

contract VaultERC4626Mock {
    using Address for address;

    Erc4626SupplyFuse public fuse;
    ERC4626BalanceFuse public balanceFuse;

    constructor(address fuseInput, address balanceFuseInput) {
        fuse = Erc4626SupplyFuse(fuseInput);
        balanceFuse = ERC4626BalanceFuse(balanceFuseInput);
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

    //solhint-disable-next-line
    function balanceOf(address plasmaVault) external returns (uint256) {
        return abi.decode(address(balanceFuse).functionDelegateCall(msg.data), (uint256));
    }
}
