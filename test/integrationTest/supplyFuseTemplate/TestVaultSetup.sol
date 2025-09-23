// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TestStorage} from "./TestStorage.sol";
import {PlasmaVault, MarketSubstratesConfig, FeeConfig, MarketBalanceFuseConfig, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

abstract contract TestVaultSetup is TestStorage {
    function initPlasmaVault() public {
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = setupMarketConfigs();
        MarketBalanceFuseConfig[] memory balanceFuses = setupBalanceFuses();
        FeeConfig memory feeConfig = setupFeeConfig();

        createAccessManager();

        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vm.startPrank(accounts[0]);
        plasmaVault = address(new PlasmaVault());
        PlasmaVault(plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "TPLASMA",
                asset,
                priceOracle,
                feeConfig,
                accessManager,
                address(new PlasmaVaultBase()),
                withdrawManager
            )
        );
        vm.stopPrank();

        // Set up roles first
        setupRoles(withdrawManager);

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            accounts[0],
            address(plasmaVault),
            fuses,
            balanceFuses,
            marketConfigs
        );
    }

    function initPlasmaVaultCustom(
        MarketSubstratesConfig[] memory marketConfigs,
        MarketBalanceFuseConfig[] memory balanceFuses
    ) public {
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;

        FeeConfig memory feeConfig = setupFeeConfig();

        createAccessManager();

        address withdrawManager = address(new WithdrawManager(address(accessManager)));
        vm.startPrank(accounts[0]);
        plasmaVault = address(new PlasmaVault());
        PlasmaVault(plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "TPLASMA",
                asset,
                priceOracle,
                feeConfig,
                accessManager,
                address(new PlasmaVaultBase()),
                withdrawManager
            )
        );

        vm.stopPrank();

        setupRoles(withdrawManager);

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            accounts[0],
            address(plasmaVault),
            fuses,
            balanceFuses,
            marketConfigs
        );
    }

    /// @dev Setup default  fee configuration for the PlasmaVault
    function setupFeeConfig() public virtual returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function createAccessManager() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = accounts[0];
        usersToRoles.atomist = accounts[0];
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
    }

    function setupRoles(address withdrawManager) private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = accounts[0];
        usersToRoles.atomist = accounts[0];
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            plasmaVault,
            IporFusionAccessManager(accessManager),
            withdrawManager
        );
    }

    function setupMarketConfigs() public virtual returns (MarketSubstratesConfig[] memory marketConfigs);

    function setupFuses() public virtual;

    function setupBalanceFuses() public virtual returns (MarketBalanceFuseConfig[] memory balanceFuses);

    function getEnterFuseData(
        uint256 amount_,
        bytes32[] memory data_
    ) public view virtual returns (bytes[] memory data);

    function getExitFuseData(
        uint256 amount_,
        bytes32[] memory data_
    ) public view virtual returns (address[] memory fusesSetup, bytes[] memory data);
}
