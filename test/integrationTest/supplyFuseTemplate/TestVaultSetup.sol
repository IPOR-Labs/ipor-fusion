// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {TestStorage} from "./TestStorage.sol";
import {PlasmaVault, MarketSubstratesConfig, FeeConfig, MarketBalanceFuseConfig, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultAccessManager} from "../../../contracts/managers/PlasmaVaultAccessManager.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

abstract contract TestVaultSetup is TestStorage {
    function initPlasmaVault() public {
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = setupMarketConfigs();
        MarketBalanceFuseConfig[] memory balanceFuses = setupBalanceFuses();
        FeeConfig memory feeConfig = setupFeeConfig();

        createAccessManager();
        plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "TPLASMA",
                    asset,
                    priceOracle,
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    feeConfig,
                    accessManager
                )
            )
        );

        setupRoles();
    }

    /// @dev Setup default  fee configuration for the PlasmaVault
    function setupFeeConfig() public view virtual returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig({
            performanceFeeManager: address(this),
            performanceFeeInPercentage: 0,
            managementFeeManager: address(this),
            managementFeeInPercentage: 0
        });
    }

    function createAccessManager() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = accounts[0];
        usersToRoles.atomist = accounts[0];
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = address(RoleLib.createAccessManager(usersToRoles, vm));
    }

    function setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = accounts[0];
        usersToRoles.atomist = accounts[0];
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, plasmaVault, PlasmaVaultAccessManager(accessManager));
    }

    function setupMarketConfigs() public virtual returns (MarketSubstratesConfig[] memory marketConfigs);

    function setupFuses() public virtual;

    function setupBalanceFuses() public virtual returns (MarketBalanceFuseConfig[] memory balanceFuses);

    function getEnterFuseData(uint256 amount_, bytes32[] memory data_) public view virtual returns (bytes memory data);

    function getExitFuseData(uint256 amount_, bytes32[] memory data_) public view virtual returns (bytes memory data);
}
