// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

/// @title Fork Integration Tests for DAO Fee Packages
/// @notice Tests DAO fee packages functionality on Ethereum mainnet fork
/// @dev Deploys fresh FusionFactory with DAO fee packages support to test against real mainnet state
contract FusionFactoryDaoFeePackagesForkTest is Test {
    // Ethereum mainnet addresses - used for reference/copying configuration
    address public constant EXISTING_FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDC_HOLDER = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    // Fork block number (recent Ethereum mainnet block where FusionFactory exists)
    uint256 public constant FORK_BLOCK = 23831825;

    FusionFactory public fusionFactory;
    FusionFactory public existingFactory;
    address public owner;
    address public daoFeeManager;
    address public atomist;

    function setUp() public {
        // Create Ethereum mainnet fork
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        // Setup test accounts
        owner = makeAddr("owner");
        daoFeeManager = makeAddr("daoFeeManager");
        atomist = makeAddr("atomist");

        // Get existing factory to copy configuration
        existingFactory = FusionFactory(EXISTING_FUSION_FACTORY_PROXY);

        // Get configuration from existing factory
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = existingFactory.getFactoryAddresses();

        // Deploy new PlasmaVaultFactory and FeeManagerFactory - the existing ones on fork
        // don't support the new PlasmaVaultInitData structure with plasmaVaultVotesPlugin
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());

        // Deploy new PlasmaVaultBase - the existing one on fork is already initialized
        address plasmaVaultBase = address(new PlasmaVaultBase());
        address priceOracleMiddleware = existingFactory.getPriceOracleMiddleware();
        address burnRequestFeeFuse = existingFactory.getBurnRequestFeeFuseAddress();
        address burnRequestFeeBalanceFuse = existingFactory.getBurnRequestFeeBalanceFuseAddress();
        address[] memory plasmaVaultAdminArray = existingFactory.getPlasmaVaultAdminArray();

        // Deploy fresh FusionFactory with fee packages support
        FusionFactory implementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSelector(
            FusionFactory.initialize.selector,
            owner,
            plasmaVaultAdminArray,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        fusionFactory = FusionFactory(address(proxy));

        // Grant roles first
        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), owner);
        vm.stopPrank();

        // Copy base addresses from existing factory
        _copyBaseAddresses();

        // Copy other configuration from existing factory
        _copyOtherConfiguration();

        // Setup fee packages
        _setupDaoFeePackages();

        // Transfer some USDC to atomist for deposits
        vm.prank(USDC_HOLDER);
        ERC20(USDC).transfer(atomist, 100_000e6);
    }

    function _copyBaseAddresses() internal {
        FusionFactoryStorageLib.BaseAddresses memory existingBases = existingFactory.getBaseAddresses();
        uint256 version = existingFactory.getFusionFactoryVersion();

        // Deploy new PlasmaVault as plasmaVaultCoreBase for cloning
        // The existing one on fork may be incompatible with new PlasmaVaultInitData structure
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
        // Note: plasmaVaultBase is already set in setUp() with a new instance
    }

    function _copyOtherConfiguration() internal {
        // Copy vesting period
        uint256 vestingPeriod = existingFactory.getVestingPeriodInSeconds();
        vm.prank(owner);
        fusionFactory.updateVestingPeriodInSeconds(vestingPeriod);

        // Copy withdraw window
        uint256 withdrawWindow = existingFactory.getWithdrawWindowInSeconds();
        vm.prank(owner);
        fusionFactory.updateWithdrawWindowInSeconds(withdrawWindow);
    }

    function _setupDaoFeePackages() internal {
        // Create fee packages with different configurations
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](3);

        // Package 0: Standard fees (2% management, 20% performance)
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 200, // 2%
            performanceFee: 2000, // 20%
            feeRecipient: makeAddr("standardFeeRecipient")
        });

        // Package 1: Low fees (1% management, 10% performance)
        packages[1] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100, // 1%
            performanceFee: 1000, // 10%
            feeRecipient: makeAddr("lowFeeRecipient")
        });

        // Package 2: Premium fees (3% management, 30% performance)
        packages[2] = FusionFactoryStorageLib.FeePackage({
            managementFee: 300, // 3%
            performanceFee: 3000, // 30%
            feeRecipient: makeAddr("premiumFeeRecipient")
        });

        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
    }

    /// @notice Test creating vault with standard fee package (index 0) on Ethereum fork
    function testForkEthereum_CreateVaultWithDaoFeePackageIndex0() public {
        // given
        uint256 redemptionDelay = 1 days;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.create(
            "Fork Test Vault Standard",
            "FTVS",
            USDC,
            redemptionDelay,
            atomist,
            0 // Standard fee package
        );

        // then
        assertTrue(instance.plasmaVault != address(0), "PlasmaVault should be created");
        assertTrue(instance.feeManager != address(0), "FeeManager should be created");

        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 200, "Management fee should be 2%");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 2000, "Performance fee should be 20%");
        assertEq(
            feeManager.getIporDaoFeeRecipientAddress(),
            makeAddr("standardFeeRecipient"),
            "Fee recipient should match"
        );
    }

    /// @notice Test creating vault with low fee package (index 1) on Ethereum fork
    function testForkEthereum_CreateVaultWithDaoFeePackageIndex1() public {
        // given
        uint256 redemptionDelay = 1 days;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.create(
            "Fork Test Vault Low Fees",
            "FTVL",
            USDC,
            redemptionDelay,
            atomist,
            1 // Low fee package
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 100, "Management fee should be 1%");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 1000, "Performance fee should be 10%");
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), makeAddr("lowFeeRecipient"), "Fee recipient should match");
    }

    /// @notice Test cloning vault with fee package on Ethereum fork
    function testForkEthereum_CloneVaultWithDaoFeePackage() public {
        // given
        uint256 redemptionDelay = 1 days;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Fork Test Vault Clone",
            "FTVC",
            USDC,
            redemptionDelay,
            atomist,
            2 // Premium fee package
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 300, "Management fee should be 3%");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 3000, "Performance fee should be 30%");
        assertEq(
            feeManager.getIporDaoFeeRecipientAddress(),
            makeAddr("premiumFeeRecipient"),
            "Fee recipient should match"
        );
    }

    /// @notice Test that fee packages are correctly applied and vault can accept deposits
    function testForkEthereum_VaultWithDaoFeePackageAcceptsDeposits() public {
        // given
        uint256 redemptionDelay = 0; // No delay for simplicity
        uint256 depositAmount = 10_000e6;

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.create(
            "Fork Test Deposit Vault",
            "FTDV",
            USDC,
            redemptionDelay,
            atomist,
            0
        );

        // Grant ATOMIST_ROLE to atomist in the vault's access manager
        // Owner role is automatically granted to atomist (as vault owner), but ATOMIST_ROLE needs separate grant
        vm.startPrank(atomist);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.stopPrank();

        // Make vault public for deposits
        vm.startPrank(atomist);
        PlasmaVaultGovernance(instance.plasmaVault).convertToPublicVault();
        vm.stopPrank();

        // when - deposit
        vm.startPrank(atomist);
        ERC20(USDC).approve(instance.plasmaVault, depositAmount);
        uint256 shares = PlasmaVault(instance.plasmaVault).deposit(depositAmount, atomist);
        vm.stopPrank();

        // then
        assertTrue(shares > 0, "Should receive shares");
        assertEq(
            ERC20(instance.plasmaVault).balanceOf(atomist),
            shares,
            "Atomist should have shares"
        );
    }

    /// @notice Test creating multiple vaults with different fee packages
    function testForkEthereum_CreateMultipleVaultsWithDifferentDaoFeePackages() public {
        // given
        uint256 redemptionDelay = 1 days;

        // when - create vaults with each package
        FusionFactoryLogicLib.FusionInstance memory vault0 = fusionFactory.create(
            "Vault Package 0",
            "VP0",
            USDC,
            redemptionDelay,
            atomist,
            0
        );

        FusionFactoryLogicLib.FusionInstance memory vault1 = fusionFactory.create(
            "Vault Package 1",
            "VP1",
            USDC,
            redemptionDelay,
            atomist,
            1
        );

        FusionFactoryLogicLib.FusionInstance memory vault2 = fusionFactory.create(
            "Vault Package 2",
            "VP2",
            USDC,
            redemptionDelay,
            atomist,
            2
        );

        // then - verify each vault has correct fees
        assertEq(FeeManager(vault0.feeManager).IPOR_DAO_MANAGEMENT_FEE(), 200);
        assertEq(FeeManager(vault0.feeManager).IPOR_DAO_PERFORMANCE_FEE(), 2000);

        assertEq(FeeManager(vault1.feeManager).IPOR_DAO_MANAGEMENT_FEE(), 100);
        assertEq(FeeManager(vault1.feeManager).IPOR_DAO_PERFORMANCE_FEE(), 1000);

        assertEq(FeeManager(vault2.feeManager).IPOR_DAO_MANAGEMENT_FEE(), 300);
        assertEq(FeeManager(vault2.feeManager).IPOR_DAO_PERFORMANCE_FEE(), 3000);

        // Verify all vaults are distinct
        assertTrue(vault0.plasmaVault != vault1.plasmaVault);
        assertTrue(vault1.plasmaVault != vault2.plasmaVault);
        assertTrue(vault0.plasmaVault != vault2.plasmaVault);
    }

    /// @notice Test fee packages query functions work correctly on fork
    function testForkEthereum_QueryDaoFeePackages() public view {
        // when
        FusionFactoryStorageLib.FeePackage[] memory packages = fusionFactory.getDaoFeePackages();
        uint256 length = fusionFactory.getDaoFeePackagesLength();

        // then
        assertEq(length, 3, "Should have 3 packages");
        assertEq(packages.length, 3, "Array should have 3 packages");

        // Verify package 0
        FusionFactoryStorageLib.FeePackage memory pkg0 = fusionFactory.getDaoFeePackage(0);
        assertEq(pkg0.managementFee, 200);
        assertEq(pkg0.performanceFee, 2000);

        // Verify package 1
        FusionFactoryStorageLib.FeePackage memory pkg1 = fusionFactory.getDaoFeePackage(1);
        assertEq(pkg1.managementFee, 100);
        assertEq(pkg1.performanceFee, 1000);

        // Verify package 2
        FusionFactoryStorageLib.FeePackage memory pkg2 = fusionFactory.getDaoFeePackage(2);
        assertEq(pkg2.managementFee, 300);
        assertEq(pkg2.performanceFee, 3000);
    }

    /// @notice Test that invalid fee package index reverts on fork
    function testForkEthereum_RevertOnInvalidDaoFeePackageIndex() public {
        // given
        uint256 redemptionDelay = 1 days;

        // when / then
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.DaoFeePackageIndexOutOfBounds.selector, 10, 3));
        fusionFactory.create("Invalid Package", "INV", USDC, redemptionDelay, atomist, 10);
    }

    /// @notice Test updating fee packages on fork
    function testForkEthereum_UpdateDaoFeePackages() public {
        // given - verify initial state
        assertEq(fusionFactory.getDaoFeePackagesLength(), 3);

        // Create new packages
        FusionFactoryStorageLib.FeePackage[] memory newPackages = new FusionFactoryStorageLib.FeePackage[](2);
        newPackages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 150,
            performanceFee: 1500,
            feeRecipient: makeAddr("newRecipient1")
        });
        newPackages[1] = FusionFactoryStorageLib.FeePackage({
            managementFee: 250,
            performanceFee: 2500,
            feeRecipient: makeAddr("newRecipient2")
        });

        // when
        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(newPackages);

        // then
        assertEq(fusionFactory.getDaoFeePackagesLength(), 2, "Should have 2 packages after update");

        FusionFactoryStorageLib.FeePackage memory pkg0 = fusionFactory.getDaoFeePackage(0);
        assertEq(pkg0.managementFee, 150);
        assertEq(pkg0.performanceFee, 1500);

        FusionFactoryStorageLib.FeePackage memory pkg1 = fusionFactory.getDaoFeePackage(1);
        assertEq(pkg1.managementFee, 250);
        assertEq(pkg1.performanceFee, 2500);
    }
}
