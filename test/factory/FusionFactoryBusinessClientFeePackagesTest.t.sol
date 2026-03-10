// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

contract FusionFactoryBusinessClientFeePackagesTest is Test {
    FusionFactory public fusionFactory;
    FusionFactoryStorageLib.FactoryAddresses public factoryAddresses;
    address public plasmaVaultBase;
    address public priceOracleMiddleware;
    address public burnRequestFeeFuse;
    address public burnRequestFeeBalanceFuse;
    MockERC20 public underlyingToken;
    address public owner;
    address public daoFeeManager;
    address public maintenanceManager;
    address public daoFeeRecipient;

    function setUp() public {
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        owner = address(0x777);
        daoFeeRecipient = address(0x888);
        daoFeeManager = address(0x111);
        maintenanceManager = address(0x222);
        address adminOne = address(0x999);
        address adminTwo = address(0x1000);
        address[] memory plasmaVaultAdminArray = new address[](2);
        plasmaVaultAdminArray[0] = adminOne;
        plasmaVaultAdminArray[1] = adminTwo;

        plasmaVaultBase = address(new PlasmaVaultBase());
        burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        FusionFactory fusionFactoryImplementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],(address,address,address,address,address,address,address),address,address,address,address)",
            owner,
            plasmaVaultAdminArray,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(fusionFactoryImplementation), initData)));

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        // Setup global DAO fee packages
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 333,
            performanceFee: 777,
            feeRecipient: daoFeeRecipient
        });
        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);

        // Setup base addresses for cloning
        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = address(1);

        address accessManagerBase = address(new IporFusionAccessManager(owner, 1 seconds));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address contextManagerBase = address(new ContextManager(owner, approvedAddresses));
        address priceManagerBase = address(new PriceOracleMiddlewareManager(owner, priceOracleMiddleware));

        address plasmaVaultCoreBase = address(new PlasmaVault());
        PlasmaVault(plasmaVaultCoreBase).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "fake",
                assetSymbol: "fake",
                underlyingToken: address(underlyingToken),
                priceOracleMiddleware: priceOracleMiddleware,
                feeConfig: FeeConfig({
                    feeFactory: factoryAddresses.feeManagerFactory,
                    iporDaoManagementFee: 111,
                    iporDaoPerformanceFee: 222,
                    iporDaoFeeRecipientAddress: address(this)
                }),
                accessManager: accessManagerBase,
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: withdrawManagerBase,
                plasmaVaultVotesPlugin: address(0)
            })
        );

        address rewardsManagerBase = address(new RewardsClaimManager(owner, plasmaVaultCoreBase));

        vm.prank(maintenanceManager);
        fusionFactory.updateBaseAddresses(
            1,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
    }

    // ============ setBusinessClientFeePackages ============

    function test_setBusinessClientFeePackages_shouldSetCustomFeePackages() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("clientFeeRecipient")
        });

        // when
        vm.prank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);

        // then
        (FusionFactoryStorageLib.FeePackage[] memory result, bool isCustom) = fusionFactory
            .getBusinessClientFeePackages(businessClient);
        assertTrue(isCustom);
        assertEq(result.length, 1);
        assertEq(result[0].managementFee, 100);
        assertEq(result[0].performanceFee, 500);
        assertEq(result[0].feeRecipient, makeAddr("clientFeeRecipient"));
    }

    function test_setBusinessClientFeePackages_shouldRevertWhenCallerNotAuthorized() public {
        // given
        address unauthorized = makeAddr("unauthorized");
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("recipient")
        });

        // when / then
        vm.prank(unauthorized);
        vm.expectRevert();
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);
    }

    function test_setBusinessClientFeePackages_shouldRevertWhenClientAddressZero() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("recipient")
        });

        // when / then
        vm.prank(daoFeeManager);
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.BusinessClientAddressZero.selector));
        fusionFactory.setBusinessClientFeePackages(address(0), packages);
    }

    function test_setBusinessClientFeePackages_shouldRevertWhenEmptyArray() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](0);

        // when / then
        vm.prank(daoFeeManager);
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.DaoFeePackagesArrayEmpty.selector));
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);
    }

    function test_setBusinessClientFeePackages_shouldRevertWhenManagementFeeExceedsMax() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 10001,
            performanceFee: 500,
            feeRecipient: makeAddr("recipient")
        });

        // when / then
        vm.prank(daoFeeManager);
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.FeeExceedsMaximum.selector, 10001, 10000));
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);
    }

    function test_setBusinessClientFeePackages_shouldRevertWhenPerformanceFeeExceedsMax() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 10001,
            feeRecipient: makeAddr("recipient")
        });

        // when / then
        vm.prank(daoFeeManager);
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.FeeExceedsMaximum.selector, 10001, 10000));
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);
    }

    function test_setBusinessClientFeePackages_shouldRevertWhenFeeRecipientZero() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: address(0)
        });

        // when / then
        vm.prank(daoFeeManager);
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.FeeRecipientZeroAddress.selector));
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);
    }

    function test_setBusinessClientFeePackages_shouldOverwriteExistingPackages() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages1 = new FusionFactoryStorageLib.FeePackage[](1);
        packages1[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("recipient1")
        });

        FusionFactoryStorageLib.FeePackage[] memory packages2 = new FusionFactoryStorageLib.FeePackage[](1);
        packages2[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 200,
            performanceFee: 600,
            feeRecipient: makeAddr("recipient2")
        });

        // when
        vm.startPrank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(businessClient, packages1);
        fusionFactory.setBusinessClientFeePackages(businessClient, packages2);
        vm.stopPrank();

        // then
        (FusionFactoryStorageLib.FeePackage[] memory result, bool isCustom) = fusionFactory
            .getBusinessClientFeePackages(businessClient);
        assertTrue(isCustom);
        assertEq(result.length, 1);
        assertEq(result[0].managementFee, 200);
        assertEq(result[0].performanceFee, 600);
        assertEq(result[0].feeRecipient, makeAddr("recipient2"));
    }

    function test_setBusinessClientFeePackages_shouldSetMultiplePackages() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](3);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("recipient1")
        });
        packages[1] = FusionFactoryStorageLib.FeePackage({
            managementFee: 200,
            performanceFee: 1000,
            feeRecipient: makeAddr("recipient2")
        });
        packages[2] = FusionFactoryStorageLib.FeePackage({
            managementFee: 300,
            performanceFee: 1500,
            feeRecipient: makeAddr("recipient3")
        });

        // when
        vm.prank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);

        // then
        (FusionFactoryStorageLib.FeePackage[] memory result, bool isCustom) = fusionFactory
            .getBusinessClientFeePackages(businessClient);
        assertTrue(isCustom);
        assertEq(result.length, 3);
        assertEq(result[0].managementFee, 100);
        assertEq(result[1].managementFee, 200);
        assertEq(result[2].managementFee, 300);
    }

    // ============ removeBusinessClientFeePackages ============

    function test_removeBusinessClientFeePackages_shouldRemoveCustomFeePackages() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("clientRecipient")
        });

        vm.startPrank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);

        // when
        fusionFactory.removeBusinessClientFeePackages(businessClient);
        vm.stopPrank();

        // then
        (FusionFactoryStorageLib.FeePackage[] memory result, bool isCustom) = fusionFactory
            .getBusinessClientFeePackages(businessClient);
        assertFalse(isCustom);
        // Should return global packages
        assertEq(result.length, 1);
        assertEq(result[0].managementFee, 333);
        assertEq(result[0].performanceFee, 777);
    }

    function test_removeBusinessClientFeePackages_shouldRevertWhenCallerNotAuthorized() public {
        // given
        address unauthorized = makeAddr("unauthorized");
        address businessClient = makeAddr("businessClient");

        // when / then
        vm.prank(unauthorized);
        vm.expectRevert();
        fusionFactory.removeBusinessClientFeePackages(businessClient);
    }

    function test_removeBusinessClientFeePackages_shouldRevertWhenNoPackagesSet() public {
        // given
        address businessClient = makeAddr("businessClient");

        // when / then
        vm.prank(daoFeeManager);
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.DaoFeePackagesArrayEmpty.selector));
        fusionFactory.removeBusinessClientFeePackages(businessClient);
    }

    // ============ getBusinessClientFeePackages ============

    function test_getBusinessClientFeePackages_shouldReturnCustomPackagesWhenSet() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("clientRecipient")
        });
        vm.prank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(businessClient, packages);

        // when
        (FusionFactoryStorageLib.FeePackage[] memory result, bool isCustom) = fusionFactory
            .getBusinessClientFeePackages(businessClient);

        // then
        assertTrue(isCustom);
        assertEq(result.length, 1);
        assertEq(result[0].managementFee, 100);
        assertEq(result[0].performanceFee, 500);
    }

    function test_getBusinessClientFeePackages_shouldReturnDefaultPackagesWhenNotSet() public {
        // given
        address businessClient = makeAddr("businessClient");

        // when
        (FusionFactoryStorageLib.FeePackage[] memory result, bool isCustom) = fusionFactory
            .getBusinessClientFeePackages(businessClient);

        // then
        assertFalse(isCustom);
        assertEq(result.length, 1);
        assertEq(result[0].managementFee, 333);
        assertEq(result[0].performanceFee, 777);
        assertEq(result[0].feeRecipient, daoFeeRecipient);
    }

    // ============ clone with business client packages ============

    function test_clone_shouldUseBusinessClientFeePackageAtIndex() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory clientPackages = new FusionFactoryStorageLib.FeePackage[](1);
        clientPackages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("clientFeeRecipient")
        });
        vm.prank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(businessClient, clientPackages);

        // when
        vm.prank(businessClient);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Business Vault",
            "BV",
            address(underlyingToken),
            1 days,
            makeAddr("vaultOwner"),
            0
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 100);
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 500);
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), makeAddr("clientFeeRecipient"));
    }

    function test_clone_shouldUseDefaultFeePackageWhenNoBusinessClientPackages() public {
        // given
        address regularCaller = makeAddr("regularCaller");

        // when
        vm.prank(regularCaller);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Regular Vault",
            "RV",
            address(underlyingToken),
            1 days,
            makeAddr("vaultOwner"),
            0
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 333);
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 777);
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), daoFeeRecipient);
    }

    function test_clone_shouldRevertWhenBusinessClientIndexOutOfBounds() public {
        // given
        address businessClient = makeAddr("businessClient");
        FusionFactoryStorageLib.FeePackage[] memory clientPackages = new FusionFactoryStorageLib.FeePackage[](1);
        clientPackages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 500,
            feeRecipient: makeAddr("clientFeeRecipient")
        });
        vm.prank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(businessClient, clientPackages);

        // when / then
        vm.prank(businessClient);
        vm.expectRevert(
            abi.encodeWithSelector(FusionFactoryLogicLib.DaoFeePackageIndexOutOfBounds.selector, 5, 1)
        );
        fusionFactory.clone(
            "Business Vault",
            "BV",
            address(underlyingToken),
            1 days,
            makeAddr("vaultOwner"),
            5
        );
    }

    function test_cloneSupervised_shouldUseBusinessClientFeePackageWhenSet() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory clientPackages = new FusionFactoryStorageLib.FeePackage[](1);
        clientPackages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 50,
            performanceFee: 250,
            feeRecipient: makeAddr("supervisedClientRecipient")
        });
        vm.prank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(maintenanceManager, clientPackages);

        // when
        vm.prank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneSupervised(
            "Supervised Vault",
            "SV",
            address(underlyingToken),
            1 days,
            makeAddr("vaultOwner"),
            0
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 50);
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 250);
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), makeAddr("supervisedClientRecipient"));
    }
}
