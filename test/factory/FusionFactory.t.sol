// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
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
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultPauser} from "../../contracts/managers/pause/PlasmaVaultPauser.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Vm} from "forge-std/Vm.sol";
contract FusionFactoryTest is Test {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.FusionVaults")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FUSION_VAULTS_SLOT = 0xd8f986f99805409cbb90b99bdf93bd9819d8b8f9dd5c2456ffaf840ff9eb8900;

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
        // Deploy mock token
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        // Deploy factory contracts
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

        // Deploy implementation and proxy for FusionFactory
        fusionFactoryImplementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,(address,address,address,address,address,address,address),address,address,address,address)",
            owner,
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

        vm.startPrank(daoFeeManager);
        // Setup fee packages for testing
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

    function testShouldCloneFusionInstance() public {
        //given
        uint256 redemptionDelay = 1 seconds;

        //when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        //then
        assertEq(instance.assetName, "Test Asset");
        assertEq(instance.assetSymbol, "TEST");
        assertEq(instance.underlyingToken, address(underlyingToken));
        assertEq(instance.initialOwner, owner);
        assertEq(instance.plasmaVaultBase, plasmaVaultBase);

        assertTrue(instance.accessManager != address(0));
        assertTrue(instance.withdrawManager != address(0));
        assertTrue(instance.priceManager != address(0));
        assertTrue(instance.plasmaVault != address(0));
        assertTrue(instance.rewardsManager != address(0));
        assertTrue(instance.contextManager != address(0));
        assertTrue(instance.feeManager != address(0));
    }

    function testShouldCreateFusionInstance() public {
        //given
        uint256 redemptionDelay = 1 seconds;
        //when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        //then
        assertEq(instance.assetName, "Test Asset");
        assertEq(instance.assetSymbol, "TEST");
        assertEq(instance.underlyingToken, address(underlyingToken));
        assertEq(instance.initialOwner, owner);
        assertEq(instance.plasmaVaultBase, plasmaVaultBase);

        assertTrue(instance.accessManager != address(0));
        assertTrue(instance.withdrawManager != address(0));
        assertTrue(instance.priceManager != address(0));
        assertTrue(instance.plasmaVault != address(0));
        assertTrue(instance.rewardsManager != address(0));
        assertTrue(instance.contextManager != address(0));
        assertTrue(instance.feeManager != address(0));
    }

    function testShouldUpdateFactoryAddresses() public {
        // given
        FusionFactoryStorageLib.FactoryAddresses memory newFactoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        // when
        vm.startPrank(maintenanceManager);
        fusionFactory.updateFactoryAddresses(33, newFactoryAddresses);
        vm.stopPrank();

        // then
        FusionFactoryStorageLib.FactoryAddresses memory updatedAddresses = fusionFactory.getFactoryAddresses();
        assertEq(updatedAddresses.accessManagerFactory, newFactoryAddresses.accessManagerFactory);
        assertEq(updatedAddresses.plasmaVaultFactory, newFactoryAddresses.plasmaVaultFactory);
        assertEq(updatedAddresses.feeManagerFactory, newFactoryAddresses.feeManagerFactory);
        assertEq(updatedAddresses.withdrawManagerFactory, newFactoryAddresses.withdrawManagerFactory);
        assertEq(updatedAddresses.rewardsManagerFactory, newFactoryAddresses.rewardsManagerFactory);
        assertEq(updatedAddresses.contextManagerFactory, newFactoryAddresses.contextManagerFactory);
        assertEq(updatedAddresses.priceManagerFactory, newFactoryAddresses.priceManagerFactory);
        assertEq(fusionFactory.getFusionFactoryVersion(), 33);
    }

    function testShouldUpdatePlasmaVaultBase() public {
        // given
        address newPlasmaVaultBase = address(new PlasmaVaultBase());

        // when
        vm.startPrank(maintenanceManager);
        fusionFactory.updatePlasmaVaultBase(newPlasmaVaultBase);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getPlasmaVaultBaseAddress(), newPlasmaVaultBase);
    }

    function testShouldUpdatePriceOracleMiddleware() public {
        // given
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        address newPriceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        // when
        vm.startPrank(maintenanceManager);
        fusionFactory.updatePriceOracleMiddleware(newPriceOracleMiddleware);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getPriceOracleMiddleware(), newPriceOracleMiddleware);
    }

    function testShouldUpdateBurnRequestFeeFuse() public {
        // given
        address newBurnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        // when
        vm.startPrank(maintenanceManager);
        fusionFactory.updateBurnRequestFeeFuse(newBurnRequestFeeFuse);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getBurnRequestFeeFuseAddress(), newBurnRequestFeeFuse);
    }

    function testShouldUpdateBurnRequestFeeBalanceFuse() public {
        // given
        address newBurnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        // when
        vm.startPrank(maintenanceManager);
        fusionFactory.updateBurnRequestFeeBalanceFuse(newBurnRequestFeeBalanceFuse);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getBurnRequestFeeBalanceFuseAddress(), newBurnRequestFeeBalanceFuse);
    }

    function testShouldUpdateWithdrawWindowInSeconds() public {
        // given
        uint256 newWithdrawWindow = 86400; // 24 hours

        // when
        vm.startPrank(maintenanceManager);
        fusionFactory.updateWithdrawWindowInSeconds(newWithdrawWindow);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getWithdrawWindowInSeconds(), newWithdrawWindow);
    }

    function testShouldUpdateVestingPeriodInSeconds() public {
        // given
        uint256 newVestingPeriod = 604800; // 1 week

        // when
        vm.startPrank(maintenanceManager);
        fusionFactory.updateVestingPeriodInSeconds(newVestingPeriod);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getVestingPeriodInSeconds(), newVestingPeriod);
    }

    function testShouldRevertWhenUpdatingFactoryAddressesWithZeroAddress() public {
        // given
        FusionFactoryStorageLib.FactoryAddresses memory newFactoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(0),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        vm.startPrank(maintenanceManager);
        fusionFactory.updateFactoryAddresses(1, newFactoryAddresses);
        vm.stopPrank();
    }

    function testShouldRevertWhenUpdatingPlasmaVaultBaseWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        vm.startPrank(maintenanceManager);
        fusionFactory.updatePlasmaVaultBase(address(0));
        vm.stopPrank();
    }

    function testShouldRevertWhenUpdatingPriceOracleMiddlewareWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        vm.startPrank(maintenanceManager);
        fusionFactory.updatePriceOracleMiddleware(address(0));
        vm.stopPrank();
    }

    function testShouldRevertWhenUpdatingBurnRequestFeeFuseWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        vm.startPrank(maintenanceManager);
        fusionFactory.updateBurnRequestFeeFuse(address(0));
        vm.stopPrank();
    }

    function testShouldRevertWhenUpdatingBurnRequestFeeBalanceFuseWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        vm.startPrank(maintenanceManager);
        fusionFactory.updateBurnRequestFeeBalanceFuse(address(0));
        vm.stopPrank();
    }

    function testShouldRevertWhenUpdatingWithdrawWindowWithZero() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidWithdrawWindow.selector);
        vm.startPrank(maintenanceManager);
        fusionFactory.updateWithdrawWindowInSeconds(0);
        vm.stopPrank();
    }

    function testShouldNotRevertWhenUpdatingVestingPeriodWithZero() public {
        // when/then
        vm.startPrank(maintenanceManager);
        fusionFactory.updateVestingPeriodInSeconds(0);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getVestingPeriodInSeconds(), 0);
    }

    function testShouldCreateVaultWithoutAdmin() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasRoleOne, ) = accessManager.hasRole(Roles.ADMIN_ROLE, adminOne);
        (bool hasRoleTwo, ) = accessManager.hasRole(Roles.ADMIN_ROLE, adminTwo);
        assertFalse(hasRoleOne);
        assertFalse(hasRoleTwo);
    }

    function testShouldCloneVaultWithoutAdmin() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasRoleOne, ) = accessManager.hasRole(Roles.ADMIN_ROLE, adminOne);
        (bool hasRoleTwo, ) = accessManager.hasRole(Roles.ADMIN_ROLE, adminTwo);
        assertFalse(hasRoleOne);
        assertFalse(hasRoleTwo);
    }

    function testShouldCreatePremiumVaultWithAdmin() public {
        // given
        uint256 redemptionDelay = 3 seconds;

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneSupervised(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        vm.stopPrank();

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasAdminRole, uint32 adminDelay) = accessManager.hasRole(Roles.ADMIN_ROLE, maintenanceManager);
        assertTrue(hasAdminRole);
        assertEq(adminDelay, 0);
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
    }

    function testShouldClonePremiumVaultWithAdmin() public {
        // given
        uint256 redemptionDelay = 3 seconds;

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneSupervised(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        vm.stopPrank();

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasAdminRole, uint32 adminDelay) = accessManager.hasRole(Roles.ADMIN_ROLE, maintenanceManager);
        assertTrue(hasAdminRole);
        assertEq(adminDelay, 0);
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
    }

    function testShouldCreateVaultWithCorrectRedemptionDelay() public {
        // given
        uint256 redemptionDelay = 123;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
    }

    function testShouldCloneVaultWithCorrectRedemptionDelay() public {
        // given
        uint256 redemptionDelay = 123;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
    }

    function testShouldCreateVaultWithZeroRedemptionDelay() public {
        // given
        uint256 redemptionDelay = 0;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), 0);
    }

    function testShouldCloneVaultWithZeroRedemptionDelay() public {
        // given
        uint256 redemptionDelay = 0;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), 0);
    }

    function testShouldOwnerChangeRedemptionDelayAfterVaultCreation() public {
        // given
        uint256 redemptionDelay = 123;

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);

        // when - the owner changes the delay through the vault's governance entry point
        vm.prank(owner);
        IPlasmaVaultGovernance(instance.plasmaVault).setRedemptionDelay(0);

        // then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), 0);

        // when
        vm.prank(owner);
        IPlasmaVaultGovernance(instance.plasmaVault).setRedemptionDelay(7 days);

        // then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), 7 days);
    }

    function testShouldNotChangeRedemptionDelayDirectlyOnAccessManagerEvenWhenOwner() public {
        // given - the access manager setter is reserved for the vault (TECH_PLASMA_VAULT_ROLE), the owner must go
        // through PlasmaVaultGovernance.setRedemptionDelay so the OWNER_ROLE timelock can apply
        uint256 redemptionDelay = 123;

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        // when
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", owner));
        vm.prank(owner);
        accessManager.setRedemptionDelay(0);

        // then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
    }

    function testShouldNotChangeRedemptionDelayAfterVaultCreationWhenNotOwner() public {
        // given
        uint256 redemptionDelay = 123;

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        // when
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", adminOne));
        vm.prank(adminOne);
        IPlasmaVaultGovernance(instance.plasmaVault).setRedemptionDelay(0);

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", adminOne));
        vm.prank(adminOne);
        accessManager.setRedemptionDelay(0);

        // then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
    }

    function testShouldPauseVaultThroughPlasmaVaultPauserWithGuardianRole() public {
        // given - IL-7725: the pauser contract uses the same updateTargetClosed / GUARDIAN_ROLE path as a human guardian
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            0,
            owner,
            0
        );
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        assertEq(
            accessManager.getTargetFunctionRole(
                instance.accessManager,
                IporFusionAccessManager.updateTargetClosed.selector
            ),
            Roles.GUARDIAN_ROLE,
            "updateTargetClosed mapped to GUARDIAN_ROLE"
        );
        assertEq(accessManager.getRoleAdmin(Roles.GUARDIAN_ROLE), Roles.OWNER_ROLE, "owner administers GUARDIAN_ROLE");

        // and - a guardian appointed after creation needs GUARDIAN_ROLE only to pause and unpause
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, guardian, 0);

        vm.startPrank(guardian);
        accessManager.updateTargetClosed(instance.plasmaVault, true);
        assertTrue(accessManager.isTargetClosed(instance.plasmaVault), "guardian paused");
        accessManager.updateTargetClosed(instance.plasmaVault, false);
        assertFalse(accessManager.isTargetClosed(instance.plasmaVault), "guardian unpaused");
        vm.stopPrank();

        // when - governance opts in: the owner grants GUARDIAN_ROLE to a PlasmaVaultPauser, no other access manager change
        PlasmaVaultPauser pauser = new PlasmaVaultPauser(owner);
        address emergencyKey = makeAddr("emergencyKey");
        vm.startPrank(owner);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, address(pauser), 0);
        pauser.addToWhitelist(instance.plasmaVault, emergencyKey);
        vm.stopPrank();

        vm.prank(emergencyKey);
        pauser.pause(instance.plasmaVault);

        // then
        assertTrue(accessManager.isTargetClosed(instance.plasmaVault), "vault paused through the PlasmaVaultPauser");
        assertFalse(pauser.isWhitelisted(instance.plasmaVault, emergencyKey), "one-shot entry consumed");

        // and - the guardian reopens the vault, the pauser contract has no function for it
        vm.prank(guardian);
        accessManager.updateTargetClosed(instance.plasmaVault, false);
        assertFalse(accessManager.isTargetClosed(instance.plasmaVault), "guardian reopened the vault");
    }

    function testShouldCreateVaultWithCorrectWithdrawWindow() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // given
        uint256 withdrawWindow = 123;

        vm.startPrank(maintenanceManager);
        fusionFactory.updateWithdrawWindowInSeconds(withdrawWindow);
        vm.stopPrank();

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        WithdrawManager withdrawManager = WithdrawManager(instance.withdrawManager);
        assertEq(withdrawManager.getWithdrawWindow(), withdrawWindow);
    }

    function testShouldCloneVaultWithCorrectWithdrawWindow() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // given
        uint256 withdrawWindow = 123;

        vm.startPrank(maintenanceManager);
        fusionFactory.updateWithdrawWindowInSeconds(withdrawWindow);
        vm.stopPrank();

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        WithdrawManager withdrawManager = WithdrawManager(instance.withdrawManager);
        assertEq(withdrawManager.getWithdrawWindow(), withdrawWindow);
    }

    function testShouldCreateVaultWithCorrectVestingPeriod() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        // given
        uint256 vestingPeriod = 123;

        vm.startPrank(maintenanceManager);
        fusionFactory.updateVestingPeriodInSeconds(vestingPeriod);
        vm.stopPrank();

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        RewardsClaimManager rewardsClaimManager = RewardsClaimManager(instance.rewardsManager);
        assertEq(rewardsClaimManager.getVestingData().vestingTime, vestingPeriod);
    }

    function testShouldCloneVaultWithCorrectVestingPeriod() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        // given
        uint256 vestingPeriod = 123;

        vm.startPrank(maintenanceManager);
        fusionFactory.updateVestingPeriodInSeconds(vestingPeriod);
        vm.stopPrank();

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        RewardsClaimManager rewardsClaimManager = RewardsClaimManager(instance.rewardsManager);
        assertEq(rewardsClaimManager.getVestingData().vestingTime, vestingPeriod);
    }

    function testShouldCreateVaultWithCorrectPlasmaVaultBase() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        PlasmaVault plasmaVault = PlasmaVault(instance.plasmaVault);
        assertEq(plasmaVault.PLASMA_VAULT_BASE(), plasmaVaultBase);
    }

    function testShouldCloneVaultWithCorrectPlasmaVaultBase() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        PlasmaVault plasmaVault = PlasmaVault(instance.plasmaVault);
        assertEq(plasmaVault.PLASMA_VAULT_BASE(), plasmaVaultBase);
    }

    function testShouldCreateVaultWithCorrectPlasmaVaultOnWithdrawManager() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        WithdrawManager withdrawManager = WithdrawManager(instance.withdrawManager);
        assertEq(withdrawManager.getPlasmaVaultAddress(), instance.plasmaVault);
    }

    function testShouldCloneVaultWithCorrectPlasmaVaultOnWithdrawManager() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        WithdrawManager withdrawManager = WithdrawManager(instance.withdrawManager);
        assertEq(withdrawManager.getPlasmaVaultAddress(), instance.plasmaVault);
    }

    function testShouldCreateVaultWithCorrectRewardsClaimManager() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);

        assertEq(governanceVault.getRewardsClaimManagerAddress(), instance.rewardsManager);
    }

    function testShouldCloneVaultWithCorrectRewardsClaimManager() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);

        assertEq(governanceVault.getRewardsClaimManagerAddress(), instance.rewardsManager);
    }

    function testShouldCreateVaultWithCorrectBurnRequestFeeFuse() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);

        assertEq(
            governanceVault.isBalanceFuseSupported(IporFusionMarkets.ZERO_BALANCE_MARKET, burnRequestFeeBalanceFuse),
            true
        );

        address[] memory fuses = governanceVault.getFuses();

        for (uint256 i = 0; i < fuses.length; i++) {
            if (fuses[i] == burnRequestFeeFuse) {
                return;
            }
        }

        fail();
    }

    function testShouldCloneVaultWithCorrectBurnRequestFeeFuse() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);

        assertEq(
            governanceVault.isBalanceFuseSupported(IporFusionMarkets.ZERO_BALANCE_MARKET, burnRequestFeeBalanceFuse),
            true
        );

        address[] memory fuses = governanceVault.getFuses();

        for (uint256 i = 0; i < fuses.length; i++) {
            if (fuses[i] == burnRequestFeeFuse) {
                return;
            }
        }

        fail();
    }

    function testShouldUpgradeFusionFactory() public {
        // given
        FusionFactory newImplementation = new FusionFactory();
        uint256 redemptionDelay = 1 seconds;

        // when
        vm.startPrank(owner);
        fusionFactory.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        // then
        // Verify that the contract still works by creating a new instance
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        assertEq(instance.assetName, "Test Asset");
        assertEq(instance.assetSymbol, "TEST");
        assertEq(instance.underlyingToken, address(underlyingToken));
        assertEq(instance.initialOwner, owner);
        assertEq(instance.plasmaVaultBase, plasmaVaultBase);

        // Verify that all components are properly initialized
        assertTrue(instance.accessManager != address(0));
        assertTrue(instance.withdrawManager != address(0));
        assertTrue(instance.priceManager != address(0));
        assertTrue(instance.plasmaVault != address(0));
        assertTrue(instance.rewardsManager != address(0));
        assertTrue(instance.contextManager != address(0));
        assertTrue(instance.feeManager != address(0));
    }

    function testShouldRevertUpgradeWhenNotOwner() public {
        // given
        FusionFactory newImplementation = new FusionFactory();
        address nonOwner = address(0x123);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                nonOwner,
                newImplementation.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.startPrank(nonOwner);
        fusionFactory.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();
    }

    function testShouldCreateVaultAndHaveCorrectPriceManagerOnVault() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        IPlasmaVaultGovernance plasmaVaultGovernance = IPlasmaVaultGovernance(instance.plasmaVault);
        assertEq(plasmaVaultGovernance.getPriceOracleMiddleware(), instance.priceManager);
    }

    function testShouldCloneVaultAndHaveCorrectPriceManagerOnVault() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        IPlasmaVaultGovernance plasmaVaultGovernance = IPlasmaVaultGovernance(instance.plasmaVault);
        assertEq(plasmaVaultGovernance.getPriceOracleMiddleware(), instance.priceManager);
    }

    function testShouldAllowDepositAfterVaultCreation() public {
        // given
        uint256 depositAmount = 1000 * 1e18; // 1000 tokens
        address depositor = address(0x123);
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        vm.startPrank(depositor);
        underlyingToken.mint(depositor, depositAmount);
        underlyingToken.approve(instance.plasmaVault, depositAmount);

        // Add depositor to whitelist
        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        vm.stopPrank();

        vm.stopPrank();
        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        vm.startPrank(depositor);
        PlasmaVault(instance.plasmaVault).deposit(depositAmount, depositor);
        vm.stopPrank();

        // then
        assertEq(underlyingToken.balanceOf(instance.plasmaVault), depositAmount);
        assertEq(PlasmaVault(instance.plasmaVault).balanceOf(depositor), depositAmount * 100);
    }

    function testShouldAllowDepositAfterVaultCloning() public {
        // given
        uint256 depositAmount = 1000 * 1e18; // 1000 tokens
        address depositor = address(0x123);
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        vm.startPrank(depositor);
        underlyingToken.mint(depositor, depositAmount);
        underlyingToken.approve(instance.plasmaVault, depositAmount);

        // Add depositor to whitelist
        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        vm.stopPrank();

        vm.stopPrank();
        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        vm.startPrank(depositor);
        PlasmaVault(instance.plasmaVault).deposit(depositAmount, depositor);
        vm.stopPrank();

        // then
        assertEq(underlyingToken.balanceOf(instance.plasmaVault), depositAmount);
        assertEq(PlasmaVault(instance.plasmaVault).balanceOf(depositor), depositAmount * 100);
    }

    function testShouldWithdrawAfterVaultCreation() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        uint256 depositAmount = 1000 * 1e18; // 1000 tokens
        address depositor = address(0x123);

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // Setup - mint tokens, approve, and add to whitelist
        underlyingToken.mint(depositor, depositAmount);

        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        // Deposit tokens
        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, depositAmount);
        PlasmaVault(instance.plasmaVault).deposit(depositAmount, depositor);

        vm.warp(block.timestamp + 1);

        // Verify deposit was successful
        uint256 initialShareBalance = PlasmaVault(instance.plasmaVault).balanceOf(depositor);
        assertEq(initialShareBalance, depositAmount * 100); // 100 is the conversion rate

        // Direct redeem (instead of request withdraw)
        uint256 redeemAmount = initialShareBalance / 2; // Redeem half the shares
        uint256 initialTokenBalance = underlyingToken.balanceOf(depositor);

        // Perform redeem
        PlasmaVault(instance.plasmaVault).redeem(redeemAmount, depositor, depositor);
        vm.stopPrank();

        // then
        // Verify redemption was successful
        uint256 finalShareBalance = PlasmaVault(instance.plasmaVault).balanceOf(depositor);
        uint256 finalTokenBalance = underlyingToken.balanceOf(depositor);

        // Share balance should be reduced
        assertEq(finalShareBalance, initialShareBalance - redeemAmount);
    }

    function testShouldWithdrawAfterVaultCloning() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        uint256 depositAmount = 1000 * 1e18; // 1000 tokens
        address depositor = address(0x123);

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // Setup - mint tokens, approve, and add to whitelist
        underlyingToken.mint(depositor, depositAmount);

        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        // Deposit tokens
        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, depositAmount);
        PlasmaVault(instance.plasmaVault).deposit(depositAmount, depositor);

        vm.warp(block.timestamp + 1);

        // Verify deposit was successful
        uint256 initialShareBalance = PlasmaVault(instance.plasmaVault).balanceOf(depositor);
        assertEq(initialShareBalance, depositAmount * 100); // 100 is the conversion rate

        // Direct redeem (instead of request withdraw)
        uint256 redeemAmount = initialShareBalance / 2; // Redeem half the shares
        uint256 initialTokenBalance = underlyingToken.balanceOf(depositor);

        // Perform redeem
        PlasmaVault(instance.plasmaVault).redeem(redeemAmount, depositor, depositor);
        vm.stopPrank();

        // then
        // Verify redemption was successful
        uint256 finalShareBalance = PlasmaVault(instance.plasmaVault).balanceOf(depositor);
        uint256 finalTokenBalance = underlyingToken.balanceOf(depositor);

        // Share balance should be reduced
        assertEq(finalShareBalance, initialShareBalance - redeemAmount);
    }

    function testShouldDAOBeConfiguredAfterVaultCreation() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        address customFeeRecipient = address(0x123);
        uint256 customManagementFee = 100;
        uint256 customPerformanceFee = 100;

        // Create a custom fee package
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](3);
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
        packages[2] = FusionFactoryStorageLib.FeePackage({
            managementFee: customManagementFee,
            performanceFee: customPerformanceFee,
            feeRecipient: customFeeRecipient
        });

        vm.startPrank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

        // when - use fee package index 2 which has custom fees
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            2
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), customManagementFee);
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), customPerformanceFee);
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), customFeeRecipient);
    }

    function testShouldDAOBeConfiguredAfterVaultClone() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        address customFeeRecipient = address(0x123);
        uint256 customManagementFee = 100;
        uint256 customPerformanceFee = 100;

        // Create a custom fee package
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](3);
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
        packages[2] = FusionFactoryStorageLib.FeePackage({
            managementFee: customManagementFee,
            performanceFee: customPerformanceFee,
            feeRecipient: customFeeRecipient
        });

        vm.startPrank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

        // when - use fee package index 2 which has custom fees
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            2
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), customManagementFee);
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), customPerformanceFee);
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), customFeeRecipient);
    }

    function testShouldContainAppropriateTechnicalRolesAfterVaultCreation() public {
        //given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        (bool hasPlasmaVaultRole, ) = accessManager.hasRole(Roles.TECH_PLASMA_VAULT_ROLE, instance.plasmaVault);
        assertTrue(hasPlasmaVaultRole, "PlasmaVault role not found TECH_PLASMA_VAULT_ROLE");

        (bool hasContextManagerRole, ) = accessManager.hasRole(
            Roles.TECH_CONTEXT_MANAGER_ROLE,
            instance.contextManager
        );
        assertTrue(hasContextManagerRole, "ContextManager role not found TECH_CONTEXT_MANAGER_ROLE");

        (bool hasWithdrawManagerRole, ) = accessManager.hasRole(
            Roles.TECH_WITHDRAW_MANAGER_ROLE,
            instance.withdrawManager
        );
        assertTrue(hasWithdrawManagerRole, "WithdrawManager role not found TECH_WITHDRAW_MANAGER_ROLE");

        (bool hasVaultTransferSharesRole, ) = accessManager.hasRole(
            Roles.TECH_VAULT_TRANSFER_SHARES_ROLE,
            instance.feeManager
        );
        assertTrue(hasVaultTransferSharesRole, "VaultTransferShares role not found TECH_VAULT_TRANSFER_SHARES_ROLE");

        (bool hasPerformanceFeeManagerRole, ) = accessManager.hasRole(
            Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
            instance.feeManager
        );
        assertTrue(
            hasPerformanceFeeManagerRole,
            "PerformanceFeeManager role not found TECH_PERFORMANCE_FEE_MANAGER_ROLE"
        );

        (bool hasRewardsClaimManagerRole, ) = accessManager.hasRole(
            Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            instance.rewardsManager
        );
        assertTrue(hasRewardsClaimManagerRole, "RewardsClaimManager role not found TECH_REWARDS_CLAIM_MANAGER_ROLE");
    }

    function testShouldContainAppropriateTechnicalRolesAfterVaultClone() public {
        //given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        (bool hasPlasmaVaultRole, ) = accessManager.hasRole(Roles.TECH_PLASMA_VAULT_ROLE, instance.plasmaVault);
        assertTrue(hasPlasmaVaultRole, "PlasmaVault role not found TECH_PLASMA_VAULT_ROLE");

        (bool hasContextManagerRole, ) = accessManager.hasRole(
            Roles.TECH_CONTEXT_MANAGER_ROLE,
            instance.contextManager
        );
        assertTrue(hasContextManagerRole, "ContextManager role not found TECH_CONTEXT_MANAGER_ROLE");

        (bool hasWithdrawManagerRole, ) = accessManager.hasRole(
            Roles.TECH_WITHDRAW_MANAGER_ROLE,
            instance.withdrawManager
        );
        assertTrue(hasWithdrawManagerRole, "WithdrawManager role not found TECH_WITHDRAW_MANAGER_ROLE");

        (bool hasVaultTransferSharesRole, ) = accessManager.hasRole(
            Roles.TECH_VAULT_TRANSFER_SHARES_ROLE,
            instance.feeManager
        );
        assertTrue(hasVaultTransferSharesRole, "VaultTransferShares role not found TECH_VAULT_TRANSFER_SHARES_ROLE");

        (bool hasPerformanceFeeManagerRole, ) = accessManager.hasRole(
            Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
            instance.feeManager
        );
        assertTrue(
            hasPerformanceFeeManagerRole,
            "PerformanceFeeManager role not found TECH_PERFORMANCE_FEE_MANAGER_ROLE"
        );

        (bool hasRewardsClaimManagerRole, ) = accessManager.hasRole(
            Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            instance.rewardsManager
        );
        assertTrue(hasRewardsClaimManagerRole, "RewardsClaimManager role not found TECH_REWARDS_CLAIM_MANAGER_ROLE");
    }

    function testShouldCreateVaultWithCorrectContextManagerApprovedTargets() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        // Verify that the context manager has approved the correct targets
        address[] memory approvedTargets = ContextManager(instance.contextManager).getApprovedTargets();

        // Should have exactly 5 approved targets
        assertEq(approvedTargets.length, 5);

        // Verify each target is approved
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.plasmaVault));
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.withdrawManager));
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.priceManager));
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.rewardsManager));
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.feeManager));

        // Verify the approved targets array contains the correct addresses
        bool foundPlasmaVault = false;
        bool foundWithdrawManager = false;
        bool foundPriceManager = false;
        bool foundRewardsManager = false;
        bool foundFeeManager = false;
        for (uint256 i = 0; i < approvedTargets.length; i++) {
            if (approvedTargets[i] == instance.plasmaVault) {
                foundPlasmaVault = true;
            } else if (approvedTargets[i] == instance.withdrawManager) {
                foundWithdrawManager = true;
            } else if (approvedTargets[i] == instance.priceManager) {
                foundPriceManager = true;
            } else if (approvedTargets[i] == instance.rewardsManager) {
                foundRewardsManager = true;
            } else if (approvedTargets[i] == instance.feeManager) {
                foundFeeManager = true;
            }
        }

        assertTrue(foundPlasmaVault, "PlasmaVault should be in approved targets");
        assertTrue(foundWithdrawManager, "WithdrawManager should be in approved targets");
        assertTrue(foundPriceManager, "PriceManager should be in approved targets");
        assertTrue(foundRewardsManager, "RewardsManager should be in approved targets");
        assertTrue(foundFeeManager, "FeeManager should be in approved targets");
    }

    function testShouldCloneVaultWithCorrectContextManagerApprovedTargets() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        // Verify that the context manager has approved the correct targets
        address[] memory approvedTargets = ContextManager(instance.contextManager).getApprovedTargets();

        // Should have exactly 5 approved targets
        assertEq(approvedTargets.length, 5);

        // Verify each target is approved
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.plasmaVault));
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.withdrawManager));
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.priceManager));
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.rewardsManager));
        assertTrue(ContextManager(instance.contextManager).isTargetApproved(instance.feeManager));

        // Verify the approved targets array contains the correct addresses
        bool foundPlasmaVault = false;
        bool foundWithdrawManager = false;
        bool foundPriceManager = false;
        bool foundRewardsManager = false;
        bool foundFeeManager = false;
        for (uint256 i = 0; i < approvedTargets.length; i++) {
            if (approvedTargets[i] == instance.plasmaVault) {
                foundPlasmaVault = true;
            } else if (approvedTargets[i] == instance.withdrawManager) {
                foundWithdrawManager = true;
            } else if (approvedTargets[i] == instance.priceManager) {
                foundPriceManager = true;
            } else if (approvedTargets[i] == instance.rewardsManager) {
                foundRewardsManager = true;
            } else if (approvedTargets[i] == instance.feeManager) {
                foundFeeManager = true;
            }
        }

        assertTrue(foundPlasmaVault, "PlasmaVault should be in approved targets");
        assertTrue(foundWithdrawManager, "WithdrawManager should be in approved targets");
        assertTrue(foundPriceManager, "PriceManager should be in approved targets");
        assertTrue(foundRewardsManager, "RewardsManager should be in approved targets");
        assertTrue(foundFeeManager, "FeeManager should be in approved targets");
    }

    function testShouldCreateTwoClonedVaultsWithUniqueAddresses() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when - create first vault using clone
        FusionFactoryLogicLib.FusionInstance memory instance1 = fusionFactory.clone(
            "Test Asset 1",
            "TEST1",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // when - create second vault using clone
        FusionFactoryLogicLib.FusionInstance memory instance2 = fusionFactory.clone(
            "Test Asset 2",
            "TEST2",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then - verify all addresses are different from each other
        assertTrue(instance1.plasmaVault != instance2.plasmaVault, "PlasmaVault addresses should be different");
        assertTrue(instance1.accessManager != instance2.accessManager, "AccessManager addresses should be different");
        assertTrue(instance1.feeManager != instance2.feeManager, "FeeManager addresses should be different");
        assertTrue(
            instance1.rewardsManager != instance2.rewardsManager,
            "RewardsManager addresses should be different"
        );
        assertTrue(
            instance1.withdrawManager != instance2.withdrawManager,
            "WithdrawManager addresses should be different"
        );
        assertTrue(
            instance1.contextManager != instance2.contextManager,
            "ContextManager addresses should be different"
        );
        assertTrue(instance1.priceManager != instance2.priceManager, "PriceManager addresses should be different");
        assertTrue(instance1.feeManager != instance2.feeManager, "FeeManager addresses should be different");

        // then - verify fee account addresses are different
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData1 = IPlasmaVaultGovernance(
            instance1.plasmaVault
        ).getPerformanceFeeData();
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData2 = IPlasmaVaultGovernance(
            instance2.plasmaVault
        ).getPerformanceFeeData();
        assertTrue(
            performanceFeeData1.feeAccount != performanceFeeData2.feeAccount,
            "Performance fee account addresses should be different"
        );

        PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData1 = IPlasmaVaultGovernance(
            instance1.plasmaVault
        ).getManagementFeeData();
        PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData2 = IPlasmaVaultGovernance(
            instance2.plasmaVault
        ).getManagementFeeData();
        assertTrue(
            managementFeeData1.feeAccount != managementFeeData2.feeAccount,
            "Management fee account addresses should be different"
        );

        // then - verify FeeManager configuration
        FeeManager feeManager1 = FeeManager(instance1.feeManager);
        FeeManager feeManager2 = FeeManager(instance2.feeManager);

        // DAO fee recipient should be the same for both instances
        assertEq(
            feeManager1.getIporDaoFeeRecipientAddress(),
            feeManager2.getIporDaoFeeRecipientAddress(),
            "DAO fee recipient addresses should be the same"
        );

        // Fee accounts should be different between instances
        assertTrue(
            feeManager1.PERFORMANCE_FEE_ACCOUNT() != feeManager2.PERFORMANCE_FEE_ACCOUNT(),
            "Performance fee account addresses should be different"
        );
        assertTrue(
            feeManager1.MANAGEMENT_FEE_ACCOUNT() != feeManager2.MANAGEMENT_FEE_ACCOUNT(),
            "Management fee account addresses should be different"
        );

        // Plasma vault addresses should be different between instances
        assertTrue(
            feeManager1.PLASMA_VAULT() != feeManager2.PLASMA_VAULT(),
            "Plasma vault addresses should be different"
        );

        // DAO fees should be greater than zero
        assertTrue(feeManager1.IPOR_DAO_MANAGEMENT_FEE() > 0, "DAO management fee should be greater than zero");
        assertTrue(feeManager1.IPOR_DAO_PERFORMANCE_FEE() > 0, "DAO performance fee should be greater than zero");
        assertTrue(feeManager2.IPOR_DAO_MANAGEMENT_FEE() > 0, "DAO management fee should be greater than zero");
        assertTrue(feeManager2.IPOR_DAO_PERFORMANCE_FEE() > 0, "DAO performance fee should be greater than zero");

        // DAO fees should have the expected values (set in factory setup)
        assertEq(feeManager1.IPOR_DAO_MANAGEMENT_FEE(), 333, "DAO management fee should be 333");
        assertEq(feeManager1.IPOR_DAO_PERFORMANCE_FEE(), 777, "DAO performance fee should be 777");
        assertEq(feeManager2.IPOR_DAO_MANAGEMENT_FEE(), 333, "DAO management fee should be 333");
        assertEq(feeManager2.IPOR_DAO_PERFORMANCE_FEE(), 777, "DAO performance fee should be 777");

        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = fusionFactory.getBaseAddresses();

        // then - verify all addresses are different from base addresses
        assertTrue(
            instance1.plasmaVault != baseAddresses.plasmaVaultCoreBase,
            "Instance1 PlasmaVault should be different from base"
        );
        assertTrue(
            instance1.accessManager != baseAddresses.accessManagerBase,
            "Instance1 AccessManager should be different from base"
        );
        assertTrue(
            instance1.rewardsManager != baseAddresses.rewardsManagerBase,
            "Instance1 RewardsManager should be different from base"
        );
        assertTrue(
            instance1.withdrawManager != baseAddresses.withdrawManagerBase,
            "Instance1 WithdrawManager should be different from base"
        );
        assertTrue(
            instance1.contextManager != baseAddresses.contextManagerBase,
            "Instance1 ContextManager should be different from base"
        );
        assertTrue(
            instance1.priceManager != baseAddresses.priceManagerBase,
            "Instance1 PriceManager should be different from base"
        );

        assertTrue(
            instance2.plasmaVault != baseAddresses.plasmaVaultCoreBase,
            "Instance2 PlasmaVault should be different from base"
        );
        assertTrue(
            instance2.accessManager != baseAddresses.accessManagerBase,
            "Instance2 AccessManager should be different from base"
        );
        assertTrue(
            instance2.rewardsManager != baseAddresses.rewardsManagerBase,
            "Instance2 RewardsManager should be different from base"
        );
        assertTrue(
            instance2.withdrawManager != baseAddresses.withdrawManagerBase,
            "Instance2 WithdrawManager should be different from base"
        );
        assertTrue(
            instance2.contextManager != baseAddresses.contextManagerBase,
            "Instance2 ContextManager should be different from base"
        );
        assertTrue(
            instance2.priceManager != baseAddresses.priceManagerBase,
            "Instance2 PriceManager should be different from base"
        );

        // then - verify all addresses are non-zero
        assertTrue(instance1.plasmaVault != address(0), "Instance1 PlasmaVault should not be zero address");
        assertTrue(instance1.accessManager != address(0), "Instance1 AccessManager should not be zero address");
        assertTrue(instance1.feeManager != address(0), "Instance1 FeeManager should not be zero address");
        assertTrue(instance1.rewardsManager != address(0), "Instance1 RewardsManager should not be zero address");
        assertTrue(instance1.withdrawManager != address(0), "Instance1 WithdrawManager should not be zero address");
        assertTrue(instance1.contextManager != address(0), "Instance1 ContextManager should not be zero address");
        assertTrue(instance1.priceManager != address(0), "Instance1 PriceManager should not be zero address");

        assertTrue(instance2.plasmaVault != address(0), "Instance2 PlasmaVault should not be zero address");
        assertTrue(instance2.accessManager != address(0), "Instance2 AccessManager should not be zero address");
        assertTrue(instance2.feeManager != address(0), "Instance2 FeeManager should not be zero address");
        assertTrue(instance2.rewardsManager != address(0), "Instance2 RewardsManager should not be zero address");
        assertTrue(instance2.withdrawManager != address(0), "Instance2 WithdrawManager should not be zero address");
        assertTrue(instance2.contextManager != address(0), "Instance2 ContextManager should not be zero address");
        assertTrue(instance2.priceManager != address(0), "Instance2 PriceManager should not be zero address");

        // then - verify plasmaVaultBase is the same for both instances (should reference the same base)
        assertEq(
            instance1.plasmaVaultBase,
            instance2.plasmaVaultBase,
            "Both instances should reference the same plasmaVaultBase"
        );
        assertEq(instance1.plasmaVaultBase, plasmaVaultBase, "plasmaVaultBase should match the setup value");
    }

    // ======================= DAO Fee Packages Tests =======================

    function testShouldSetDaoFeePackages() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](3);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 200,
            feeRecipient: address(0x111)
        });
        packages[1] = FusionFactoryStorageLib.FeePackage({
            managementFee: 300,
            performanceFee: 400,
            feeRecipient: address(0x222)
        });
        packages[2] = FusionFactoryStorageLib.FeePackage({
            managementFee: 500,
            performanceFee: 600,
            feeRecipient: address(0x333)
        });

        // when
        vm.startPrank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getDaoFeePackagesLength(), 3, "Should have 3 packages");

        FusionFactoryStorageLib.FeePackage memory pkg0 = fusionFactory.getDaoFeePackage(0);
        assertEq(pkg0.managementFee, 100);
        assertEq(pkg0.performanceFee, 200);
        assertEq(pkg0.feeRecipient, address(0x111));

        FusionFactoryStorageLib.FeePackage memory pkg1 = fusionFactory.getDaoFeePackage(1);
        assertEq(pkg1.managementFee, 300);
        assertEq(pkg1.performanceFee, 400);
        assertEq(pkg1.feeRecipient, address(0x222));

        FusionFactoryStorageLib.FeePackage memory pkg2 = fusionFactory.getDaoFeePackage(2);
        assertEq(pkg2.managementFee, 500);
        assertEq(pkg2.performanceFee, 600);
        assertEq(pkg2.feeRecipient, address(0x333));
    }

    function testShouldGetAllDaoFeePackages() public {
        // given - packages set in setUp

        // when
        FusionFactoryStorageLib.FeePackage[] memory packages = fusionFactory.getDaoFeePackages();

        // then
        assertEq(packages.length, 2, "Should have 2 packages from setUp");
        assertEq(packages[0].managementFee, 333);
        assertEq(packages[0].performanceFee, 777);
        assertEq(packages[1].managementFee, 100);
        assertEq(packages[1].performanceFee, 200);
    }

    function testShouldRevertWhenSetDaoFeePackagesWithEmptyArray() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](0);

        // when / then
        vm.startPrank(daoFeeManager);
        vm.expectRevert(FusionFactoryLib.DaoFeePackagesArrayEmpty.selector);
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();
    }

    function testShouldRevertWhenSetDaoFeePackagesWithInvalidManagementFee() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 10001, // > 10000
            performanceFee: 500,
            feeRecipient: address(0x111)
        });

        // when / then
        vm.startPrank(daoFeeManager);
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.FeeExceedsMaximum.selector, 10001, 10000));
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();
    }

    function testShouldRevertWhenSetDaoFeePackagesWithInvalidPerformanceFee() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 500,
            performanceFee: 10001, // > 10000
            feeRecipient: address(0x111)
        });

        // when / then
        vm.startPrank(daoFeeManager);
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.FeeExceedsMaximum.selector, 10001, 10000));
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();
    }

    function testShouldRevertWhenSetDaoFeePackagesWithZeroFeeRecipient() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 500,
            performanceFee: 500,
            feeRecipient: address(0)
        });

        // when / then
        vm.startPrank(daoFeeManager);
        vm.expectRevert(FusionFactoryLib.FeeRecipientZeroAddress.selector);
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();
    }

    function testShouldRevertWhenGetDaoFeePackageWithInvalidIndex() public {
        // given - 2 packages set in setUp

        // when / then
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.DaoFeePackageIndexOutOfBounds.selector, 5, 2));
        fusionFactory.getDaoFeePackage(5);
    }

    function testShouldRevertWhenCreateWithInvalidDaoFeePackageIndex() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when / then
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLib.DaoFeePackageIndexOutOfBounds.selector, 10, 2));
        fusionFactory.clone("Test Asset", "TEST", address(underlyingToken), redemptionDelay, owner, 10);
    }

    function testShouldRevertWhenCloneWithInvalidDaoFeePackageIndex() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when / then
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLogicLib.DaoFeePackageIndexOutOfBounds.selector, 10, 2));
        fusionFactory.clone("Test Asset", "TEST", address(underlyingToken), redemptionDelay, owner, 10);
    }

    function testShouldCreateVaultWithDifferentDaoFeePackages() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when - create vault with package 0 (333, 777)
        FusionFactoryLogicLib.FusionInstance memory instance0 = fusionFactory.clone(
            "Test Asset 0",
            "TEST0",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // when - create vault with package 1 (100, 200)
        FusionFactoryLogicLib.FusionInstance memory instance1 = fusionFactory.clone(
            "Test Asset 1",
            "TEST1",
            address(underlyingToken),
            redemptionDelay,
            owner,
            1
        );

        // then - verify fees are different
        FeeManager feeManager0 = FeeManager(instance0.feeManager);
        FeeManager feeManager1 = FeeManager(instance1.feeManager);

        assertEq(feeManager0.IPOR_DAO_MANAGEMENT_FEE(), 333, "Package 0 management fee");
        assertEq(feeManager0.IPOR_DAO_PERFORMANCE_FEE(), 777, "Package 0 performance fee");
        assertEq(feeManager0.getIporDaoFeeRecipientAddress(), daoFeeRecipient, "Package 0 recipient");

        assertEq(feeManager1.IPOR_DAO_MANAGEMENT_FEE(), 100, "Package 1 management fee");
        assertEq(feeManager1.IPOR_DAO_PERFORMANCE_FEE(), 200, "Package 1 performance fee");
        assertEq(feeManager1.getIporDaoFeeRecipientAddress(), address(0x999), "Package 1 recipient");
    }

    function testShouldRevertSetDaoFeePackagesWhenNotDaoFeeManager() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 200,
            feeRecipient: address(0x111)
        });

        // when / then
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();
    }

    function testShouldEmitDaoFeePackagesUpdatedEvent() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 100,
            performanceFee: 200,
            feeRecipient: address(0x111)
        });

        // when / then
        vm.startPrank(daoFeeManager);
        vm.expectEmit(false, true, false, false);
        emit FusionFactory.DaoFeePackagesUpdated(packages, daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();
    }

    function testShouldReplaceDaoFeePackagesArray() public {
        // given - 2 packages set in setUp
        assertEq(fusionFactory.getDaoFeePackagesLength(), 2, "Should start with 2 packages");

        FusionFactoryStorageLib.FeePackage[] memory newPackages = new FusionFactoryStorageLib.FeePackage[](1);
        newPackages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 999,
            performanceFee: 888,
            feeRecipient: address(0x444)
        });

        // when
        vm.startPrank(daoFeeManager);
        fusionFactory.setDaoFeePackages(newPackages);
        vm.stopPrank();

        // then - array should be replaced, not appended
        assertEq(fusionFactory.getDaoFeePackagesLength(), 1, "Should have 1 package after replacement");
        FusionFactoryStorageLib.FeePackage memory pkg = fusionFactory.getDaoFeePackage(0);
        assertEq(pkg.managementFee, 999);
        assertEq(pkg.performanceFee, 888);
        assertEq(pkg.feeRecipient, address(0x444));
    }

    function testShouldAllowZeroFees() public {
        // given
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 0,
            performanceFee: 0,
            feeRecipient: address(0x111)
        });

        // when
        vm.startPrank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

        // then
        uint256 redemptionDelay = 1 seconds;
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 0, "Zero management fee allowed");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 0, "Zero performance fee allowed");
    }

    function testShouldAllowMaximumDaoFees() public {
        // given - PlasmaVaultLib limits:
        // - MANAGEMENT_MAX_FEE_IN_PERCENTAGE = 500 (5%)
        // - PERFORMANCE_MAX_FEE_IN_PERCENTAGE = 5000 (50%)
        // Note: The factory validates up to 10000 (100%), but PlasmaVault has stricter limits
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 500, // 5% - max allowed by PlasmaVault for management
            performanceFee: 5000, // 50% - max allowed by PlasmaVault for performance
            feeRecipient: address(0x111)
        });

        // when
        vm.startPrank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

        // then
        uint256 redemptionDelay = 1 seconds;
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), 500, "Max DAO management fee allowed");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), 5000, "Max DAO performance fee allowed");
    }

    // ======================= Fusion Vault Registry Tests =======================

    function testShouldRegisterPlasmaVaultWhenClone() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        assertTrue(fusionFactory.isFusionVault(instance.plasmaVault), "Cloned PlasmaVault should be registered");
        assertEq(
            vm.load(address(fusionFactory), _fusionVaultMappingSlot(instance.plasmaVault)),
            bytes32(uint256(1)),
            "Raw registry slot should be set on the factory proxy"
        );
    }

    function testShouldRegisterPlasmaVaultWhenCloneSupervised() public {
        // given
        uint256 redemptionDelay = 1 seconds;

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneSupervised(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        vm.stopPrank();

        // then
        assertTrue(
            fusionFactory.isFusionVault(instance.plasmaVault),
            "Supervised cloned PlasmaVault should be registered"
        );
        assertEq(
            vm.load(address(fusionFactory), _fusionVaultMappingSlot(instance.plasmaVault)),
            bytes32(uint256(1)),
            "Raw registry slot should be set on the factory proxy"
        );
    }

    function testShouldNotRegisterPlasmaVaultClonedDirectlyByPlasmaVaultFactory() public {
        // given
        FusionFactoryStorageLib.FactoryAddresses memory currentFactoryAddresses = fusionFactory.getFactoryAddresses();
        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = fusionFactory.getBaseAddresses();

        // when
        address directPlasmaVault = PlasmaVaultFactory(currentFactoryAddresses.plasmaVaultFactory).clone(
            baseAddresses.plasmaVaultCoreBase,
            1,
            PlasmaVaultInitData({
                assetName: "Direct Asset",
                assetSymbol: "DIRECT",
                underlyingToken: address(underlyingToken),
                priceOracleMiddleware: priceOracleMiddleware,
                feeConfig: FeeConfig({
                    feeFactory: currentFactoryAddresses.feeManagerFactory,
                    iporDaoManagementFee: 111,
                    iporDaoPerformanceFee: 222,
                    iporDaoFeeRecipientAddress: address(this)
                }),
                accessManager: baseAddresses.accessManagerBase,
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: baseAddresses.withdrawManagerBase,
                plasmaVaultVotesPlugin: address(0)
            })
        );

        // then
        assertTrue(directPlasmaVault.code.length > 0, "Direct PlasmaVault should be deployed");
        assertFalse(
            fusionFactory.isFusionVault(directPlasmaVault),
            "PlasmaVault cloned directly by PlasmaVaultFactory should not be registered"
        );
        assertEq(
            vm.load(address(fusionFactory), _fusionVaultMappingSlot(directPlasmaVault)),
            bytes32(0),
            "Raw registry slot should be empty for a direct PlasmaVaultFactory clone"
        );
    }

    function testShouldNotRegisterNonPlasmaVaultAddresses() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // when / then
        assertTrue(fusionFactory.isFusionVault(instance.plasmaVault), "Cloned PlasmaVault should be registered");
        assertFalse(fusionFactory.isFusionVault(address(0)), "Zero address should not be registered");
        assertFalse(fusionFactory.isFusionVault(makeAddr("eoa")), "EOA should not be registered");
        assertFalse(fusionFactory.isFusionVault(instance.accessManager), "AccessManager should not be registered");
        assertFalse(fusionFactory.isFusionVault(instance.withdrawManager), "WithdrawManager should not be registered");
        assertFalse(fusionFactory.isFusionVault(instance.priceManager), "PriceManager should not be registered");
        assertFalse(fusionFactory.isFusionVault(instance.rewardsManager), "RewardsManager should not be registered");
        assertFalse(fusionFactory.isFusionVault(instance.contextManager), "ContextManager should not be registered");
        assertFalse(fusionFactory.isFusionVault(instance.feeManager), "FeeManager should not be registered");
        assertFalse(
            fusionFactory.isFusionVault(fusionFactory.getBaseAddresses().plasmaVaultCoreBase),
            "PlasmaVault core base should not be registered"
        );
        assertFalse(fusionFactory.isFusionVault(address(fusionFactory)), "Factory proxy should not be registered");
    }

    function testShouldIsolateFusionVaultRegistryPerFactoryProxy() public {
        // given
        FusionFactory otherFusionFactory = _deployConfiguredFusionFactoryProxy();
        uint256 redemptionDelay = 1 seconds;

        // when
        FusionFactoryLogicLib.FusionInstance memory instanceA = fusionFactory.clone(
            "Test Asset A",
            "TESTA",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        FusionFactoryLogicLib.FusionInstance memory instanceB = otherFusionFactory.clone(
            "Test Asset B",
            "TESTB",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        assertEq(
            vm.load(address(otherFusionFactory), ERC1967Utils.IMPLEMENTATION_SLOT),
            vm.load(address(fusionFactory), ERC1967Utils.IMPLEMENTATION_SLOT),
            "Both proxies should share the same implementation"
        );
        assertTrue(fusionFactory.isFusionVault(instanceA.plasmaVault), "Vault A should be registered on proxy A");
        assertFalse(otherFusionFactory.isFusionVault(instanceA.plasmaVault), "Vault A should not be registered on B");
        assertTrue(otherFusionFactory.isFusionVault(instanceB.plasmaVault), "Vault B should be registered on proxy B");
        assertFalse(fusionFactory.isFusionVault(instanceB.plasmaVault), "Vault B should not be registered on A");

        assertEq(
            vm.load(address(fusionFactory), _fusionVaultMappingSlot(instanceA.plasmaVault)),
            bytes32(uint256(1)),
            "Raw slot for vault A should be set on proxy A"
        );
        assertEq(
            vm.load(address(otherFusionFactory), _fusionVaultMappingSlot(instanceA.plasmaVault)),
            bytes32(0),
            "Raw slot for vault A should be empty on proxy B"
        );
        assertEq(
            vm.load(address(otherFusionFactory), _fusionVaultMappingSlot(instanceB.plasmaVault)),
            bytes32(uint256(1)),
            "Raw slot for vault B should be set on proxy B"
        );
        assertEq(
            vm.load(address(fusionFactory), _fusionVaultMappingSlot(instanceB.plasmaVault)),
            bytes32(0),
            "Raw slot for vault B should be empty on proxy A"
        );
    }

    function testShouldKeepVersionAndIncrementIndexOncePerRegisteredClone() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        uint256 versionBefore = fusionFactory.getFusionFactoryVersion();
        uint256 indexBefore = fusionFactory.getFusionFactoryIndex();

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        assertEq(fusionFactory.getFusionFactoryVersion(), versionBefore, "Version should not change on clone");
        assertEq(instance.version, versionBefore, "Instance version should equal factory version");
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore + 1, "Index should increase exactly once");
        assertEq(instance.index, indexBefore + 1, "Instance index should equal the new factory index");

        // when
        vm.startPrank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory supervisedInstance = fusionFactory.cloneSupervised(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        vm.stopPrank();

        // then
        assertEq(
            fusionFactory.getFusionFactoryVersion(),
            versionBefore,
            "Version should not change on cloneSupervised"
        );
        assertEq(supervisedInstance.version, versionBefore, "Supervised instance version should equal factory version");
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore + 2, "Index should increase exactly once again");
        assertEq(supervisedInstance.index, indexBefore + 2, "Supervised instance index should equal the new index");
        assertTrue(fusionFactory.isFusionVault(instance.plasmaVault), "First vault should be registered");
        assertTrue(
            fusionFactory.isFusionVault(supervisedInstance.plasmaVault),
            "Supervised vault should be registered"
        );
    }

    function testShouldPreserveFusionVaultRegistryAndIndexAfterUpgrade() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        FusionFactoryLogicLib.FusionInstance memory instanceBefore = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        uint256 indexBefore = fusionFactory.getFusionFactoryIndex();
        uint256 versionBefore = fusionFactory.getFusionFactoryVersion();
        FusionFactory newImplementation = new FusionFactory();

        // when
        vm.startPrank(owner);
        fusionFactory.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        // then
        assertEq(
            vm.load(address(fusionFactory), ERC1967Utils.IMPLEMENTATION_SLOT),
            bytes32(uint256(uint160(address(newImplementation)))),
            "Proxy should point to the new implementation"
        );
        assertTrue(fusionFactory.isFusionVault(instanceBefore.plasmaVault), "Registry entry should survive upgrade");
        assertEq(
            vm.load(address(fusionFactory), _fusionVaultMappingSlot(instanceBefore.plasmaVault)),
            bytes32(uint256(1)),
            "Raw registry slot should survive upgrade"
        );
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore, "Index should survive upgrade");
        assertEq(fusionFactory.getFusionFactoryVersion(), versionBefore, "Version should survive upgrade");

        // when
        FusionFactoryLogicLib.FusionInstance memory instanceAfter = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );

        // then
        assertTrue(fusionFactory.isFusionVault(instanceAfter.plasmaVault), "Post-upgrade vault should be registered");
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore + 1, "Index should increase exactly once");
        assertEq(instanceAfter.index, indexBefore + 1, "Post-upgrade instance index should follow preserved index");
    }

    function testShouldEmitFusionInstanceCreatedWithUnchangedPayloadWhenClone() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        uint256 indexBefore = fusionFactory.getFusionFactoryIndex();
        bytes32 expectedEventSignature = keccak256(
            "FusionInstanceCreated(uint256,uint256,string,string,uint8,address,string,uint8,address,address,address,address)"
        );

        // when
        vm.recordLogs();
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(FusionFactoryLib.FusionInstanceCreated.selector, expectedEventSignature, "Event signature changed");

        FusionFactoryLogicLib.FusionInstance memory expected;
        expected.index = indexBefore + 1;
        expected.version = fusionFactory.getFusionFactoryVersion();
        expected.assetName = "Test Asset";
        expected.assetSymbol = "TEST";
        expected.assetDecimals = PlasmaVault(instance.plasmaVault).decimals();
        expected.underlyingToken = address(underlyingToken);
        expected.underlyingTokenSymbol = "TEST";
        expected.underlyingTokenDecimals = 18;
        expected.initialOwner = owner;
        expected.plasmaVault = instance.plasmaVault;
        expected.plasmaVaultBase = plasmaVaultBase;
        expected.feeManager = instance.feeManager;

        uint256 matchingLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == expectedEventSignature) {
                ++matchingLogs;
                assertEq(logs[i].emitter, address(fusionFactory), "Event should be emitted by the factory proxy");
                assertEq(logs[i].topics.length, 1, "Event should have no indexed parameters");
                assertEq(logs[i].data, _encodeFusionInstanceCreatedData(expected), "Event payload changed");
            }
        }
        assertEq(matchingLogs, 1, "FusionInstanceCreated should be emitted exactly once");
        assertTrue(fusionFactory.isFusionVault(instance.plasmaVault), "Cloned PlasmaVault should be registered");
    }

    function testShouldNotRegisterAnyAddressWhenCloneRevertsOnInvalidDaoFeePackageIndex() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        address plasmaVaultFactory = fusionFactory.getFactoryAddresses().plasmaVaultFactory;
        address predictedPlasmaVault = vm.computeCreateAddress(plasmaVaultFactory, vm.getNonce(plasmaVaultFactory));
        uint256 indexBefore = fusionFactory.getFusionFactoryIndex();

        // when
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLogicLib.DaoFeePackageIndexOutOfBounds.selector, 10, 2));
        fusionFactory.clone("Test Asset", "TEST", address(underlyingToken), redemptionDelay, owner, 10);

        // then
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore, "Index should not change on reverted clone");
        assertFalse(fusionFactory.isFusionVault(predictedPlasmaVault), "Reverted clone should not register a vault");
        assertEq(
            vm.load(address(fusionFactory), _fusionVaultMappingSlot(predictedPlasmaVault)),
            bytes32(0),
            "Raw registry slot should be empty after reverted clone"
        );

        // and the predicted address is the one a successful clone produces next
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        assertEq(instance.plasmaVault, predictedPlasmaVault, "Predicted PlasmaVault address mismatch");
        assertTrue(fusionFactory.isFusionVault(predictedPlasmaVault), "Successful clone should register the vault");
    }

    function testShouldNotRegisterPlasmaVaultWhenCloneRevertsAfterPlasmaVaultDeployment() public {
        // given
        uint256 redemptionDelay = 1 seconds;
        FusionFactoryStorageLib.FactoryAddresses memory currentFactoryAddresses = fusionFactory.getFactoryAddresses();
        address predictedPlasmaVault = vm.computeCreateAddress(
            currentFactoryAddresses.plasmaVaultFactory,
            vm.getNonce(currentFactoryAddresses.plasmaVaultFactory)
        );
        uint256 indexBefore = fusionFactory.getFusionFactoryIndex();
        // RewardsManagerFactory.clone runs after the PlasmaVault has been cloned and initialized
        vm.mockCallRevert(
            currentFactoryAddresses.rewardsManagerFactory,
            abi.encodeWithSelector(RewardsManagerFactory.clone.selector),
            bytes("REWARDS_MANAGER_CLONE_FAILED")
        );

        // when
        vm.expectRevert(bytes("REWARDS_MANAGER_CLONE_FAILED"));
        fusionFactory.clone("Test Asset", "TEST", address(underlyingToken), redemptionDelay, owner, 0);

        // then
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore, "Index should not change on reverted clone");
        assertFalse(fusionFactory.isFusionVault(predictedPlasmaVault), "Reverted clone should not register a vault");
        assertEq(
            vm.load(address(fusionFactory), _fusionVaultMappingSlot(predictedPlasmaVault)),
            bytes32(0),
            "Raw registry slot should be empty after reverted clone"
        );

        // and the predicted address is the one a successful clone produces next
        vm.clearMockedCalls();
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            redemptionDelay,
            owner,
            0
        );
        assertEq(instance.plasmaVault, predictedPlasmaVault, "Predicted PlasmaVault address mismatch");
        assertTrue(fusionFactory.isFusionVault(predictedPlasmaVault), "Successful clone should register the vault");
    }

    function _fusionVaultMappingSlot(address vault_) private pure returns (bytes32) {
        return keccak256(abi.encode(vault_, FUSION_VAULTS_SLOT));
    }

    function _encodeFusionInstanceCreatedData(
        FusionFactoryLogicLib.FusionInstance memory instance_
    ) private pure returns (bytes memory) {
        return
            abi.encode(
                instance_.index,
                instance_.version,
                instance_.assetName,
                instance_.assetSymbol,
                instance_.assetDecimals,
                instance_.underlyingToken,
                instance_.underlyingTokenSymbol,
                instance_.underlyingTokenDecimals,
                instance_.initialOwner,
                instance_.plasmaVault,
                instance_.plasmaVaultBase,
                instance_.feeManager
            );
    }

    /// @dev Deploys a second FusionFactory proxy of the same implementation, configured like setUp
    function _deployConfiguredFusionFactoryProxy() private returns (FusionFactory otherFusionFactory) {
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,(address,address,address,address,address,address,address),address,address,address,address)",
            owner,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        otherFusionFactory = FusionFactory(address(new ERC1967Proxy(address(fusionFactoryImplementation), initData)));

        vm.startPrank(owner);
        otherFusionFactory.grantRole(otherFusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        otherFusionFactory.grantRole(otherFusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        FusionFactoryStorageLib.FeePackage[] memory packages = fusionFactory.getDaoFeePackages();
        vm.startPrank(daoFeeManager);
        otherFusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = fusionFactory.getBaseAddresses();
        uint256 version = fusionFactory.getFusionFactoryVersion();
        vm.startPrank(maintenanceManager);
        otherFusionFactory.updateBaseAddresses(
            version,
            baseAddresses.plasmaVaultCoreBase,
            baseAddresses.accessManagerBase,
            baseAddresses.priceManagerBase,
            baseAddresses.withdrawManagerBase,
            baseAddresses.rewardsManagerBase,
            baseAddresses.contextManagerBase
        );
        vm.stopPrank();
    }
}
