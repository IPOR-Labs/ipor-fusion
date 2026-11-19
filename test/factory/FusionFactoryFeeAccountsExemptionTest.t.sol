// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Roles} from "../../contracts/libraries/Roles.sol";
import {RedemptionDelayLib} from "../../contracts/managers/access/RedemptionDelayLib.sol";
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
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

contract FusionFactoryFeeAccountsExemptionTest is Test {
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
        plasmaVaultBase = address(new PlasmaVaultBase());
        burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        FusionFactory fusionFactoryImplementation = new FusionFactory();
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

    function _cloneWithDelay(uint256 delay_) private returns (FusionFactoryLogicLib.FusionInstance memory) {
        return fusionFactory.clone("Vault", "VLT", address(underlyingToken), delay_, owner, 0);
    }

    function _depositDust(
        FusionFactoryLogicLib.FusionInstance memory instance_,
        address depositor_,
        address receiver_
    ) private {
        underlyingToken.mint(depositor_, 1_000e18);
        vm.startPrank(depositor_);
        underlyingToken.approve(instance_.plasmaVault, type(uint256).max);
        PlasmaVault(instance_.plasmaVault).deposit(1_000e18, receiver_);
        vm.stopPrank();
    }

    function _setupVault() private returns (FusionFactoryLogicLib.FusionInstance memory instance, address depositor) {
        instance = _cloneWithDelay(1 days);
        depositor = makeAddr("depositor");
        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();
    }

    function testShouldExemptFeeManagerAndBothFeeAccountsFromRedemptionDelay() public {
        // given / when
        FusionFactoryLogicLib.FusionInstance memory instance = _cloneWithDelay(1 days);

        // then
        IporFusionAccessManager am = IporFusionAccessManager(instance.accessManager);
        FeeManager fm = FeeManager(instance.feeManager);
        assertTrue(am.isRedemptionDelayExempt(instance.feeManager), "fee manager exempt");
        assertTrue(am.isRedemptionDelayExempt(fm.PERFORMANCE_FEE_ACCOUNT()), "performance fee account exempt");
        assertTrue(am.isRedemptionDelayExempt(fm.MANAGEMENT_FEE_ACCOUNT()), "management fee account exempt");
        assertEq(am.getRedemptionDelayExemptionsCount(), 3, "exactly three exemptions");
        assertFalse(am.isRedemptionDelayExempt(owner), "owner not exempt");
    }

    function testShouldHarvestFeesAfterDustDepositedToFeeAccounts() public {
        // given
        (FusionFactoryLogicLib.FusionInstance memory instance, address depositor) = _setupVault();
        FeeManager fm = FeeManager(instance.feeManager);
        address perfAccount = fm.PERFORMANCE_FEE_ACCOUNT();
        address mgmtAccount = fm.MANAGEMENT_FEE_ACCOUNT();

        // when - a third party deposits on behalf of both fee accounts, which starts the receiver lock
        _depositDust(instance, depositor, perfAccount);
        _depositDust(instance, depositor, mgmtAccount);
        uint256 perfShares = PlasmaVault(instance.plasmaVault).balanceOf(perfAccount);
        uint256 mgmtShares = PlasmaVault(instance.plasmaVault).balanceOf(mgmtAccount);
        assertGt(perfShares, 0);
        assertGt(mgmtShares, 0);

        // then - harvest moves the DAO part out of the fee accounts in the same block
        fm.harvestPerformanceFee();
        fm.harvestManagementFee();
        assertLt(PlasmaVault(instance.plasmaVault).balanceOf(perfAccount), perfShares, "performance fee harvested");
        assertLt(PlasmaVault(instance.plasmaVault).balanceOf(mgmtAccount), mgmtShares, "management fee harvested");
    }

    function testShouldUpdatePerformanceFeeAfterDustDepositedToFeeManager() public {
        // given
        (FusionFactoryLogicLib.FusionInstance memory instance, address depositor) = _setupVault();
        FeeManager fm = FeeManager(instance.feeManager);
        _depositDust(instance, depositor, fm.PERFORMANCE_FEE_ACCOUNT());
        _depositDust(instance, depositor, instance.feeManager);

        RecipientFee[] memory fees = new RecipientFee[](1);
        fees[0] = RecipientFee({recipient: makeAddr("recipient"), feeValue: 100});

        // when
        vm.prank(owner);
        fm.updatePerformanceFee(fees);

        // then
        assertEq(fm.getPerformanceFeeRecipients().length, 1);
    }

    function testShouldKeepRedemptionLockForOrdinaryDepositor() public {
        // given
        (FusionFactoryLogicLib.FusionInstance memory instance, address depositor) = _setupVault();
        _depositDust(instance, depositor, depositor);

        // when / then - the exemption is limited to the three fee addresses
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(RedemptionDelayLib.AccountIsLocked.selector, block.timestamp + 1 days));
        PlasmaVault(instance.plasmaVault).redeem(1, depositor, depositor);
    }

    function testShouldExemptFeeAccountsOnSupervisedClone() public {
        // given / when
        vm.prank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneSupervised(
            "Vault",
            "VLT",
            address(underlyingToken),
            1 days,
            owner,
            0
        );

        // then
        assertTrue(
            IporFusionAccessManager(instance.accessManager).isRedemptionDelayExempt(
                FeeManager(instance.feeManager).PERFORMANCE_FEE_ACCOUNT()
            )
        );
    }
}
