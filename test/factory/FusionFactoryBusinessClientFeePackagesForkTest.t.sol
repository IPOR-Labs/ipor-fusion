// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";

/// @title Fork Integration Tests for Business Client Fee Packages
/// @notice Tests business client fee packages on Ethereum mainnet fork
contract FusionFactoryBusinessClientFeePackagesForkTest is Test {
    address public constant EXISTING_FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDC_HOLDER = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    uint256 public constant FORK_BLOCK = 23831825;

    FusionFactory public fusionFactory;
    FusionFactory public existingFactory;
    address public owner;
    address public daoFeeManager;
    address public atomist;
    address public businessClient;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        owner = makeAddr("owner");
        daoFeeManager = makeAddr("daoFeeManager");
        atomist = makeAddr("atomist");
        businessClient = makeAddr("businessClient");

        existingFactory = FusionFactory(EXISTING_FUSION_FACTORY_PROXY);

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = existingFactory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());

        address plasmaVaultBase = address(new PlasmaVaultBase());
        address priceOracleMiddleware = existingFactory.getPriceOracleMiddleware();
        address burnRequestFeeFuse = existingFactory.getBurnRequestFeeFuseAddress();
        address burnRequestFeeBalanceFuse = existingFactory.getBurnRequestFeeBalanceFuseAddress();
        FusionFactory implementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSelector(
            FusionFactory.initialize.selector,
            owner,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        fusionFactory = FusionFactory(address(proxy));

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), owner);
        vm.stopPrank();

        _copyBaseAddresses();
        _copyOtherConfiguration();
        _setupDaoFeePackages();
        _setupBusinessClientFeePackages();

        vm.prank(USDC_HOLDER);
        ERC20(USDC).transfer(businessClient, 100_000e6);
    }

    function _copyBaseAddresses() internal {
        FusionFactoryStorageLib.BaseAddresses memory existingBases = existingFactory.getBaseAddresses();
        uint256 version = existingFactory.getFusionFactoryVersion();
        address newPlasmaVaultCoreBase = address(new PlasmaVault());

        vm.prank(owner);
        fusionFactory.updateBaseAddresses(
            version,
            newPlasmaVaultCoreBase,
            existingBases.accessManagerBase,
            existingBases.priceManagerBase,
            existingBases.withdrawManagerBase,
            existingBases.rewardsManagerBase,
            existingBases.contextManagerBase
        );
    }

    function _copyOtherConfiguration() internal {
        uint256 vestingPeriod = existingFactory.getVestingPeriodInSeconds();
        vm.prank(owner);
        fusionFactory.updateVestingPeriodInSeconds(vestingPeriod);

        uint256 withdrawWindow = existingFactory.getWithdrawWindowInSeconds();
        vm.prank(owner);
        fusionFactory.updateWithdrawWindowInSeconds(withdrawWindow);
    }

    function _setupDaoFeePackages() internal {
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 200,
            performanceFee: 2000,
            feeRecipient: makeAddr("globalFeeRecipient")
        });
        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
    }

    function _setupBusinessClientFeePackages() internal {
        FusionFactoryStorageLib.FeePackage[] memory clientPackages = new FusionFactoryStorageLib.FeePackage[](1);
        clientPackages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 50,
            performanceFee: 500,
            feeRecipient: makeAddr("clientFeeRecipient")
        });
        vm.prank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(businessClient, clientPackages);
    }

    /// @notice Test that business client gets custom fees when cloning vault on Ethereum fork
    function test_fork_businessClientClone_shouldCreateVaultWithCustomFees() public {
        // given
        uint256 redemptionDelay = 1 days;

        // when
        vm.prank(businessClient);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Business Client Vault",
            "BCV",
            USDC,
            redemptionDelay,
            atomist,
            0
        );

        // then
        assertTrue(instance.plasmaVault != address(0), "PlasmaVault should be created");
        assertTrue(instance.feeManager != address(0), "FeeManager should be created");

        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 50, "Management fee should be 0.5% (custom)");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 500, "Performance fee should be 5% (custom)");
    }

    /// @notice Test that business client fee recipient is correctly set on vault cloned on fork
    function test_fork_businessClientClone_shouldHaveCorrectFeeRecipient() public {
        // given
        uint256 redemptionDelay = 1 days;

        // when
        vm.prank(businessClient);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Business Client Vault",
            "BCV",
            USDC,
            redemptionDelay,
            atomist,
            0
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(
            feeManager.getIporDaoFeeRecipientAddress(),
            makeAddr("clientFeeRecipient"),
            "Fee recipient should match business client's configured recipient"
        );
    }
}
