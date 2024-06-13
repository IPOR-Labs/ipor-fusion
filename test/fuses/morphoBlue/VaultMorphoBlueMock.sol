// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {MorphoBlueSupplyFuse, MorphoBlueSupplyFuseExitData, MorphoBlueSupplyFuseEnterData} from "../../../contracts/fuses/morphoBlue/MorphoBlueSupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract VaultMorphoBlueMock {
    using Address for address;

    MorphoBlueSupplyFuse public fuse;
    address public morphoBalanceFuse;

    constructor(address fuseInput, address morphoBalanceFuseInput) {
        fuse = MorphoBlueSupplyFuse(fuseInput);
        morphoBalanceFuse = morphoBalanceFuseInput;
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        MorphoBlueSupplyFuseEnterData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        MorphoBlueSupplyFuseExitData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function grandMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external {
        PlasmaVaultConfigLib.grandMarketSubstrates(marketId, substrates);
    }

    //solhint-disable-next-line
    function balanceOf(address plasmaVault) external returns (uint256) {
        return abi.decode(morphoBalanceFuse.functionDelegateCall(msg.data), (uint256));
    }
}
