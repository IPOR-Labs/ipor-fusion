// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {FusionFactory} from "contracts/factory/FusionFactory.sol";
import {FusionFactoryStorageLib} from "contracts/factory/lib/FusionFactoryStorageLib.sol";
import {FusionFactoryLib} from "contracts/factory/lib/FusionFactoryLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Target contract: contracts/factory/FusionFactory.sol

contract FusionFactoryTest is OlympixUnitTest("FusionFactory") {
    FusionFactory public impl;
    FusionFactory public factory;
    address internal admin = address(0xAD11);

    function setUp() public override {
        impl = new FusionFactory();

        address[] memory plasmaAdmins = new address[](1);
        plasmaAdmins[0] = admin;

        FusionFactoryStorageLib.FactoryAddresses memory addrs = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(0x1),
            plasmaVaultFactory: address(0x2),
            feeManagerFactory: address(0x3),
            withdrawManagerFactory: address(0x4),
            rewardsManagerFactory: address(0x5),
            contextManagerFactory: address(0x6),
            priceManagerFactory: address(0x7)
        });

        bytes memory initData = abi.encodeWithSelector(
            impl.initialize.selector,
            admin,
            plasmaAdmins,
            addrs,
            address(0x100), // plasmaVaultBase
            address(0x101), // priceOracleMiddleware
            address(0x102), // burnRequestFeeFuse
            address(0x103) // burnRequestFeeBalanceFuse
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        factory = FusionFactory(address(proxy));
    }

    function test_example_implIsDisabled() public {
        FusionFactory rawImpl = new FusionFactory();
        address[] memory none = new address[](0);
        FusionFactoryStorageLib.FactoryAddresses memory addrs;
        vm.expectRevert();
        rawImpl.initialize(admin, none, addrs, address(0), address(0), address(0), address(0));
    }

    function test_example_deployment_doesNotRevert() public view {
        assertTrue(address(factory) != address(0));
    }

    function test_example_initialFactoryVersionIsZero() public view {
        assertEq(factory.getFusionFactoryVersion(), 0);
    }

    function test_example_initialFactoryIndexIsZero() public view {
        assertEq(factory.getFusionFactoryIndex(), 0);
    }

    function test_example_initializeRevertsOnZeroAdmin() public {
        FusionFactory freshImpl = new FusionFactory();
        address[] memory none = new address[](0);
        FusionFactoryStorageLib.FactoryAddresses memory addrs;
        bytes memory initData = abi.encodeWithSelector(
            freshImpl.initialize.selector,
            address(0),
            none,
            addrs,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        new ERC1967Proxy(address(freshImpl), initData);
    }

    function test_example_cannotReinitialize() public {
        address[] memory none = new address[](0);
        FusionFactoryStorageLib.FactoryAddresses memory addrs;
        vm.expectRevert();
        factory.initialize(admin, none, addrs, address(0), address(0), address(0), address(0));
    }

    function test_example_adminHasDefaultAdminRole() public view {
        assertTrue(factory.hasRole(0x00, admin));
    }

    function test_example_getFactoryAddresses() public view {
        FusionFactoryStorageLib.FactoryAddresses memory a = factory.getFactoryAddresses();
        assertEq(a.accessManagerFactory, address(0x1));
        assertEq(a.plasmaVaultFactory, address(0x2));
    }

    function test_updatePlasmaVaultAdminArray_RevertOnZeroAddress() public {
            address[] memory admins = new address[](2);
            admins[0] = admin;
            admins[1] = address(0);
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updatePlasmaVaultAdminArray(admins);
            vm.stopPrank();
        }

    function test_updateFactoryAddresses_RevertOnZeroPlasmaVaultFactory() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that access control passes
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            FusionFactoryStorageLib.FactoryAddresses memory addrs = FusionFactoryStorageLib.FactoryAddresses({
                accessManagerFactory: address(0x1),
                plasmaVaultFactory: address(0), // trigger revert on this zero address to enter the targeted branch
                feeManagerFactory: address(0x3),
                withdrawManagerFactory: address(0x4),
                rewardsManagerFactory: address(0x5),
                contextManagerFactory: address(0x6),
                priceManagerFactory: address(0x7)
            });
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateFactoryAddresses(1, addrs);
            vm.stopPrank();
        }

    function test_updateFactoryAddresses_RevertOnZeroFeeManagerFactory() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that access control passes
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            FusionFactoryStorageLib.FactoryAddresses memory addrs = FusionFactoryStorageLib.FactoryAddresses({
                accessManagerFactory: address(0x1),
                plasmaVaultFactory: address(0x2),
                feeManagerFactory: address(0), // trigger revert on this zero address to enter opix-target-branch-182-True
                withdrawManagerFactory: address(0x4),
                rewardsManagerFactory: address(0x5),
                contextManagerFactory: address(0x6),
                priceManagerFactory: address(0x7)
            });
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateFactoryAddresses(1, addrs);
            vm.stopPrank();
        }

    function test_updateFactoryAddresses_RevertOnZeroWithdrawManagerFactory() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so access control passes
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            FusionFactoryStorageLib.FactoryAddresses memory addrs = FusionFactoryStorageLib.FactoryAddresses({
                accessManagerFactory: address(0x1),
                plasmaVaultFactory: address(0x2),
                feeManagerFactory: address(0x3),
                withdrawManagerFactory: address(0), // triggers opix-target-branch-183-True revert
                rewardsManagerFactory: address(0x5),
                contextManagerFactory: address(0x6),
                priceManagerFactory: address(0x7)
            });
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateFactoryAddresses(1, addrs);
            vm.stopPrank();
        }

    function test_updateFactoryAddresses_RevertOnZeroRewardsManagerFactory() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that access control passes
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            FusionFactoryStorageLib.FactoryAddresses memory addrs = FusionFactoryStorageLib.FactoryAddresses({
                accessManagerFactory: address(0x1),
                plasmaVaultFactory: address(0x2),
                feeManagerFactory: address(0x3),
                withdrawManagerFactory: address(0x4),
                rewardsManagerFactory: address(0), // trigger revert on this zero address to enter opix-target-branch-184-True
                contextManagerFactory: address(0x6),
                priceManagerFactory: address(0x7)
            });
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateFactoryAddresses(1, addrs);
            vm.stopPrank();
        }

    function test_updateFactoryAddresses_RevertOnZeroContextManagerFactory() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that access control passes
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            FusionFactoryStorageLib.FactoryAddresses memory addrs = FusionFactoryStorageLib.FactoryAddresses({
                accessManagerFactory: address(0x1),
                plasmaVaultFactory: address(0x2),
                feeManagerFactory: address(0x3),
                withdrawManagerFactory: address(0x4),
                rewardsManagerFactory: address(0x5),
                contextManagerFactory: address(0), // triggers opix-target-branch-185-True
                priceManagerFactory: address(0x7)
            });
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateFactoryAddresses(1, addrs);
            vm.stopPrank();
        }

    function test_updateFactoryAddresses_RevertOnZeroPriceManagerFactory() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that access control passes
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            FusionFactoryStorageLib.FactoryAddresses memory addrs = FusionFactoryStorageLib.FactoryAddresses({
                accessManagerFactory: address(0x1),
                plasmaVaultFactory: address(0x2),
                feeManagerFactory: address(0x3),
                withdrawManagerFactory: address(0x4),
                rewardsManagerFactory: address(0x5),
                contextManagerFactory: address(0x6),
                priceManagerFactory: address(0) // triggers opix-target-branch-186-True revert
            });
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateFactoryAddresses(1, addrs);
            vm.stopPrank();
        }

    function test_updateBaseAddresses_RevertOnZeroPlasmaVaultCoreBase() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that the call passes access control
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateBaseAddresses({
                version_: 1,
                newPlasmaVaultCoreBase_: address(0),
                newAccessManagerBase_: address(0x11),
                newPriceManagerBase_: address(0x12),
                newWithdrawManagerBase_: address(0x13),
                newRewardsManagerBase_: address(0x14),
                newContextManagerBase_: address(0x15)
            });
            vm.stopPrank();
        }

    function test_updateBaseAddresses_RevertOnZeroAccessManagerBase() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that the call passes access control
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateBaseAddresses({
                version_: 1,
                newPlasmaVaultCoreBase_: address(0x10),
                newAccessManagerBase_: address(0), // triggers the opix-target-branch-231-True revert
                newPriceManagerBase_: address(0x12),
                newWithdrawManagerBase_: address(0x13),
                newRewardsManagerBase_: address(0x14),
                newContextManagerBase_: address(0x15)
            });
            vm.stopPrank();
        }

    function test_updateBaseAddresses_RevertOnZeroPriceManagerBase() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that the call passes access control
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateBaseAddresses({
                version_: 1,
                newPlasmaVaultCoreBase_: address(0x10),
                newAccessManagerBase_: address(0x11),
                newPriceManagerBase_: address(0), // triggers the opix-target-branch-232-True revert
                newWithdrawManagerBase_: address(0x13),
                newRewardsManagerBase_: address(0x14),
                newContextManagerBase_: address(0x15)
            });
            vm.stopPrank();
        }

    function test_updateBaseAddresses_RevertOnZeroWithdrawManagerBase() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that the call passes access control
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateBaseAddresses({
                version_: 1,
                newPlasmaVaultCoreBase_: address(0x10),
                newAccessManagerBase_: address(0x11),
                newPriceManagerBase_: address(0x12),
                newWithdrawManagerBase_: address(0), // triggers opix-target-branch-233-True
                newRewardsManagerBase_: address(0x14),
                newContextManagerBase_: address(0x15)
            });
            vm.stopPrank();
        }

    function test_updateBaseAddresses_RevertOnZeroRewardsManagerBase() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that the call passes access control
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateBaseAddresses({
                version_: 1,
                newPlasmaVaultCoreBase_: address(0x10),
                newAccessManagerBase_: address(0x11),
                newPriceManagerBase_: address(0x12),
                newWithdrawManagerBase_: address(0x13),
                newRewardsManagerBase_: address(0), // triggers opix-target-branch-234-True
                newContextManagerBase_: address(0x15)
            });
            vm.stopPrank();
        }

    function test_updateBaseAddresses_RevertOnZeroContextManagerBase() public {
            // Grant MAINTENANCE_MANAGER_ROLE to admin so that the call passes access control
            bytes32 maintenanceRole = factory.MAINTENANCE_MANAGER_ROLE();
            vm.prank(admin);
            factory.grantRole(maintenanceRole, admin);
    
            vm.startPrank(admin);
            vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
            factory.updateBaseAddresses({
                version_: 1,
                newPlasmaVaultCoreBase_: address(0x10),
                newAccessManagerBase_: address(0x11),
                newPriceManagerBase_: address(0x12),
                newWithdrawManagerBase_: address(0x13),
                newRewardsManagerBase_: address(0x14),
                newContextManagerBase_: address(0) // triggers opix-target-branch-235-True revert
            });
            vm.stopPrank();
        }
}