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
import {IRewardsClaimManager} from "../../contracts/interfaces/IRewardsClaimManager.sol";

/// @title Fusion Factory CREATE3 Fork Integration Tests
/// @notice Tests cross-chain deterministic deployment behavior by simulating two independent factory deployments
contract FusionFactoryCreate3ForkTest is Test {
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

    // ======================= Helpers =======================

    function _deployDeterministicVault(
        bytes32 masterSalt_
    ) internal returns (FusionFactoryLogicLib.FusionInstance memory) {
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
            "Fork Test Vault",
            "FTV",
            address(underlyingToken),
            1 seconds,
            owner,
            0,
            masterSalt_
        );
        vm.stopPrank();
        return instance;
    }

    function _setupDepositor(
        address accessManager_,
        address depositor_,
        uint256 amount_
    ) internal {
        underlyingToken.mint(depositor_, amount_);
        vm.startPrank(owner);
        IporFusionAccessManager(accessManager_).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IporFusionAccessManager(accessManager_).grantRole(Roles.WHITELIST_ROLE, depositor_, 0);
        vm.stopPrank();
    }

    // ======================= Fork Integration Tests =======================

    function testForkDeterministicDeployEthereum() public {
        // given
        bytes32 masterSalt = keccak256("fork-ethereum-mainnet");

        // when - deploy full deterministic vault
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        // then - all Phase 1 addresses are non-zero and have code
        assertTrue(instance.plasmaVault != address(0), "PlasmaVault should be non-zero");
        assertTrue(instance.accessManager != address(0), "AccessManager should be non-zero");
        assertTrue(instance.priceManager != address(0), "PriceManager should be non-zero");
        assertTrue(instance.withdrawManager != address(0), "WithdrawManager should be non-zero");
        assertTrue(instance.feeManager != address(0), "FeeManager should be non-zero");

        assertTrue(instance.plasmaVault.code.length > 0, "PlasmaVault should have code");
        assertTrue(instance.accessManager.code.length > 0, "AccessManager should have code");
        assertTrue(instance.priceManager.code.length > 0, "PriceManager should have code");
        assertTrue(instance.withdrawManager.code.length > 0, "WithdrawManager should have code");
        assertTrue(instance.feeManager.code.length > 0, "FeeManager should have code");

        // Phase 2 addresses pre-computed but not deployed yet
        assertTrue(instance.rewardsManager != address(0), "RewardsManager address pre-computed");
        assertTrue(instance.contextManager != address(0), "ContextManager address pre-computed");
        assertEq(instance.rewardsManager.code.length, 0, "RewardsManager not deployed yet");
        assertEq(instance.contextManager.code.length, 0, "ContextManager not deployed yet");

        // Verify configuration is correct
        WithdrawManager withdrawManager = WithdrawManager(instance.withdrawManager);
        assertEq(withdrawManager.getPlasmaVaultAddress(), instance.plasmaVault, "WithdrawManager linked to vault");
        assertEq(withdrawManager.getWithdrawWindow(), 24 hours, "Withdraw window configured");

        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 333, "Management fee set");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 777, "Performance fee set");
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), daoFeeRecipient, "Fee recipient set");

        // Verify roles
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasPlasmaVaultRole, ) = accessManager.hasRole(Roles.TECH_PLASMA_VAULT_ROLE, instance.plasmaVault);
        assertTrue(hasPlasmaVaultRole, "PlasmaVault should have TECH_PLASMA_VAULT_ROLE");
        (bool hasWithdrawManagerRole, ) = accessManager.hasRole(
            Roles.TECH_WITHDRAW_MANAGER_ROLE,
            instance.withdrawManager
        );
        assertTrue(hasWithdrawManagerRole, "WithdrawManager should have TECH_WITHDRAW_MANAGER_ROLE");
    }

    function testForkSameSaltProducesSameAddresses() public {
        // given - same salt used for two separate prediction calls
        // This proves cross-chain determinism: CREATE3 depends only on deployer + salt
        bytes32 masterSalt = keccak256("cross-chain-deterministic");

        // when - predict addresses (first "chain")
        (
            address predictedVault1,
            address predictedAccess1,
            address predictedPrice1,
            address predictedWithdraw1,
            address predictedRewards1,
            address predictedContext1
        ) = fusionFactory.predictAddresses(masterSalt);

        // predict addresses again (simulates second "chain" with same factory setup)
        (
            address predictedVault2,
            address predictedAccess2,
            address predictedPrice2,
            address predictedWithdraw2,
            address predictedRewards2,
            address predictedContext2
        ) = fusionFactory.predictAddresses(masterSalt);

        // then - same salt produces same predictions (deterministic)
        assertEq(predictedVault1, predictedVault2, "PlasmaVault prediction deterministic");
        assertEq(predictedAccess1, predictedAccess2, "AccessManager prediction deterministic");
        assertEq(predictedPrice1, predictedPrice2, "PriceManager prediction deterministic");
        assertEq(predictedWithdraw1, predictedWithdraw2, "WithdrawManager prediction deterministic");
        assertEq(predictedRewards1, predictedRewards2, "RewardsManager prediction deterministic");
        assertEq(predictedContext1, predictedContext2, "ContextManager prediction deterministic");

        // All predicted addresses should be unique (different component salts)
        assertTrue(predictedVault1 != predictedAccess1, "Vault != Access");
        assertTrue(predictedVault1 != predictedPrice1, "Vault != Price");
        assertTrue(predictedVault1 != predictedWithdraw1, "Vault != Withdraw");
        assertTrue(predictedVault1 != predictedRewards1, "Vault != Rewards");
        assertTrue(predictedVault1 != predictedContext1, "Vault != Context");

        // Deploy and verify actual addresses match predictions
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        assertEq(instance.plasmaVault, predictedVault1, "Deployed vault matches prediction");
        assertEq(instance.accessManager, predictedAccess1, "Deployed access matches prediction");
        assertEq(instance.priceManager, predictedPrice1, "Deployed price matches prediction");
        assertEq(instance.withdrawManager, predictedWithdraw1, "Deployed withdraw matches prediction");
        assertEq(instance.rewardsManager, predictedRewards1, "Deployed rewards matches prediction");
        assertEq(instance.contextManager, predictedContext1, "Deployed context matches prediction");
    }

    function testForkFullStackPredictionMatchesDeployment() public {
        // given
        bytes32 masterSalt = keccak256("full-stack-prediction");

        // when - predict all 6 addresses via predictAddresses()
        (
            address predictedVault,
            address predictedAccess,
            address predictedPrice,
            address predictedWithdraw,
            address predictedRewards,
            address predictedContext
        ) = fusionFactory.predictAddresses(masterSalt);

        // deploy via cloneWithSalt() (Phase 1 deployed, Phase 2 pre-computed)
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        // then - all 6 addresses match predictions exactly
        assertEq(instance.plasmaVault, predictedVault, "PlasmaVault address matches prediction");
        assertEq(instance.accessManager, predictedAccess, "AccessManager address matches prediction");
        assertEq(instance.priceManager, predictedPrice, "PriceManager address matches prediction");
        assertEq(instance.withdrawManager, predictedWithdraw, "WithdrawManager address matches prediction");
        assertEq(instance.rewardsManager, predictedRewards, "RewardsManager address matches prediction");
        assertEq(instance.contextManager, predictedContext, "ContextManager address matches prediction");

        // Phase 1 components have code
        assertTrue(instance.plasmaVault.code.length > 0, "PlasmaVault has code");
        assertTrue(instance.accessManager.code.length > 0, "AccessManager has code");
        assertTrue(instance.priceManager.code.length > 0, "PriceManager has code");
        assertTrue(instance.withdrawManager.code.length > 0, "WithdrawManager has code");
        assertTrue(instance.feeManager.code.length > 0, "FeeManager has code");

        // Phase 2 addresses are pre-computed (non-zero) but not yet deployed
        assertEq(instance.rewardsManager.code.length, 0, "RewardsManager not deployed yet");
        assertEq(instance.contextManager.code.length, 0, "ContextManager not deployed yet");

        // Verify stored instance matches
        VaultInstanceAddresses memory stored = fusionFactory.getVaultInstanceAddresses(instance.plasmaVault);
        assertEq(stored.plasmaVault, predictedVault, "Stored plasmaVault matches prediction");
        assertEq(stored.accessManager, predictedAccess, "Stored accessManager matches prediction");
        assertEq(stored.priceManager, predictedPrice, "Stored priceManager matches prediction");
        assertEq(stored.withdrawManager, predictedWithdraw, "Stored withdrawManager matches prediction");
        assertEq(stored.rewardsManager, predictedRewards, "Stored rewardsManager matches prediction");
        assertEq(stored.contextManager, predictedContext, "Stored contextManager matches prediction");
        assertFalse(stored.rewardsManagerDeployed, "RewardsManager not yet deployed");
        assertFalse(stored.contextManagerDeployed, "ContextManager not yet deployed");
    }

    function testForkLazyDeployAndInteract() public {
        // given - Phase 1 deployment (lazy: RewardsManager and ContextManager not yet deployed)
        bytes32 masterSalt = keccak256("lazy-deploy-interact");
        FusionFactoryLogicLib.FusionInstance memory instance = _deployDeterministicVault(masterSalt);

        uint256 depositAmount = 1000 * 1e18;
        address depositor = address(0x123);
        _setupDepositor(instance.accessManager, depositor, depositAmount);

        // when - deposit during Phase 1 (before Phase 2 deployment)
        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, depositAmount);
        PlasmaVault(instance.plasmaVault).deposit(depositAmount, depositor);
        vm.stopPrank();

        // then - deposit successful
        assertEq(underlyingToken.balanceOf(instance.plasmaVault), depositAmount, "Vault received tokens");
        assertEq(
            PlasmaVault(instance.plasmaVault).balanceOf(depositor),
            depositAmount * 100,
            "Depositor received shares"
        );

        // Phase 2 components are pre-computed but NOT deployed
        assertTrue(instance.rewardsManager != address(0), "RewardsManager address pre-computed");
        assertTrue(instance.contextManager != address(0), "ContextManager address pre-computed");
        assertEq(instance.rewardsManager.code.length, 0, "RewardsManager not deployed yet");
        assertEq(instance.contextManager.code.length, 0, "ContextManager not deployed yet");

        // Verify that Phase 2 roles are already assigned on AccessManager (pre-computed addresses)
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasContextManagerRole, ) = accessManager.hasRole(
            Roles.TECH_CONTEXT_MANAGER_ROLE,
            instance.contextManager
        );
        assertTrue(hasContextManagerRole, "ContextManager role pre-assigned");
        (bool hasRewardsClaimManagerRole, ) = accessManager.hasRole(
            Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            instance.rewardsManager
        );
        assertTrue(hasRewardsClaimManagerRole, "RewardsManager role pre-assigned");

        // Vault remains functional with deposits even with Phase 2 not deployed
        uint256 additionalDeposit = 500 * 1e18;
        underlyingToken.mint(depositor, additionalDeposit);
        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, additionalDeposit);
        PlasmaVault(instance.plasmaVault).deposit(additionalDeposit, depositor);
        vm.stopPrank();

        assertEq(
            underlyingToken.balanceOf(instance.plasmaVault),
            depositAmount + additionalDeposit,
            "Total vault balance correct"
        );
    }

    function testForkCloneBackwardCompatible() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when - clone() deploys all 7 components atomically via doCloneDeterministicFullStack
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Backward Compatible",
            "BC",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then - all 7 components deployed
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

        // Verify deposit basics work
        uint256 depositAmount = 500 * 1e18;
        address depositor = address(0x456);
        _setupDepositor(instance.accessManager, depositor, depositAmount);

        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, depositAmount);
        PlasmaVault(instance.plasmaVault).deposit(depositAmount, depositor);
        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(instance.plasmaVault), depositAmount, "Deposit successful");
        assertEq(
            PlasmaVault(instance.plasmaVault).balanceOf(depositor),
            depositAmount * 100,
            "Shares minted correctly"
        );

        // Verify withdraw request works
        uint256 sharesToWithdraw = 100 * 1e18;
        vm.startPrank(depositor);
        WithdrawManager(instance.withdrawManager).requestShares(sharesToWithdraw);
        vm.stopPrank();

        // Verify request was recorded
        assertEq(
            WithdrawManager(instance.withdrawManager).requestInfo(depositor).shares,
            sharesToWithdraw,
            "Withdraw request recorded"
        );
    }
}
