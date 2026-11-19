// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RequestBackingTestBase} from "./request_backing/RequestBackingTestBase.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
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
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

/// @title PlasmaVaultCallerRedemptionLockTest
/// @notice IL-9705 (3sigma audit v3, #19, Pete D-004): in `transferFrom`, `redeem` and `withdraw` the caller passes
///         only the role check; the redemption lock is read for the owner of the shares (`from` / `owner`) only.
///         A third party that deposits dust to an operator therefore cannot lock the operator out of moving
///         another account's shares. The owner's lock and the caller's role are still enforced.
contract PlasmaVaultCallerRedemptionLockTest is Test {
    uint256 private constant REDEMPTION_DELAY = 1 days;
    uint256 private constant DEPOSIT_AMOUNT = 1000 * 1e18;

    FusionFactory private fusionFactory;
    FusionFactoryStorageLib.FactoryAddresses private factoryAddresses;
    MockERC20 private underlyingToken;

    address private plasmaVaultBase;
    address private priceOracleMiddleware;
    address private burnRequestFeeFuse;
    address private burnRequestFeeBalanceFuse;

    address private owner;
    address private atomist;
    address private depositor;
    address private operator;
    address private griefer;
    address private receiver;
    address private daoFeeRecipient;
    address private daoFeeManager;
    address private maintenanceManager;

    IporFusionAccessManager private accessManager;
    PlasmaVault private plasmaVault;
    address private feeManagerOf;

    function setUp() public {
        owner = makeAddr("owner");
        atomist = makeAddr("atomist");
        depositor = makeAddr("depositor");
        operator = makeAddr("operator");
        griefer = makeAddr("griefer");
        receiver = makeAddr("receiver");
        daoFeeRecipient = makeAddr("daoFeeRecipient");
        daoFeeManager = makeAddr("daoFeeManager");
        maintenanceManager = makeAddr("maintenanceManager");

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

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Vault",
            "TVAULT",
            address(underlyingToken),
            REDEMPTION_DELAY,
            owner,
            0
        );

        accessManager = IporFusionAccessManager(instance.accessManager);
        plasmaVault = PlasmaVault(payable(instance.plasmaVault));
        feeManagerOf = instance.feeManager;

        // the owner also acts as role admin for whitelisting depositors (ATOMIST_ROLE administers WHITELIST_ROLE)
        vm.prank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);
    }

    // ------------------------------------------------------------------
    // The caller's own lock no longer blocks moving another account's shares
    // ------------------------------------------------------------------

    function testShouldLetOperatorTransferFromAfterThirdPartyDustDeposit() public {
        // given
        uint256 shares = _unlockedOwnerWithLockedOperator();

        // when
        vm.prank(operator);
        plasmaVault.transferFrom(depositor, receiver, shares / 2);

        // then
        assertEq(plasmaVault.balanceOf(receiver), shares / 2, "shares transferred");
    }

    function testShouldLetOperatorWithdrawAfterThirdPartyDustDeposit() public {
        // given
        _unlockedOwnerWithLockedOperator();

        // when
        vm.prank(operator);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, receiver, depositor);

        // then
        assertEq(underlyingToken.balanceOf(receiver), DEPOSIT_AMOUNT / 2, "assets received");
    }

    function testShouldLetOperatorRedeemAfterThirdPartyDustDeposit() public {
        // given
        uint256 shares = _unlockedOwnerWithLockedOperator();

        // when
        vm.prank(operator);
        plasmaVault.redeem(shares / 2, receiver, depositor);

        // then
        assertGt(underlyingToken.balanceOf(receiver), 0, "assets received");
    }

    // ------------------------------------------------------------------
    // What still reverts
    // ------------------------------------------------------------------

    function testShouldStillRevertWhenOwnerIsLockedAndOperatorIsExempt() public {
        // given - the owner deposited just now; the operator is exempt and holds the allowance
        _whitelist(depositor);
        _whitelist(operator);
        _enableTransferShares();
        _exempt(operator);
        _deposit(depositor, DEPOSIT_AMOUNT);
        uint256 ownerUnlockTime = block.timestamp + REDEMPTION_DELAY;
        uint256 shares = plasmaVault.balanceOf(depositor);
        vm.prank(depositor);
        plasmaVault.approve(operator, shares);

        // when / then - the owner's lock is what reverts
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", ownerUnlockTime));
        vm.prank(operator);
        plasmaVault.transferFrom(depositor, receiver, shares / 2);

        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", ownerUnlockTime));
        vm.prank(operator);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, receiver, depositor);

        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", ownerUnlockTime));
        vm.prank(operator);
        plasmaVault.redeem(shares / 2, receiver, depositor);
    }

    // ------------------------------------------------------------------
    // FeeManager on a vault without the IL-9634 exemption
    // ------------------------------------------------------------------

    function testShouldHarvestManagementFeeAfterDustDepositedToFeeManagerWithoutExemption() public {
        // given - the IL-9634 exemptions are removed, so the lock applies to every account
        FeeManager fm = FeeManager(feeManagerOf);
        address mgmtAccount = fm.MANAGEMENT_FEE_ACCOUNT();
        address[] memory accounts = new address[](3);
        accounts[0] = feeManagerOf;
        accounts[1] = mgmtAccount;
        accounts[2] = fm.PERFORMANCE_FEE_ACCOUNT();
        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelayExemption(accounts, false);
        assertFalse(accessManager.isRedemptionDelayExempt(feeManagerOf), "fee manager not exempt");

        _whitelist(griefer);
        _dustDeposit(mgmtAccount);
        uint256 mgmtShares = plasmaVault.balanceOf(mgmtAccount);
        assertGt(mgmtShares, 0, "management fee account holds shares");
        vm.warp(block.timestamp + REDEMPTION_DELAY + 1);

        // when - a third party deposits dust to the FeeManager, which locks the caller of the harvest
        _dustDeposit(feeManagerOf);
        assertGt(accessManager.getAccountLockTime(feeManagerOf), block.timestamp, "fee manager locked");

        // then - harvest moves the DAO part out of the unlocked fee account
        fm.harvestManagementFee();
        assertLt(plasmaVault.balanceOf(mgmtAccount), mgmtShares, "management fee harvested");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev The owner deposits and waits out the lock; a third party then deposits dust to the operator, which locks
    ///      the operator; the owner approves the operator. Returns the owner's shares
    function _unlockedOwnerWithLockedOperator() private returns (uint256 shares) {
        _whitelist(depositor);
        _whitelist(operator);
        _whitelist(griefer);
        _enableTransferShares();
        _deposit(depositor, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + REDEMPTION_DELAY + 1);
        _dustDeposit(operator);
        assertGt(accessManager.getAccountLockTime(operator), block.timestamp, "operator locked by the dust deposit");
        shares = plasmaVault.balanceOf(depositor);
        vm.prank(depositor);
        plasmaVault.approve(operator, shares);
    }

    function _dustDeposit(address receiver_) private {
        underlyingToken.mint(griefer, 1_000e18);
        vm.startPrank(griefer);
        underlyingToken.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(1_000e18, receiver_);
        vm.stopPrank();
    }

    function _whitelist(address account_) private {
        vm.prank(owner);
        accessManager.grantRole(Roles.WHITELIST_ROLE, account_, 0);
    }

    function _exempt(address account_) private {
        address[] memory accounts = new address[](1);
        accounts[0] = account_;
        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelayExemption(accounts, true);
    }

    function _enableTransferShares() private {
        vm.prank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).enableTransferShares();
    }

    function _deposit(address account_, uint256 amount_) private {
        underlyingToken.mint(account_, amount_);
        vm.startPrank(account_);
        underlyingToken.approve(address(plasmaVault), amount_);
        plasmaVault.deposit(amount_, account_);
        vm.stopPrank();
    }
}

/// @notice IL-9705: the caller still needs the role of the function. The exit functions are made role-gated
///         (WHITELIST_ROLE) by the access manager admin, so an operator without the role is rejected on the
///         role check even though only the owner's lock is read now
contract PlasmaVaultCallerRedemptionRoleTest is RequestBackingTestBase {
    function testShouldStillRequireRoleOfOperatorOnNonPublicVault() public {
        // given - redeem and withdraw need WHITELIST_ROLE; the operator has none and is locked by a dust deposit
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = vault.redeem.selector;
        selectors[1] = vault.withdraw.selector;
        vm.prank(TestAddresses.ADMIN);
        accessManager.setTargetFunctionRole(address(vault), selectors, Roles.WHITELIST_ROLE);

        address holder = HONEST;
        uint256 shares = _deposit(holder, 100_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(holder);
        vault.approve(BYSTANDER, shares);
        _dustDeposit(BYSTANDER);

        // when / then - the role check of the caller is not weakened
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", BYSTANDER));
        vm.prank(BYSTANDER);
        vault.redeem(shares / 2, SINK, holder);

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", BYSTANDER));
        vm.prank(BYSTANDER);
        vault.withdraw(1e6, SINK, holder);

        // and - with the role the same call passes
        vm.prank(TestAddresses.ATOMIST);
        accessManager.grantRole(Roles.WHITELIST_ROLE, BYSTANDER, 0);
        vm.prank(BYSTANDER);
        vault.redeem(shares / 2, SINK, holder);
        assertGt(usdc.balanceOf(SINK), 0, "assets received once the role is granted");
    }

    function testShouldStillRequireRoleOfOperatorOnTransferFromOfNonPublicVault() public {
        // given - transferFrom needs WHITELIST_ROLE; the operator has none and is locked by a dust deposit
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = vault.transferFrom.selector;
        vm.prank(TestAddresses.ADMIN);
        accessManager.setTargetFunctionRole(address(vault), selectors, Roles.WHITELIST_ROLE);

        address holder = HONEST;
        uint256 shares = _deposit(holder, 100_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(holder);
        vault.approve(BYSTANDER, shares);
        _dustDeposit(BYSTANDER);

        // when / then - the role check of the caller in the transferFrom branch is not weakened
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", BYSTANDER));
        vm.prank(BYSTANDER);
        vault.transferFrom(holder, SINK, shares / 2);

        // and - with the role the same call passes
        vm.prank(TestAddresses.ATOMIST);
        accessManager.grantRole(Roles.WHITELIST_ROLE, BYSTANDER, 0);
        vm.prank(BYSTANDER);
        vault.transferFrom(holder, SINK, shares / 2);
        assertEq(vault.balanceOf(SINK), shares / 2, "shares moved once the role is granted");
    }
}
