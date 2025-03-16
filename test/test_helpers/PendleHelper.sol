// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultHelper} from "./PlasmaVaultHelper.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestAddresses} from "./TestAddresses.sol";

import {PendleSwapPTFuse} from "../../contracts/fuses/pendle/PendleSwapPTFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {PtPriceFeed} from "../../contracts/price_oracle/price_feed/PtPriceFeed.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC20BalanceFuse} from "../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

struct PendleAddresses {
    address swapPTFuse;
    address marketsBalanceFuse;
}

/// @title PendleHelper
/// @notice Helper library for Pendle markets in PlasmaVault
/// @dev Contains utility functions to assist with Pendle market configuration
library PendleHelper {
    using PlasmaVaultHelper for PlasmaVault;

    function addFullMarket(
        PlasmaVault plasmaVault_,
        address[] memory markets_,
        uint256[] memory usePendleOracleMethod,
        Vm vm_
    ) internal returns (PendleAddresses memory pendleAddresses) {
        vm_.startPrank(TestAddresses.ATOMIST);
        _addSubstratesToMarket(plasmaVault_, markets_);
        _addDependencyGraph(plasmaVault_);
        vm_.stopPrank();

        address oracleOwner = PriceOracleMiddleware(plasmaVault_.priceOracleMiddlewareOf()).owner();

        vm_.startPrank(oracleOwner);
        for (uint256 i; i < markets_.length; i++) {
            _addPtPriceFeed(plasmaVault_, markets_[i], usePendleOracleMethod[i]);
        }
        vm_.stopPrank();

        vm_.startPrank(TestAddresses.FUSE_MANAGER);
        pendleAddresses.swapPTFuse = _addSwapPTFuse(plasmaVault_);
        vm_.stopPrank();

        vm_.startPrank(TestAddresses.FUSE_MANAGER);
        pendleAddresses.marketsBalanceFuse = _addBalanceFuse(plasmaVault_);
        vm_.stopPrank();

        return pendleAddresses;
    }

    function _addPtPriceFeed(PlasmaVault plasmaVault_, address market, uint256 usePendleOracleMethod) internal {
        address priceOracle = plasmaVault_.priceOracleMiddlewareOf();
        (, IPPrincipalToken pt, ) = IPMarket(market).readTokens();

        address ptPriceFeed = createPtPriceFeed(
            TestAddresses.ARBITRUM_PENDLE_ORACLE,
            address(market),
            priceOracle,
            usePendleOracleMethod
        );
        address[] memory assets = new address[](2);
        assets[0] = address(pt);
        assets[1] = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84; // stEth address on etherium (came from pendel market configuration)
        address[] memory sources = new address[](2);
        sources[0] = ptPriceFeed; // address of
        sources[1] = 0x07C5b924399cc23c24a95c8743DE4006a32b7f2a; // price feed of stEth on arbitrum

        PriceOracleMiddleware(priceOracle).setAssetsPricesSources(assets, sources);
    }

    function createPtPriceFeed(
        address _pendleOracle,
        address _pendleMarket,
        address _priceMiddleware,
        uint256 _usePendleOracleMethod
    ) internal returns (address ptPriceFeed) {
        ptPriceFeed = address(
            new PtPriceFeed(_pendleOracle, _pendleMarket, 5 minutes, _priceMiddleware, _usePendleOracleMethod)
        );
    }

    function _addSubstratesToMarket(PlasmaVault plasmaVault_, address[] memory markets_) private {
        // Convert mToken addresses to bytes32 format
        bytes32[] memory substrates = new bytes32[](markets_.length);
        bytes32[] memory erc20Substrates = new bytes32[](markets_.length);
        for (uint256 i = 0; i < markets_.length; i++) {
            substrates[i] = bytes32(uint256(uint160(markets_[i])));
            (, IPPrincipalToken pt, ) = IPMarket(markets_[i]).readTokens();
            erc20Substrates[i] = bytes32(uint256(uint160(address(pt))));
        }

        plasmaVault_.addSubstratesToMarket(IporFusionMarkets.PENDLE, substrates);
        plasmaVault_.addSubstratesToMarket(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Substrates);
    }

    function _addSwapPTFuse(PlasmaVault plasmaVault_) private returns (address swapPTFuse) {
        PendleSwapPTFuse pendleSwapPTFuse = new PendleSwapPTFuse(
            IporFusionMarkets.PENDLE,
            TestAddresses.ARBITRUM_PENDLE_ROUTER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(pendleSwapPTFuse);
        plasmaVault_.addFusesToVault(fuses);

        return fuses[0];
    }

    function _addBalanceFuse(PlasmaVault plasmaVault_) private returns (address marketsBalanceFuse) {
        ZeroBalanceFuse zeroBalanceFuse = new ZeroBalanceFuse(IporFusionMarkets.PENDLE);
        plasmaVault_.addBalanceFusesToVault(IporFusionMarkets.PENDLE, address(zeroBalanceFuse));

        ERC20BalanceFuse erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        plasmaVault_.addBalanceFusesToVault(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));

        return address(zeroBalanceFuse);
    }

    function _addDependencyGraph(PlasmaVault plasmaVault_) private {
        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        plasmaVault_.addDependencyBalanceGraphs(IporFusionMarkets.PENDLE, dependencies);
    }
}
