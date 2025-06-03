// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
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


import {Roles} from "../../contracts/libraries/Roles.sol";

contract FusionFactoryTest is Test {
    FusionFactory public fusionFactory;
    FusionFactory public fusionFactoryImplementation;
    FusionFactoryLib.FactoryAddresses public factoryAddresses;
    address public plasmaVaultBase;
    address public priceOracleMiddleware;
    address public burnRequestFeeFuse;
    address public burnRequestFeeBalanceFuse;
    MockERC20 public underlyingToken;
    address public owner;
    address public iporDaoFeeRecipient;

    function setUp() public {
        // Deploy mock token
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        // Deploy factory contracts
        factoryAddresses = FusionFactoryLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        owner = address(0x777);
        iporDaoFeeRecipient = address(0x888);

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
            "initialize((address,address,address,address,address,address,address),address,address,address,address)",
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(fusionFactoryImplementation), initData)));

        fusionFactory.updateIporDaoFee(iporDaoFeeRecipient, 100, 100);
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

    function testShouldSetupIporDaoFee() public {
        //given
        address iporDaoFeeRecipient = address(0x999);
        uint256 iporDaoManagementFee = 11;
        uint256 iporDaoPerformanceFee = 12;
        //when
        fusionFactory.updateIporDaoFee(iporDaoFeeRecipient, iporDaoManagementFee, iporDaoPerformanceFee);

        //then
        assertEq(fusionFactory.getIporDaoFeeRecipientAddress(), iporDaoFeeRecipient);
        assertEq(fusionFactory.getIporDaoManagementFee(), iporDaoManagementFee);
        assertEq(fusionFactory.getIporDaoPerformanceFee(), iporDaoPerformanceFee);
    }

    function testShouldUpdateFactoryAddresses() public {
        // given
        FusionFactoryLib.FactoryAddresses memory newFactoryAddresses = FusionFactoryLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        // when
        fusionFactory.updateFactoryAddresses(newFactoryAddresses);

        // then
        FusionFactoryLib.FactoryAddresses memory updatedAddresses = fusionFactory.getFactoryAddresses();
        assertEq(updatedAddresses.accessManagerFactory, newFactoryAddresses.accessManagerFactory);
        assertEq(updatedAddresses.plasmaVaultFactory, newFactoryAddresses.plasmaVaultFactory);
        assertEq(updatedAddresses.feeManagerFactory, newFactoryAddresses.feeManagerFactory);
        assertEq(updatedAddresses.withdrawManagerFactory, newFactoryAddresses.withdrawManagerFactory);
        assertEq(updatedAddresses.rewardsManagerFactory, newFactoryAddresses.rewardsManagerFactory);
        assertEq(updatedAddresses.contextManagerFactory, newFactoryAddresses.contextManagerFactory);
        assertEq(updatedAddresses.priceManagerFactory, newFactoryAddresses.priceManagerFactory);
    }

    function testShouldUpdatePlasmaVaultBase() public {
        // given
        address newPlasmaVaultBase = address(new PlasmaVaultBase());

        // when
        fusionFactory.updatePlasmaVaultBase(newPlasmaVaultBase);

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
        fusionFactory.updatePriceOracleMiddleware(newPriceOracleMiddleware);

        // then
        assertEq(fusionFactory.getPriceOracleMiddleware(), newPriceOracleMiddleware);
    }

    function testShouldUpdateBurnRequestFeeFuse() public {
        // given
        address newBurnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        // when
        fusionFactory.updateBurnRequestFeeFuse(newBurnRequestFeeFuse);

        // then
        assertEq(fusionFactory.getBurnRequestFeeFuseAddress(), newBurnRequestFeeFuse);
    }

    function testShouldUpdateBurnRequestFeeBalanceFuse() public {
        // given
        address newBurnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        // when
        fusionFactory.updateBurnRequestFeeBalanceFuse(newBurnRequestFeeBalanceFuse);

        // then
        assertEq(fusionFactory.getBurnRequestFeeBalanceFuseAddress(), newBurnRequestFeeBalanceFuse);
    }

    function testShouldUpdateRedemptionDelayInSeconds() public {
        // given
        uint256 newRedemptionDelay = 3600; // 1 hour

        // when
        fusionFactory.updateRedemptionDelayInSeconds(newRedemptionDelay);

        // then
        assertEq(fusionFactory.getRedemptionDelayInSeconds(), newRedemptionDelay);
    }

    function testShouldUpdateWithdrawWindowInSeconds() public {
        // given
        uint256 newWithdrawWindow = 86400; // 24 hours

        // when
        fusionFactory.updateWithdrawWindowInSeconds(newWithdrawWindow);

        // then
        assertEq(fusionFactory.getWithdrawWindowInSeconds(), newWithdrawWindow);
    }

    function testShouldUpdateVestingPeriodInSeconds() public {
        // given
        uint256 newVestingPeriod = 604800; // 1 week

        // when
        fusionFactory.updateVestingPeriodInSeconds(newVestingPeriod);

        // then
        assertEq(fusionFactory.getVestingPeriodInSeconds(), newVestingPeriod);
    }

    function testShouldRevertWhenUpdatingFactoryAddressesWithZeroAddress() public {
        // given
        FusionFactoryLib.FactoryAddresses memory newFactoryAddresses = FusionFactoryLib.FactoryAddresses({
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
        fusionFactory.updateFactoryAddresses(newFactoryAddresses);
    }

    function testShouldRevertWhenUpdatingPlasmaVaultBaseWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        fusionFactory.updatePlasmaVaultBase(address(0));
    }

    function testShouldRevertWhenUpdatingPriceOracleMiddlewareWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        fusionFactory.updatePriceOracleMiddleware(address(0));
    }

    function testShouldRevertWhenUpdatingBurnRequestFeeFuseWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        fusionFactory.updateBurnRequestFeeFuse(address(0));
    }

    function testShouldRevertWhenUpdatingBurnRequestFeeBalanceFuseWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        fusionFactory.updateBurnRequestFeeBalanceFuse(address(0));
    }

    function testShouldRevertWhenUpdatingIporDaoFeeWithZeroAddress() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidAddress.selector);
        fusionFactory.updateIporDaoFee(address(0), 100, 100);
    }

    function testShouldRevertWhenUpdatingIporDaoFeeWithInvalidFee() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidFeeValue.selector);
        fusionFactory.updateIporDaoFee(iporDaoFeeRecipient, 10001, 100); // > 10000 (100%)
    }

    function testShouldRevertWhenUpdatingRedemptionDelayWithZero() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidRedemptionDelay.selector);
        fusionFactory.updateRedemptionDelayInSeconds(0);
    }

    function testShouldRevertWhenUpdatingWithdrawWindowWithZero() public {
        // when/then
        vm.expectRevert(FusionFactoryLib.InvalidWithdrawWindow.selector);
        fusionFactory.updateWithdrawWindowInSeconds(0);
    }

    function testShouldNotRevertWhenUpdatingVestingPeriodWithZero() public {
        // when/then
        fusionFactory.updateVestingPeriodInSeconds(0);
    }

    function testShouldUpdatePlasmaVaultAdmin() public {
        // given
        address newPlasmaVaultAdmin = address(0x1000);

        // when
        fusionFactory.updatePlasmaVaultAdmin(newPlasmaVaultAdmin);

        // then
        assertEq(fusionFactory.getPlasmaVaultAdmin(), newPlasmaVaultAdmin);
    }

    function testShouldCreateVaultWithCorrectAdmin() public {
        // given
        address plasmaVaultAdmin = address(0x1000);
        fusionFactory.updatePlasmaVaultAdmin(plasmaVaultAdmin);

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        (bool hasRole, uint32 delay) = accessManager.hasRole(Roles.ADMIN_ROLE, plasmaVaultAdmin);
        assertTrue(hasRole);
        assertEq(delay, 0);
    }

    function testShouldCreateVaultWithCorrectIporDaoFees() public {
        // given
        address iporDaoFeeRecipient = address(0x999);
        uint256 iporDaoManagementFee = 100;
        uint256 iporDaoPerformanceFee = 200;
        fusionFactory.updateIporDaoFee(iporDaoFeeRecipient, iporDaoManagementFee, iporDaoPerformanceFee);

        // when
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Test Asset",
            "TEST",
            address(underlyingToken),
            owner
        );

        // then
        assertEq(fusionFactory.getIporDaoFeeRecipientAddress(), iporDaoFeeRecipient);
        assertEq(fusionFactory.getIporDaoManagementFee(), iporDaoManagementFee);
        assertEq(fusionFactory.getIporDaoPerformanceFee(), iporDaoPerformanceFee);
    }


    function testShouldCreateVaultWithCorrectRedemptionDelay() public {
        // given
        uint256 redemptionDelay = 123;
        fusionFactory.updateRedemptionDelayInSeconds(redemptionDelay);

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
        fusionFactory.updateWithdrawWindowInSeconds(withdrawWindow);

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
        fusionFactory.updateVestingPeriodInSeconds(vestingPeriod);

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


        assertEq(governanceVault.isBalanceFuseSupported(IporFusionMarkets.ZERO_BALANCE_MARKET, burnRequestFeeBalanceFuse), true);

        address[] memory fuses = governanceVault.getFuses();

        for (uint256 i = 0; i < fuses.length; i++) {
            if (fuses[i] == burnRequestFeeFuse) {
                return;
            }
        }

        fail();
    }

}
