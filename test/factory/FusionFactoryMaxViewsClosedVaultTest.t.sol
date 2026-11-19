// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @notice IL-9624 follow-up: on a vault cloned by the FusionFactory (the new template with a fee package), the four
///         ERC-4626 max views return 0 while the vault is closed in the access manager and return the values they
///         had before the closure once the vault is reopened, also while management and performance fees are pending.
contract FusionFactoryMaxViewsClosedVaultTest is Test {
    uint256 private constant DEPOSIT = 1_000e18;
    uint256 private constant DONATION = 200e18;
    uint256 private constant REDEMPTION_DELAY = 1 days;

    FusionFactory public fusionFactory;
    MockERC20 public underlyingToken;
    address public owner;
    address public daoFeeManager;
    address public maintenanceManager;
    address public daoFeeRecipient;
    address public guardian;
    address public depositor;

    function setUp() public {
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
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
        guardian = makeAddr("guardian");
        depositor = makeAddr("depositor");

        address plasmaVaultBase = address(new PlasmaVaultBase());
        address burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        address burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        address priceOracleMiddleware = address(
            new ERC1967Proxy(
                address(new PriceOracleMiddleware(address(0))),
                abi.encodeWithSignature("initialize(address)", owner)
            )
        );

        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,(address,address,address,address,address,address,address),address,address,address,address)",
            owner,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(new FusionFactory()), initData)));

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 333,
            performanceFee: 777,
            feeRecipient: daoFeeRecipient
        });
        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);

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

    function _setupVaultWithPendingFees() private returns (FusionFactoryLogicLib.FusionInstance memory instance) {
        instance = fusionFactory.clone("Vault", "VLT", address(underlyingToken), REDEMPTION_DELAY, owner, 0);

        vm.startPrank(owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.GUARDIAN_ROLE, guardian, 0);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        underlyingToken.mint(depositor, DEPOSIT);
        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, type(uint256).max);
        PlasmaVault(instance.plasmaVault).deposit(DEPOSIT, depositor);
        vm.stopPrank();

        // time passes (management fee accrues) and a donation lifts the share price (performance fee accrues)
        vm.warp(block.timestamp + 30 days);
        underlyingToken.mint(instance.plasmaVault, DONATION);
    }

    function testShouldReturnZeroMaxViewsOnFactoryCloneWhileClosedAndRestoreThemWhenReopened() public {
        // given
        FusionFactoryLogicLib.FusionInstance memory instance = _setupVaultWithPendingFees();
        PlasmaVault vault = PlasmaVault(instance.plasmaVault);
        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);

        uint256 maxDepositBefore = vault.maxDeposit(depositor);
        uint256 maxMintBefore = vault.maxMint(depositor);
        uint256 maxWithdrawBefore = vault.maxWithdraw(depositor);
        uint256 maxRedeemBefore = vault.maxRedeem(depositor);
        assertGt(maxDepositBefore, 0, "maxDeposit positive before");
        assertGt(maxMintBefore, 0, "maxMint positive before");
        assertGt(maxWithdrawBefore, 0, "maxWithdraw positive before");
        assertGt(maxRedeemBefore, 0, "maxRedeem positive before");
        assertFalse(accessManager.isTargetClosed(instance.plasmaVault), "vault open before");

        // when - the guardian closes the vault
        vm.prank(guardian);
        accessManager.updateTargetClosed(instance.plasmaVault, true);

        // then - all four views read 0 and the calls are rejected
        assertTrue(accessManager.isTargetClosed(instance.plasmaVault), "vault closed");
        assertEq(vault.maxDeposit(depositor), 0, "maxDeposit 0 while closed");
        assertEq(vault.maxMint(depositor), 0, "maxMint 0 while closed");
        assertEq(vault.maxWithdraw(depositor), 0, "maxWithdraw 0 while closed");
        assertEq(vault.maxRedeem(depositor), 0, "maxRedeem 0 while closed");

        vm.startPrank(depositor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, depositor));
        vault.redeem(maxRedeemBefore, depositor, depositor);
        vm.stopPrank();

        // when - the guardian reopens the vault
        vm.prank(guardian);
        accessManager.updateTargetClosed(instance.plasmaVault, false);

        // then - every view is back at its value from before the closure
        assertFalse(accessManager.isTargetClosed(instance.plasmaVault), "vault reopened");
        assertEq(vault.maxDeposit(depositor), maxDepositBefore, "maxDeposit restored");
        assertEq(vault.maxMint(depositor), maxMintBefore, "maxMint restored");
        assertEq(vault.maxWithdraw(depositor), maxWithdrawBefore, "maxWithdraw restored");
        assertEq(vault.maxRedeem(depositor), maxRedeemBefore, "maxRedeem restored");
    }

    function testShouldHavePendingFeesOnFactoryCloneBeforeClosure() public {
        // given / when
        FusionFactoryLogicLib.FusionInstance memory instance = _setupVaultWithPendingFees();
        PlasmaVault vault = PlasmaVault(instance.plasmaVault);

        // then - the precondition of the closure test: gross assets exceed the deposit and the owner is past the lock
        assertEq(vault.totalAssets(), DEPOSIT + DONATION, "donation counted in total assets");
        assertGt(vault.maxRedeem(depositor), 0, "owner past the redemption lock");
        assertLt(vault.maxWithdraw(depositor), vault.totalAssets(), "pending fees reduce the owner's claim");

        // then - the management fee is pending: time passed at a nonzero rate, so unrealized fee assets are positive
        assertGt(vault.getUnrealizedManagementFee(), 0, "management fee pending");

        // then - the performance fee is pending: the share rate is above a set high-water mark and the FeeManager
        // sizes positive fee shares for it (view calls only, nothing is crystallized before the closure scenario)
        FeeManager feeManager = FeeManager(instance.feeManager);
        uint256 highWaterMark = feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
        uint256 rate = vault.convertToAssets(10 ** vault.decimals() * feeManager.HIGH_WATER_MARK_SCALE());
        assertGt(highWaterMark, 0, "high-water mark set");
        assertGt(rate, highWaterMark, "share rate above the high-water mark");
        assertGt(
            feeManager.pendingPerformanceFeeShares(uint128(rate), vault.totalSupply(), 777),
            0,
            "performance fee shares pending"
        );
    }
}
