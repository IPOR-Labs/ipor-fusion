// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryLazyDeployLib} from "../../contracts/factory/lib/FusionFactoryLazyDeployLib.sol";
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
import {IRewardsClaimManager} from "../../contracts/interfaces/IRewardsClaimManager.sol";

contract FusionFactoryLazyDeployTest is Test {
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

        plasmaVaultBase = address(new PlasmaVaultBase());
        burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

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
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 333,
            performanceFee: 777,
            feeRecipient: daoFeeRecipient
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

    // ======================= Helper =======================

    function _deployDeterministicVault(
        bytes32 masterSalt_
    ) internal returns (FusionFactoryLogicLib.FusionInstance memory) {
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Lazy Test Vault",
            "LTV",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt_
        );
        vm.stopPrank();
        return instance;
    }

    // ======================= Phase 1 Only Tests =======================

    function testShouldCloneWithSaltDeployPhase1Only() public {
        // given
        bytes32 masterSalt = keccak256("phase1-only");

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        // then - Phase 1 components are deployed (code exists)
        assertTrue(instance.plasmaVault.code.length > 0, "PlasmaVault should have code");
        assertTrue(instance.accessManager.code.length > 0, "AccessManager should have code");
        assertTrue(instance.priceManager.code.length > 0, "PriceManager should have code");
        assertTrue(instance.withdrawManager.code.length > 0, "WithdrawManager should have code");
        assertTrue(instance.feeManager.code.length > 0, "FeeManager should have code");

        // Phase 2 components are NOT deployed yet (no code at pre-computed addresses)
        assertEq(instance.rewardsManager.code.length, 0, "RewardsManager should NOT have code yet");
        assertEq(instance.contextManager.code.length, 0, "ContextManager should NOT have code yet");

        // But addresses are pre-computed (non-zero)
        assertTrue(instance.rewardsManager != address(0), "RewardsManager address should be pre-computed");
        assertTrue(instance.contextManager != address(0), "ContextManager address should be pre-computed");
    }

    // ======================= Deploy Component Tests =======================

    function testShouldDeployComponentRewardsManager() public {
        // given
        bytes32 masterSalt = keccak256("rewards-deploy");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);
        address expectedRewardsAddress = instance.rewardsManager;

        // when
        vm.startPrank(maintenanceManager);
        address deployedRewards = fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        vm.stopPrank();

        // then
        assertEq(deployedRewards, expectedRewardsAddress, "Deployed at predicted address");
        assertTrue(deployedRewards.code.length > 0, "RewardsManager should have code after deployment");

        // Verify configuration
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);
        assertEq(
            governanceVault.getRewardsClaimManagerAddress(),
            deployedRewards,
            "RewardsManager set on PlasmaVault"
        );

        // Verify vesting time
        RewardsClaimManager rewardsManager = RewardsClaimManager(deployedRewards);
        assertEq(rewardsManager.getVestingData().vestingTime, 1 weeks, "Vesting period should be 1 week");

        // Verify storage updated
        VaultInstanceAddresses memory stored = fusionFactory.getVaultInstanceAddresses(instance.plasmaVault);
        assertTrue(stored.rewardsManagerDeployed, "RewardsManager deployed flag should be true");
        assertFalse(stored.contextManagerDeployed, "ContextManager deployed flag should still be false");
    }

    function testShouldDeployComponentContextManager() public {
        // given
        bytes32 masterSalt = keccak256("context-deploy");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);
        address expectedContextAddress = instance.contextManager;

        // when
        vm.startPrank(maintenanceManager);
        address deployedContext = fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);
        vm.stopPrank();

        // then
        assertEq(deployedContext, expectedContextAddress, "Deployed at predicted address");
        assertTrue(deployedContext.code.length > 0, "ContextManager should have code after deployment");

        // Verify approved targets
        ContextManager contextManager = ContextManager(deployedContext);
        assertTrue(contextManager.isTargetApproved(instance.plasmaVault), "PlasmaVault should be approved");
        assertTrue(contextManager.isTargetApproved(instance.withdrawManager), "WithdrawManager should be approved");
        assertTrue(contextManager.isTargetApproved(instance.priceManager), "PriceManager should be approved");
        assertTrue(contextManager.isTargetApproved(instance.rewardsManager), "RewardsManager should be approved");
        assertTrue(contextManager.isTargetApproved(instance.feeManager), "FeeManager should be approved");

        // Verify storage updated
        VaultInstanceAddresses memory stored = fusionFactory.getVaultInstanceAddresses(instance.plasmaVault);
        assertTrue(stored.contextManagerDeployed, "ContextManager deployed flag should be true");
    }

    function testShouldDeployComponentAccessControlMaintenance() public {
        // given
        bytes32 masterSalt = keccak256("access-maintenance");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        // when - maintenance manager can deploy
        vm.startPrank(maintenanceManager);
        address deployedRewards = fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        vm.stopPrank();

        // then
        assertTrue(deployedRewards.code.length > 0, "Should deploy successfully");
    }

    function testShouldRevertDeployComponentUnauthorized() public {
        // given
        bytes32 masterSalt = keccak256("unauthorized-deploy");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);
        address unauthorized = address(0xBAD);

        // when / then
        vm.startPrank(unauthorized);
        vm.expectRevert();
        fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        vm.stopPrank();
    }

    function testShouldRevertDeployComponentDoubleDeploy() public {
        // given
        bytes32 masterSalt = keccak256("double-deploy");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        vm.startPrank(maintenanceManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);

        // when / then - deploying same component again reverts
        vm.expectRevert(FusionFactoryLazyDeployLib.ComponentAlreadyDeployed.selector);
        fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        vm.stopPrank();
    }

    function testShouldRevertDeployComponentUnknownVault() public {
        // given - a vault not created by factory
        address unknownVault = address(0xDEAD);

        // when / then
        vm.startPrank(maintenanceManager);
        vm.expectRevert(FusionFactoryLazyDeployLib.VaultNotRegistered.selector);
        fusionFactory.deployComponent(unknownVault, Component.RewardsManager);
        vm.stopPrank();
    }

    function testShouldDeployAllRemainingComponents() public {
        // given
        bytes32 masterSalt = keccak256("full-phase2");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        // when - deploy both Phase 2 components
        vm.startPrank(maintenanceManager);
        address deployedRewards = fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        address deployedContext = fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);
        vm.stopPrank();

        // then - all components deployed
        assertEq(deployedRewards, instance.rewardsManager, "RewardsManager at predicted address");
        assertEq(deployedContext, instance.contextManager, "ContextManager at predicted address");

        assertTrue(deployedRewards.code.length > 0, "RewardsManager has code");
        assertTrue(deployedContext.code.length > 0, "ContextManager has code");

        // Verify storage
        VaultInstanceAddresses memory stored = fusionFactory.getVaultInstanceAddresses(instance.plasmaVault);
        assertTrue(stored.rewardsManagerDeployed, "RewardsManager deployed");
        assertTrue(stored.contextManagerDeployed, "ContextManager deployed");
    }

    function testShouldLazyDeployRewardsThenContext() public {
        // given
        bytes32 masterSalt = keccak256("rewards-first");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        // when - deploy rewards first, then context
        vm.startPrank(maintenanceManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);
        vm.stopPrank();

        // then - verify RewardsManager is wired to PlasmaVault
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);
        assertEq(
            governanceVault.getRewardsClaimManagerAddress(),
            instance.rewardsManager,
            "RewardsManager address on vault"
        );

        // Verify ContextManager approved targets
        ContextManager contextManager = ContextManager(instance.contextManager);
        assertTrue(contextManager.isTargetApproved(instance.plasmaVault), "PlasmaVault approved");
        assertTrue(contextManager.isTargetApproved(instance.withdrawManager), "WithdrawManager approved");
        assertTrue(contextManager.isTargetApproved(instance.priceManager), "PriceManager approved");
        assertTrue(contextManager.isTargetApproved(instance.rewardsManager), "RewardsManager approved");
        assertTrue(contextManager.isTargetApproved(instance.feeManager), "FeeManager approved");
    }

    function testShouldLazyDeployContextThenRewards() public {
        // given
        bytes32 masterSalt = keccak256("context-first");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        // when - deploy context first, then rewards (reverse order)
        vm.startPrank(maintenanceManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        vm.stopPrank();

        // then - verify RewardsManager
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);
        assertEq(
            governanceVault.getRewardsClaimManagerAddress(),
            instance.rewardsManager,
            "RewardsManager address on vault"
        );

        // Verify ContextManager
        ContextManager contextManager = ContextManager(instance.contextManager);
        assertTrue(contextManager.isTargetApproved(instance.plasmaVault), "PlasmaVault approved");
    }

    function testShouldCloneFullStackBackwardCompatible() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when - use existing clone() — should deploy all 7 components
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Full Stack",
            "FS",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then - all 7 components deployed (not lazy)
        assertTrue(instance.plasmaVault.code.length > 0, "PlasmaVault has code");
        assertTrue(instance.accessManager.code.length > 0, "AccessManager has code");
        assertTrue(instance.priceManager.code.length > 0, "PriceManager has code");
        assertTrue(instance.withdrawManager.code.length > 0, "WithdrawManager has code");
        assertTrue(instance.feeManager.code.length > 0, "FeeManager has code");
        assertTrue(instance.rewardsManager.code.length > 0, "RewardsManager has code");
        assertTrue(instance.contextManager.code.length > 0, "ContextManager has code");

        // Verify full configuration
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);
        assertEq(
            governanceVault.getRewardsClaimManagerAddress(),
            instance.rewardsManager,
            "RewardsManager on PlasmaVault"
        );

        ContextManager contextManager = ContextManager(instance.contextManager);
        assertTrue(contextManager.isTargetApproved(instance.plasmaVault), "PlasmaVault approved");
        assertTrue(contextManager.isTargetApproved(instance.withdrawManager), "WithdrawManager approved");
        assertTrue(contextManager.isTargetApproved(instance.priceManager), "PriceManager approved");
        assertTrue(contextManager.isTargetApproved(instance.rewardsManager), "RewardsManager approved");
        assertTrue(contextManager.isTargetApproved(instance.feeManager), "FeeManager approved");
    }

    function testShouldDeployPhase1ThenDepositBeforePhase2() public {
        // given
        bytes32 masterSalt = keccak256("deposit-before-phase2");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        uint256 depositAmount = 1000 * 1e18;
        address depositor = address(0x123);
        underlyingToken.mint(depositor, depositAmount);

        // Setup whitelist
        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        // when - deposit before Phase 2 deployment
        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, depositAmount);
        PlasmaVault(instance.plasmaVault).deposit(depositAmount, depositor);
        vm.stopPrank();

        // then
        assertEq(underlyingToken.balanceOf(instance.plasmaVault), depositAmount, "Deposit successful");
        assertEq(
            PlasmaVault(instance.plasmaVault).balanceOf(depositor),
            depositAmount * 100,
            "Shares minted"
        );

        // Deploy Phase 2 after deposit
        vm.startPrank(maintenanceManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);
        vm.stopPrank();

        // Verify Phase 2 works
        assertTrue(instance.rewardsManager.code.length > 0, "RewardsManager deployed after deposit");
        assertTrue(instance.contextManager.code.length > 0, "ContextManager deployed after deposit");
    }

    function testShouldDoubleDeployContextManagerRevert() public {
        // given
        bytes32 masterSalt = keccak256("double-context");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        vm.startPrank(maintenanceManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);

        // when / then
        vm.expectRevert(FusionFactoryLazyDeployLib.ComponentAlreadyDeployed.selector);
        fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);
        vm.stopPrank();
    }

    function testShouldRevokeFactoryAdminRoleAfterAllPhase2Deployed() public {
        // given
        bytes32 masterSalt = keccak256("admin-revoke");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        // then - factory has ADMIN_ROLE after Phase 1 (needed for lazy deploy)
        (bool hasAdminAfterPhase1, ) = accessManager.hasRole(Roles.ADMIN_ROLE, address(fusionFactory));
        assertTrue(hasAdminAfterPhase1, "Factory should have ADMIN_ROLE after Phase 1");

        // when - deploy only RewardsManager
        vm.startPrank(maintenanceManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        vm.stopPrank();

        // then - factory still has ADMIN_ROLE (ContextManager not yet deployed)
        (bool hasAdminAfterRewards, ) = accessManager.hasRole(Roles.ADMIN_ROLE, address(fusionFactory));
        assertTrue(hasAdminAfterRewards, "Factory should still have ADMIN_ROLE after partial Phase 2");

        // when - deploy ContextManager (completes Phase 2)
        vm.startPrank(maintenanceManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);
        vm.stopPrank();

        // then - factory ADMIN_ROLE revoked (no longer needed)
        (bool hasAdminAfterAll, ) = accessManager.hasRole(Roles.ADMIN_ROLE, address(fusionFactory));
        assertFalse(hasAdminAfterAll, "Factory should NOT have ADMIN_ROLE after all Phase 2 deployed");
    }

    function testShouldRevokeFactoryAdminRoleWhenContextFirst() public {
        // given
        bytes32 masterSalt = keccak256("admin-revoke-reverse");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        // when - deploy Context first, then Rewards
        vm.startPrank(maintenanceManager);
        fusionFactory.deployComponent(instance.plasmaVault, Component.ContextManager);

        // then - factory still has ADMIN_ROLE (RewardsManager not yet deployed)
        (bool hasAdminAfterContext, ) = accessManager.hasRole(Roles.ADMIN_ROLE, address(fusionFactory));
        assertTrue(hasAdminAfterContext, "Factory should still have ADMIN_ROLE");

        fusionFactory.deployComponent(instance.plasmaVault, Component.RewardsManager);
        vm.stopPrank();

        // then - factory ADMIN_ROLE revoked
        (bool hasAdminAfterAll, ) = accessManager.hasRole(Roles.ADMIN_ROLE, address(fusionFactory));
        assertFalse(hasAdminAfterAll, "Factory should NOT have ADMIN_ROLE after all Phase 2 deployed");
    }
}
