// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
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

contract FusionFactoryTest is Test {
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

        // Deploy implementation and proxy for FusionFactory
        fusionFactoryImplementation = new FusionFactory();
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

        vm.startPrank(daoFeeManager);
        fusionFactory.updateDaoFee(daoFeeRecipient, 100, 100);
        vm.stopPrank();
    }

    function testShouldCreateFusionInstance() public {
        //when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
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

    function testShouldSetupDaoFee() public {
        //given
        address daoFeeRecipient = address(0x999);
        uint256 daoManagementFee = 11;
        uint256 daoPerformanceFee = 12;

        //when
        vm.startPrank(daoFeeManager);
        fusionFactory.updateDaoFee(daoFeeRecipient, daoManagementFee, daoPerformanceFee);
        vm.stopPrank();

        //then
        assertEq(fusionFactory.getDaoFeeRecipientAddress(), daoFeeRecipient);
        assertEq(fusionFactory.getDaoManagementFee(), daoManagementFee);
        assertEq(fusionFactory.getDaoPerformanceFee(), daoPerformanceFee);
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

    function testShouldUpdateRedemptionDelayInSeconds() public {
        // given
        uint256 newRedemptionDelay = 3600; // 1 hour

        // when
        vm.startPrank(maintenanceManager);
        fusionFactory.updateRedemptionDelayInSeconds(newRedemptionDelay);
        vm.stopPrank();

        // then
        assertEq(fusionFactory.getRedemptionDelayInSeconds(), newRedemptionDelay);
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

    function testShouldRevertWhenUpdatingIporDaoFeeWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        vm.startPrank(daoFeeManager);
        fusionFactory.updateDaoFee(address(0), 100, 100);
        vm.stopPrank();
    }

    function testShouldRevertWhenUpdatingIporDaoFeeWithInvalidFee() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidFeeValue.selector);
        vm.startPrank(daoFeeManager);
        fusionFactory.updateDaoFee(daoFeeRecipient, 10001, 100); // > 10000 (100%)
        vm.stopPrank();
    }

    function testShouldRevertWhenUpdatingRedemptionDelayWithZero() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidRedemptionDelay.selector);
        vm.startPrank(maintenanceManager);
        fusionFactory.updateRedemptionDelayInSeconds(0);
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

    function testShouldUpdatePlasmaVaultAdmin() public {
        // given
        address[] memory newPlasmaVaultAdminArray = new address[](2);
        newPlasmaVaultAdminArray[0] = adminOne;
        newPlasmaVaultAdminArray[1] = address(0x123);

        // when
        vm.startPrank(owner);
        fusionFactory.updatePlasmaVaultAdminArray(newPlasmaVaultAdminArray);
        vm.stopPrank();

        // then
        address[] memory updatedPlasmaVaultAdminArray = fusionFactory.getPlasmaVaultAdminArray();
        assertEq(updatedPlasmaVaultAdminArray[0], newPlasmaVaultAdminArray[0]);
        assertEq(updatedPlasmaVaultAdminArray[1], newPlasmaVaultAdminArray[1]);
    }

    function testShouldCreateVaultWithCorrectAdmin() public {
        // given
        address[] memory newPlasmaVaultAdminArray = new address[](2);
        newPlasmaVaultAdminArray[0] = address(0x321);
        newPlasmaVaultAdminArray[1] = address(0x123);

        vm.startPrank(owner);
        fusionFactory.updatePlasmaVaultAdminArray(newPlasmaVaultAdminArray);
        vm.stopPrank();

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasRoleOne, uint32 delayOne) = accessManager.hasRole(Roles.ADMIN_ROLE, newPlasmaVaultAdminArray[0]);
        (bool hasRoleTwo, uint32 delayTwo) = accessManager.hasRole(Roles.ADMIN_ROLE, newPlasmaVaultAdminArray[1]);
        assertTrue(hasRoleOne);
        assertTrue(hasRoleTwo);
        assertEq(delayOne, 0);
        assertEq(delayTwo, 0);
    }

    function testShouldCreateVaultWithCorrectIporDaoFees() public {
        // given
        address daoFeeRecipient = address(0x999);
        uint256 daoManagementFee = 100;
        uint256 daoPerformanceFee = 200;

        vm.startPrank(daoFeeManager);
        fusionFactory.updateDaoFee(daoFeeRecipient, daoManagementFee, daoPerformanceFee);
        vm.stopPrank();

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        assertEq(fusionFactory.getDaoFeeRecipientAddress(), daoFeeRecipient);
        assertEq(fusionFactory.getDaoManagementFee(), daoManagementFee);
        assertEq(fusionFactory.getDaoPerformanceFee(), daoPerformanceFee);
    }

    function testShouldCreateVaultWithCorrectRedemptionDelay() public {
        // given
        uint256 redemptionDelay = 123;

        vm.startPrank(maintenanceManager);
        fusionFactory.updateRedemptionDelayInSeconds(redemptionDelay);
        vm.stopPrank();

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), redemptionDelay);
    }

    function testShouldCreateVaultWithCorrectWithdrawWindow() public {
        // given
        uint256 withdrawWindow = 123;

        vm.startPrank(maintenanceManager);
        fusionFactory.updateWithdrawWindowInSeconds(withdrawWindow);
        vm.stopPrank();

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        WithdrawManager withdrawManager = WithdrawManager(instance.withdrawManager);
        assertEq(withdrawManager.getWithdrawWindow(), withdrawWindow);
    }

    function testShouldCreateVaultWithCorrectVestingPeriod() public {
        // given
        uint256 vestingPeriod = 123;

        vm.startPrank(maintenanceManager);
        fusionFactory.updateVestingPeriodInSeconds(vestingPeriod);
        vm.stopPrank();

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        RewardsClaimManager rewardsClaimManager = RewardsClaimManager(instance.rewardsManager);
        assertEq(rewardsClaimManager.getVestingData().vestingTime, vestingPeriod);
    }

    function testShouldCreateVaultWithCorrectPlasmaVaultBase() public {
        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        PlasmaVault plasmaVault = PlasmaVault(instance.plasmaVault);
        assertEq(plasmaVault.PLASMA_VAULT_BASE(), plasmaVaultBase);
    }

    function testShouldCreateVaultWithCorrectPlasmaVaultOnWithdrawManager() public {
        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        WithdrawManager withdrawManager = WithdrawManager(instance.withdrawManager);
        assertEq(withdrawManager.getPlasmaVaultAddress(), instance.plasmaVault);
    }

    function testShouldCreateVaultWithCorrectRewardsClaimManager() public {
        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(instance.plasmaVault);

        assertEq(governanceVault.getRewardsClaimManagerAddress(), instance.rewardsManager);
    }

    function testShouldCreateVaultWithCorrectBurnRequestFeeFuse() public {
        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
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

    function testShouldRevertWhenCreatingVaultWhilePaused() public {
        // given
        address pauseManager = address(0x123);
        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.PAUSE_MANAGER_ROLE(), pauseManager);
        vm.stopPrank();

        // when
        vm.startPrank(pauseManager);
        fusionFactory.pause();
        vm.stopPrank();

        // then
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        fusionFactory.create("Test Asset", "TEST", address(underlyingToken), owner);

        // when unpaused
        vm.startPrank(owner);
        fusionFactory.unpause();
        vm.stopPrank();

        // then should work again
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        assertEq(instance.assetName, "Test Asset");
        assertEq(instance.assetSymbol, "TEST");
        assertEq(instance.underlyingToken, address(underlyingToken));
        assertEq(instance.initialOwner, owner);
    }

    function testShouldUpgradeFusionFactory() public {
        // given
        FusionFactory newImplementation = new FusionFactory();

        // when
        vm.startPrank(owner);
        fusionFactory.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        // then
        // Verify that the contract still works by creating a new instance
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
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

        // Verify that existing functionality still works
        assertEq(fusionFactory.getDaoFeeRecipientAddress(), daoFeeRecipient);
        assertEq(fusionFactory.getDaoManagementFee(), 100);
        assertEq(fusionFactory.getDaoPerformanceFee(), 100);
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

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        IPlasmaVaultGovernance plasmaVaultGovernance = IPlasmaVaultGovernance(instance.plasmaVault);
        assertEq(plasmaVaultGovernance.getPriceOracleMiddleware(), instance.priceManager);
    }

    function testShouldAllowDepositAfterVaultCreation() public {
        // given
        uint256 depositAmount = 1000 * 1e18; // 1000 tokens
        address depositor = address(0x123);

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
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
        uint256 depositAmount = 1000 * 1e18; // 1000 tokens
        address depositor = address(0x123);

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
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
        address daoFeeRecipient = address(0x123);
        uint256 daoManagementFee = 100;
        uint256 daoPerformanceFee = 100;

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        vm.startPrank(daoFeeManager);
        fusionFactory.updateDaoFee(daoFeeRecipient, daoManagementFee, daoPerformanceFee);
        vm.stopPrank();

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        FeeManager feeManager = FeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), daoManagementFee);
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), daoPerformanceFee);
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), daoFeeRecipient);
    }
}
