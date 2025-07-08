// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultHelper} from "./PlasmaVaultHelper.sol";
import {Vm} from "forge-std/Vm.sol";
import {MoonwellSupplyFuse} from "../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {MoonwellBalanceFuse} from "../../contracts/fuses/moonwell/MoonwellBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {TestAddresses} from "./TestAddresses.sol";
import {MoonwellEnableMarketFuse} from "../../contracts/fuses/moonwell/MoonwellEnableMarketFuse.sol";
import {MoonwellBorrowFuse} from "../../contracts/fuses/moonwell/MoonwellBorrowFuse.sol";
import {MErc20} from "../../contracts/fuses/moonwell/ext/MErc20.sol";

struct MoonWellAddresses {
    address suppluFuse;
    address balanceFuse;
    address enableMarketFuse;
    address borrowFuse;
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

        vm_.startPrank(TestAddresses.FUSE_MANAGER);
        _addSubstratesToMarket(plasmaVault_, mTokens);
        vm_.stopPrank();

        vm_.startPrank(TestAddresses.FUSE_MANAGER);
        moonwellAddresses.suppluFuse = _addSupplyFuse(plasmaVault_);
        moonwellAddresses.balanceFuse = _addBalanceFuse(plasmaVault_);
        vm_.stopPrank();

        return moonwellAddresses;
    }

    function addFullMarket(
        PlasmaVault plasmaVault_,
        address[] memory mTokens_,
        address comptroller_,
        Vm vm_
    ) internal returns (MoonWellAddresses memory moonwellAddresses) {
        vm_.startPrank(TestAddresses.FUSE_MANAGER);
        _addSubstratesToMarket(plasmaVault_, mTokens_);
        _addSubstratesToBalanceERC20Fuse(plasmaVault_, mTokens_);
        _addDependencyGraph(plasmaVault_);
        vm_.stopPrank();

        vm_.startPrank(TestAddresses.FUSE_MANAGER);
        moonwellAddresses.suppluFuse = _addSupplyFuse(plasmaVault_);
        moonwellAddresses.balanceFuse = _addBalanceFuse(plasmaVault_);
        moonwellAddresses.enableMarketFuse = _addEnableMarketFuse(plasmaVault_, comptroller_);
        moonwellAddresses.borrowFuse = _addBorrowFuse(plasmaVault_);
        vm_.stopPrank();
    }

    function _addEnableMarketFuse(
        PlasmaVault plasmaVault_,
        address comptroller_
    ) private returns (address enableMarketFuseAddress) {
        MoonwellEnableMarketFuse moonwellEnableMarketFuse = new MoonwellEnableMarketFuse(
            IporFusionMarkets.MOONWELL,
            comptroller_
        );
        address[] memory fuses = new address[](1);
        fuses[0] = address(moonwellEnableMarketFuse);
        plasmaVault_.addFusesToVault(fuses);

        return fuses[0];
    }

    function _addBorrowFuse(PlasmaVault plasmaVault_) private returns (address borrowFuse) {
        MoonwellBorrowFuse moonwellBorrowFuse = new MoonwellBorrowFuse(IporFusionMarkets.MOONWELL);
        address[] memory fuses = new address[](1);
        fuses[0] = address(moonwellBorrowFuse);
        plasmaVault_.addFusesToVault(fuses);

        return fuses[0];
    }

    function _addSubstratesToMarket(PlasmaVault plasmaVault_, address[] memory mTokens) private {
        // Convert mToken addresses to bytes32 format
        bytes32[] memory substrates = new bytes32[](mTokens.length);
        for (uint256 i = 0; i < mTokens.length; i++) {
            substrates[i] = bytes32(uint256(uint160(mTokens[i])));
        }

        plasmaVault_.addSubstratesToMarket(IporFusionMarkets.MOONWELL, substrates);
    }

    function _addSupplyFuse(PlasmaVault plasmaVault_) private returns (address suppluFuse) {
        MoonwellSupplyFuse moonwellSupplyFuse = new MoonwellSupplyFuse(IporFusionMarkets.MOONWELL);

        address[] memory fuses = new address[](1);
        fuses[0] = address(moonwellSupplyFuse);
        plasmaVault_.addFusesToVault(fuses);

        return address(moonwellSupplyFuse);
    }

    function _addBalanceFuse(PlasmaVault plasmaVault_) private returns (address balanceFuse) {
        // Deploy both balance fuses
        MoonwellBalanceFuse moonwellBalanceFuse = new MoonwellBalanceFuse(IporFusionMarkets.MOONWELL);
        ERC20BalanceFuse erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        // Add both balance fuses to the vault
        plasmaVault_.addBalanceFusesToVault(IporFusionMarkets.MOONWELL, address(moonwellBalanceFuse));
        plasmaVault_.addBalanceFusesToVault(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));

        // Return the Moonwell balance fuse address for consistency with existing code
        return address(moonwellBalanceFuse);
    }

    function _addDependencyGraph(PlasmaVault plasmaVault_) private {
        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        plasmaVault_.addDependencyBalanceGraphs(IporFusionMarkets.MOONWELL, dependencies);
    }

    function _addSubstratesToBalanceERC20Fuse(PlasmaVault plasmaVault_, address[] memory mTokens) private {
        // Convert underlying asset addresses to bytes32 format
        bytes32[] memory substrates = new bytes32[](mTokens.length);

        for (uint256 i; i < mTokens.length; i++) {
            // Get underlying asset from mToken
            address underlyingAsset = MErc20(mTokens[i]).underlying();
            substrates[i] = bytes32(uint256(uint160(underlyingAsset)));
        }

        // Add substrates (underlying assets) to ERC20_VAULT_BALANCE market
        plasmaVault_.addSubstratesToMarket(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);
    }
}
