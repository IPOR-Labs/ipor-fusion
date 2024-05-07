// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {TestStorage} from "./TestStorage.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";

abstract contract TestVaultSetup is TestStorage {
    function initPlasmaVault() public {
        address owner = getOwner();
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = setupMarketConfigs();
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = setupBalanceFuses();

        plasmaVault = address(
            new PlasmaVault(
                owner,
                "TEST PLASMA VAULT",
                "TPLASMA",
                asset,
                priceOracle,
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                feeManager,
                0
            )
        );
    }

    function setupMarketConfigs() public virtual returns (PlasmaVault.MarketSubstratesConfig[] memory marketConfigs);

    function setupFuses() public virtual;

    function setupBalanceFuses() public virtual returns (PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses);

    function getEnterFuseData(uint256 amount_, bytes32[] memory data_) public view virtual returns (bytes memory data);

    function getExitFuseData(uint256 amount_, bytes32[] memory data_) public view virtual returns (bytes memory data);
}
