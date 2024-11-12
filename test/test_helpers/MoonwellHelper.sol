// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultHelper} from "./PlasmaVaultHelper.sol";
import {Vm} from "forge-std/Vm.sol";
import {MoonwellSupplyFuse} from "../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {MoonwellBalanceFuse} from "../../contracts/fuses/moonwell/MoonwellBalanceFuse.sol";
import {TestAddresses} from "./TestAddresses.sol";
struct MoonWellAddresses {
    address suppluFuse;
    address balanceFuse;
}

/// @title MoonwellHelper
/// @notice Helper library for setting up Moonwell markets in PlasmaVault
/// @dev Contains utility functions to assist with Moonwell market configuration
library MoonwellHelper {
    using PlasmaVaultHelper for PlasmaVault;

    function addSupplyToMarket(
        PlasmaVault plasmaVault_,
        address[] memory mTokens,
        Vm vm_
    ) internal returns (MoonWellAddresses memory moonwellAddresses) {
        MoonWellAddresses memory moonwellAddresses;

        vm_.startPrank(TestAddresses.ATOMIST);
        _addSubstratesToMarket(plasmaVault_, mTokens);
        vm_.stopPrank();

        vm_.startPrank(TestAddresses.FUSE_MANAGER);
        moonwellAddresses.suppluFuse = _addSupplyFuse(plasmaVault_);
        moonwellAddresses.balanceFuse = _addBalanceFuse(plasmaVault_);
        vm_.stopPrank();

        return moonwellAddresses;
    }

    function _addSubstratesToMarket(PlasmaVault plasmaVault_, address[] memory mTokens) private {
        // Convert mToken addresses to bytes32 format
        bytes32[] memory substrates = new bytes32[](mTokens.length);
        for (uint256 i = 0; i < mTokens.length; i++) {
            substrates[i] = bytes32(uint256(uint160(mTokens[i])));
        }

        plasmaVault_.addSubstratesToMarket(IporFusionMarkets.MOONWELL, substrates);
    }

    function _addSupplyFuse(
        PlasmaVault plasmaVault_,
    ) private returns (address suppluFuse) {
        MoonwellSupplyFuse moonwellSupplyFuse = new MoonwellSupplyFuse(IporFusionMarkets.MOONWELL);

        address[] memory fuses = new address[](1);
        fuses[0] = address(moonwellSupplyFuse);
        plasmaVault_.addFusesToVault(fuses);

        return address(moonwellSupplyFuse);
    }

    function _addBalanceFuse(PlasmaVault plasmaVault_) private returns (address balanceFuse) {
        MoonwellBalanceFuse moonwellBalanceFuse = new MoonwellBalanceFuse(IporFusionMarkets.MOONWELL);

        plasmaVault_.addBalanceFusesToVault(IporFusionMarkets.MOONWELL, address(moonwellBalanceFuse));

        return address(moonwellBalanceFuse);
    }
}
