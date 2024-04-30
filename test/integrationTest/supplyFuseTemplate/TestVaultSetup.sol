// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TestBase} from "forge-std/Base.sol";
import {console2} from "forge-std/Test.sol";
import {TestStorage} from "./TestStorage.sol";
import {PlazmaVault} from "../../../contracts/vaults/PlazmaVault.sol";

abstract contract TestVaultSetup is TestStorage {
    function initPlasmaVault() public {
        console2.log("initPlasmaVault");
        address owner = getOwner();
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = setupMarketConfigs();
        address[] memory fuses = setupFuses();
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = setupBalanceFuses();

        plasmaVault = address(
            new PlazmaVault(
                owner,
                "TEST PLASMA VAULT",
                "TPLASMA",
                asset,
                priceOracle,
                alphas,
                marketConfigs,
                fuses,
                balanceFuses
            )
        );
    }

    function setupMarketConfigs() public virtual returns (PlazmaVault.MarketSubstratesConfig[] memory marketConfigs);

    function setupFuses() public virtual returns (address[] memory fuses);

    function setupBalanceFuses() public virtual returns (PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses);
}
