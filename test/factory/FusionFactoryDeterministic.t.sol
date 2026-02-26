// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryCreate3Lib} from "../../contracts/factory/lib/FusionFactoryCreate3Lib.sol";
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
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {VaultInstanceAddresses, Component} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";

contract FusionFactoryDeterministicTest is Test {
    FusionFactory public fusionFactory;
    FusionFactory public fusionFactoryImplementation;
    FusionFactoryStorageLib.FactoryAddresses public factoryAddresses;
    address public plasmaVaultBase;
    address public priceOracleMiddleware;
    address public burnRequestFeeFuse;
    address public burnRequestFeeBalanceFuse;
    MockERC20 public underlyingToken;
    address public adminOne;
    address public adminTwo;
    address public daoFeeManager;
    address public maintenanceManager;
    address public owner;
    address public daoFeeRecipient;

    function setUp() public {
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        owner = address(0x777);
        daoFeeRecipient = address(0x888);
        adminOne = address(0x999);
        adminTwo = address(0x1000);
        daoFeeManager = address(0x111);
        maintenanceManager = address(0x222);

        // Deploy proxy first (uninitialized) so sub-factories know the FusionFactory address
        fusionFactoryImplementation = new FusionFactory();
        fusionFactory = FusionFactory(
            address(new ERC1967Proxy(address(fusionFactoryImplementation), ""))
        );

        factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory(address(fusionFactory))),
            plasmaVaultFactory: address(new PlasmaVaultFactory(address(fusionFactory))),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory(address(fusionFactory))),
            rewardsManagerFactory: address(new RewardsManagerFactory(address(fusionFactory))),
            contextManagerFactory: address(new ContextManagerFactory(address(fusionFactory))),
            priceManagerFactory: address(new PriceManagerFactory(address(fusionFactory)))
        });

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

        fusionFactory.initialize(
            owner,
            plasmaVaultAdminArray,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        vm.startPrank(daoFeeManager);
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](2);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 333,
            performanceFee: 777,
            feeRecipient: daoFeeRecipient
        });
        packages[1] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 200,
            feeRecipient: address(0x999)
        });
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

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

        vm.startPrank(maintenanceManager);
        fusionFactory.updateBaseAddresses(
            1,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
        vm.stopPrank();
    }

    // ======================= Deterministic Deployment Tests =======================

    function testShouldCloneWithSaltAndProduceDeterministicAddresses() public {
        // given
        bytes32 masterSalt = keccak256("test-salt-1");

        // predict addresses before deployment
        (
            address predictedVault,
            address predictedAccessManager,
            address predictedPriceManager,
            address predictedWithdrawManager,
            address predictedRewardsManager,
            address predictedContextManager
        ) = fusionFactory.predictAddresses(masterSalt);

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Deterministic Vault",
            "DV",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // then - Phase 1 addresses match predictions
        assertEq(instance.plasmaVault, predictedVault, "PlasmaVault address mismatch");
        assertEq(instance.accessManager, predictedAccessManager, "AccessManager address mismatch");
        assertEq(instance.priceManager, predictedPriceManager, "PriceManager address mismatch");
        assertEq(instance.withdrawManager, predictedWithdrawManager, "WithdrawManager address mismatch");

        // Phase 2 pre-computed addresses match predictions
        assertEq(instance.rewardsManager, predictedRewardsManager, "RewardsManager address mismatch");
        assertEq(instance.contextManager, predictedContextManager, "ContextManager address mismatch");

        // FeeManager is non-zero (created atomically inside PlasmaVault.init)
        assertTrue(instance.feeManager != address(0), "FeeManager should be deployed");
    }

    function testShouldCloneWithSaltAccessControl() public {
        // given
        bytes32 masterSalt = keccak256("access-control-salt");
        address unauthorized = address(0xBAD);

        // when / then - unauthorized caller reverts
        vm.startPrank(unauthorized);
        vm.expectRevert();
        fusionFactory.cloneWithSalt(
            "Test",
            "T",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // when - maintenance manager succeeds
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Test",
            "T",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        assertTrue(instance.plasmaVault != address(0), "Should deploy successfully");
    }

    function testShouldPredictAddressesMatchActualDeployment() public {
        // given
        bytes32 masterSalt = keccak256("predict-match-salt");

        // when - predict then deploy
        (
            address predictedVault,
            address predictedAccess,
            address predictedPrice,
            address predictedWithdraw,
            address predictedRewards,
            address predictedContext
        ) = fusionFactory.predictAddresses(masterSalt);

        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Predict Test",
            "PT",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // then
        assertEq(instance.plasmaVault, predictedVault);
        assertEq(instance.accessManager, predictedAccess);
        assertEq(instance.priceManager, predictedPrice);
        assertEq(instance.withdrawManager, predictedWithdraw);
        assertEq(instance.rewardsManager, predictedRewards);
        assertEq(instance.contextManager, predictedContext);
    }

    function testShouldPredictNextAddressesMatchClone() public {
        // given - predict what the next clone() will produce
        (
            address predictedVault,
            address predictedAccess,
            address predictedPrice,
            address predictedWithdraw,
            address predictedRewards,
            address predictedContext
        ) = fusionFactory.predictNextAddresses();

        // when - deploy using clone()
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Predict Next Vault",
            "PNV",
            address(underlyingToken),
            1 seconds,
            owner,
            0
        );

        // then - predicted addresses match actual deployed addresses
        assertEq(instance.plasmaVault, predictedVault, "PlasmaVault address mismatch");
        assertEq(instance.accessManager, predictedAccess, "AccessManager address mismatch");
        assertEq(instance.priceManager, predictedPrice, "PriceManager address mismatch");
        assertEq(instance.withdrawManager, predictedWithdraw, "WithdrawManager address mismatch");
        assertEq(instance.rewardsManager, predictedRewards, "RewardsManager address mismatch");
        assertEq(instance.contextManager, predictedContext, "ContextManager address mismatch");
    }

    function testShouldRevertOnSaltCollision() public {
        // given
        bytes32 masterSalt = keccak256("collision-salt");

        vm.startPrank(maintenanceManager);
        fusionFactory.cloneWithSalt(
            "First Vault",
            "FV",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );

        // when / then - same salt reverts
        vm.expectRevert();
        fusionFactory.cloneWithSalt(
            "Second Vault",
            "SV",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();
    }

    function testShouldNotCollideAutoSaltAndExplicitSalt() public {
        // given - deploy with auto-salt (clone)
        FusionFactoryLogicLib.FusionInstance memory autoInstance = fusionFactory.clone(
            "Auto Vault",
            "AV",
            address(underlyingToken),
            1 seconds,
            owner,
            0
        );

        // when - deploy with explicit salt (cloneWithSalt)
        bytes32 masterSalt = keccak256("no-collision-salt");
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory explicitInstance = fusionFactory.cloneWithSalt(
            "Explicit Vault",
            "EV",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // then - addresses should be different
        assertTrue(autoInstance.plasmaVault != explicitInstance.plasmaVault, "Vault addresses should differ");
        assertTrue(autoInstance.accessManager != explicitInstance.accessManager, "AccessManager addresses should differ");
        assertTrue(autoInstance.priceManager != explicitInstance.priceManager, "PriceManager addresses should differ");
        assertTrue(
            autoInstance.withdrawManager != explicitInstance.withdrawManager,
            "WithdrawManager addresses should differ"
        );
    }

    function testShouldCloneBackwardCompatibility() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when - use existing clone()
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "BC Vault",
            "BCV",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then - all 7 components deployed (full-stack, not lazy)
        assertTrue(instance.plasmaVault != address(0), "PlasmaVault deployed");
        assertTrue(instance.accessManager != address(0), "AccessManager deployed");
        assertTrue(instance.priceManager != address(0), "PriceManager deployed");
        assertTrue(instance.withdrawManager != address(0), "WithdrawManager deployed");
        assertTrue(instance.feeManager != address(0), "FeeManager deployed");
        assertTrue(instance.rewardsManager != address(0), "RewardsManager deployed");
        assertTrue(instance.contextManager != address(0), "ContextManager deployed");

        // Verify basic functionality
        assertEq(instance.assetName, "BC Vault");
        assertEq(instance.assetSymbol, "BCV");
        assertEq(instance.underlyingToken, address(underlyingToken));
        assertEq(instance.initialOwner, owner);

        // Verify deposit works
        uint256 depositAmount = 1000 * 1e18;
        address depositor = address(0x123);
        underlyingToken.mint(depositor, depositAmount);

        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, depositAmount);
        PlasmaVault(instance.plasmaVault).deposit(depositAmount, depositor);
        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(instance.plasmaVault), depositAmount);
    }

    function testShouldCloneSupervisedWithSalt() public {
        // given
        bytes32 masterSalt = keccak256("supervised-salt");
        address[] memory newPlasmaVaultAdminArray = new address[](2);
        newPlasmaVaultAdminArray[0] = address(0x321);
        newPlasmaVaultAdminArray[1] = address(0x123);

        vm.startPrank(owner);
        fusionFactory.updatePlasmaVaultAdminArray(newPlasmaVaultAdminArray);
        vm.stopPrank();

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneSupervisedWithSalt(
            "Supervised Vault",
            "SV",
            address(underlyingToken),
            3 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // then - admin roles should be assigned
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasRoleOne, ) = accessManager.hasRole(Roles.ADMIN_ROLE, newPlasmaVaultAdminArray[0]);
        (bool hasRoleTwo, ) = accessManager.hasRole(Roles.ADMIN_ROLE, newPlasmaVaultAdminArray[1]);
        assertTrue(hasRoleOne, "Admin 1 should have ADMIN_ROLE");
        assertTrue(hasRoleTwo, "Admin 2 should have ADMIN_ROLE");
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), 3 seconds);
    }

    function testShouldGetVaultInstanceAddresses() public {
        // given
        bytes32 masterSalt = keccak256("storage-salt");

        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Storage Test",
            "ST",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // when
        VaultInstanceAddresses memory stored = fusionFactory.getVaultInstanceAddresses(instance.plasmaVault);

        // then
        assertEq(stored.plasmaVault, instance.plasmaVault, "Stored plasmaVault mismatch");
        assertEq(stored.accessManager, instance.accessManager, "Stored accessManager mismatch");
        assertEq(stored.priceManager, instance.priceManager, "Stored priceManager mismatch");
        assertEq(stored.withdrawManager, instance.withdrawManager, "Stored withdrawManager mismatch");
        assertEq(stored.feeManager, instance.feeManager, "Stored feeManager mismatch");
        assertEq(stored.rewardsManager, instance.rewardsManager, "Stored rewardsManager mismatch");
        assertEq(stored.contextManager, instance.contextManager, "Stored contextManager mismatch");
        assertFalse(stored.rewardsManagerDeployed, "RewardsManager should not be deployed yet");
        assertFalse(stored.contextManagerDeployed, "ContextManager should not be deployed yet");
    }

    function testShouldDeployTwoDeterministicVaultsWithUniqueAddresses() public {
        // given
        bytes32 salt1 = keccak256("vault-1");
        bytes32 salt2 = keccak256("vault-2");

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance1 = fusionFactory.cloneWithSalt(
            "Vault 1",
            "V1",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            salt1
        );
        FusionFactoryLogicLib.FusionInstance memory instance2 = fusionFactory.cloneWithSalt(
            "Vault 2",
            "V2",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            salt2
        );
        vm.stopPrank();

        // then
        assertTrue(instance1.plasmaVault != instance2.plasmaVault, "Vault addresses should differ");
        assertTrue(instance1.accessManager != instance2.accessManager, "AccessManager addresses should differ");
        assertTrue(instance1.priceManager != instance2.priceManager, "PriceManager addresses should differ");
        assertTrue(instance1.withdrawManager != instance2.withdrawManager, "WithdrawManager addresses should differ");
        assertTrue(instance1.feeManager != instance2.feeManager, "FeeManager addresses should differ");
        assertTrue(instance1.rewardsManager != instance2.rewardsManager, "RewardsManager addresses should differ");
        assertTrue(instance1.contextManager != instance2.contextManager, "ContextManager addresses should differ");
    }

    function testShouldCloneWithSaltAndHaveCorrectTechnicalRoles() public {
        // given
        bytes32 masterSalt = keccak256("roles-salt");

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Roles Test",
            "RT",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        (bool hasPlasmaVaultRole, ) = accessManager.hasRole(Roles.TECH_PLASMA_VAULT_ROLE, instance.plasmaVault);
        assertTrue(hasPlasmaVaultRole, "PlasmaVault should have TECH_PLASMA_VAULT_ROLE");

        (bool hasWithdrawManagerRole, ) = accessManager.hasRole(
            Roles.TECH_WITHDRAW_MANAGER_ROLE,
            instance.withdrawManager
        );
        assertTrue(hasWithdrawManagerRole, "WithdrawManager should have TECH_WITHDRAW_MANAGER_ROLE");

        (bool hasVaultTransferSharesRole, ) = accessManager.hasRole(
            Roles.TECH_VAULT_TRANSFER_SHARES_ROLE,
            instance.feeManager
        );
        assertTrue(hasVaultTransferSharesRole, "FeeManager should have TECH_VAULT_TRANSFER_SHARES_ROLE");

        (bool hasPerformanceFeeManagerRole, ) = accessManager.hasRole(
            Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
            instance.feeManager
        );
        assertTrue(hasPerformanceFeeManagerRole, "FeeManager should have TECH_PERFORMANCE_FEE_MANAGER_ROLE");

        // Phase 2 pre-computed addresses should have roles pre-assigned
        (bool hasContextManagerRole, ) = accessManager.hasRole(
            Roles.TECH_CONTEXT_MANAGER_ROLE,
            instance.contextManager
        );
        assertTrue(hasContextManagerRole, "ContextManager should have TECH_CONTEXT_MANAGER_ROLE");

        (bool hasRewardsClaimManagerRole, ) = accessManager.hasRole(
            Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            instance.rewardsManager
        );
        assertTrue(hasRewardsClaimManagerRole, "RewardsManager should have TECH_REWARDS_CLAIM_MANAGER_ROLE");
    }

    function testShouldCloneWithSaltAndHaveCorrectFeeConfiguration() public {
        // given
        bytes32 masterSalt = keccak256("fee-salt");

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Fee Test",
            "FT",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 333, "Management fee mismatch");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 777, "Performance fee mismatch");
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), daoFeeRecipient, "Fee recipient mismatch");
    }

    function testShouldCloneWithSaltAndConfigureWithdrawManager() public {
        // given
        bytes32 masterSalt = keccak256("withdraw-salt");

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Withdraw Test",
            "WT",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt
        );
        vm.stopPrank();

        // then
        WithdrawManager withdrawManager = WithdrawManager(instance.withdrawManager);
        assertEq(withdrawManager.getPlasmaVaultAddress(), instance.plasmaVault, "PlasmaVault address on WM mismatch");
        assertEq(withdrawManager.getWithdrawWindow(), 24 hours, "Withdraw window mismatch");
    }
}
