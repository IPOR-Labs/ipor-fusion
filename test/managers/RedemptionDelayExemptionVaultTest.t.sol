// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
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
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

/// @title RedemptionDelayExemptionVaultTest
/// @notice End-to-end tests of the redemption delay exemptions on a FusionFactory vault (local, no fork)
/// @dev Covers the owner route (PlasmaVaultGovernance -> IporFusionAccessManager), the OWNER_ROLE timelock
/// and the four gated exits (withdraw, redeem, transfer, transferFrom) under a non-zero vault delay,
/// including the checks PlasmaVault._checkCanCall runs for both the share owner and the caller.
contract RedemptionDelayExemptionVaultTest is Test {
    uint256 private constant TIMELOCK_24H = 24 hours;
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
    address private timelockedOwner;
    address private guardian;
    address private atomist;
    address private alpha;
    address private depositor;
    address private other;
    address private spender;
    address private receiver;
    address private stranger;
    address private daoFeeRecipient;
    address private daoFeeManager;
    address private maintenanceManager;

    IporFusionAccessManager private accessManager;
    PlasmaVault private plasmaVault;

    event RedemptionDelayExemptionUpdated(address account, bool exempt);

    function setUp() public {
        owner = makeAddr("owner");
        timelockedOwner = makeAddr("timelockedOwner");
        guardian = makeAddr("guardian");
        atomist = makeAddr("atomist");
        alpha = makeAddr("alpha");
        depositor = makeAddr("depositor");
        other = makeAddr("other");
        spender = makeAddr("spender");
        receiver = makeAddr("receiver");
        stranger = makeAddr("stranger");
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

        // the owner also acts as role admin for whitelisting depositors (ATOMIST_ROLE administers WHITELIST_ROLE)
        vm.prank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);
    }

    // ------------------------------------------------------------------
    // Owner route and access
    // ------------------------------------------------------------------

    function testShouldOwnerSetExemptionThroughVaultImmediatelyAndEmitEvent() public {
        // given
        address[] memory accounts = new address[](2);
        accounts[0] = depositor;
        accounts[1] = other;
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 0, "no exemptions initially");
        assertFalse(accessManager.isRedemptionDelayExempt(depositor), "not exempt initially");

        // when
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayExemptionUpdated(depositor, true);
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayExemptionUpdated(other, true);
        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelayExemption(accounts, true);

        // then
        assertTrue(accessManager.isRedemptionDelayExempt(depositor), "depositor exempt");
        assertTrue(accessManager.isRedemptionDelayExempt(other), "other exempt");
        assertFalse(accessManager.isRedemptionDelayExempt(stranger), "stranger not exempt");
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 2, "count");
        address[] memory listed = accessManager.getRedemptionDelayExemptions();
        assertEq(listed.length, 2, "listed length");
        assertEq(listed[0], depositor, "listed[0]");
        assertEq(listed[1], other, "listed[1]");

        // when - revoke one
        address[] memory revoked = new address[](1);
        revoked[0] = depositor;
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayExemptionUpdated(depositor, false);
        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelayExemption(revoked, false);

        // then
        assertFalse(accessManager.isRedemptionDelayExempt(depositor), "depositor revoked");
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 1, "count after revoke");
    }

    function testShouldNotSetExemptionThroughVaultWhenNotOwner() public {
        // given
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        vm.stopPrank();
        _deposit(depositor, DEPOSIT_AMOUNT);

        address[4] memory callers = [atomist, alpha, depositor, stranger];
        address[] memory accounts = new address[](1);
        accounts[0] = other;

        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                bool exempt = j == 0;

                // when/then
                vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", callers[i]));
                vm.prank(callers[i]);
                IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelayExemption(accounts, exempt);
            }
        }

        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 0, "nothing was exempted");
    }

    function testShouldNotSetExemptionDirectlyOnAccessManagerEvenWhenOwner() public {
        // given
        address[] memory accounts = new address[](1);
        accounts[0] = depositor;

        // when/then - the access manager setter is reserved for the vault (TECH_PLASMA_VAULT_ROLE)
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", owner));
        vm.prank(owner);
        accessManager.setRedemptionDelayExemption(accounts, true);

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", stranger));
        vm.prank(stranger);
        accessManager.setRedemptionDelayExemption(accounts, true);

        assertFalse(accessManager.isRedemptionDelayExempt(depositor), "no exemption was set");
    }

    function testShouldNotChangeRedemptionDelayWhenNotOwner() public {
        // given
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        vm.stopPrank();

        address[3] memory callers = [atomist, alpha, stranger];
        for (uint256 i; i < callers.length; ++i) {
            // when/then - through the vault
            vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", callers[i]));
            vm.prank(callers[i]);
            IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelay(0);

            // when/then - directly on the access manager
            vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", callers[i]));
            vm.prank(callers[i]);
            accessManager.setRedemptionDelay(0);
        }

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", owner));
        vm.prank(owner);
        accessManager.setRedemptionDelay(0);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), REDEMPTION_DELAY, "delay unchanged");
    }

    function testShouldFactoryWireRedemptionDelayExemptionSetters() public view {
        assertEq(
            accessManager.getTargetFunctionRole(
                address(accessManager),
                IporFusionAccessManager.setRedemptionDelayExemption.selector
            ),
            Roles.TECH_PLASMA_VAULT_ROLE,
            "access manager setter should be TECH_PLASMA_VAULT_ROLE restricted"
        );
        assertEq(
            accessManager.getTargetFunctionRole(
                address(plasmaVault),
                IPlasmaVaultGovernance.setRedemptionDelayExemption.selector
            ),
            Roles.OWNER_ROLE,
            "vault setter should be OWNER_ROLE restricted"
        );
    }

    // ------------------------------------------------------------------
    // Timelock
    // ------------------------------------------------------------------

    function testShouldRequireScheduleForTimelockedOwnerExemptionChange() public {
        // given
        _setupTimelockedOwner();
        address[] memory accounts = new address[](1);
        accounts[0] = depositor;
        bytes memory data = _setExemptionCalldata(accounts, true);
        bytes32 operationId = accessManager.hashOperation(timelockedOwner, address(plasmaVault), data);

        // when/then - a direct call is refused until scheduled
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId));
        vm.prank(timelockedOwner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelayExemption(accounts, true);

        // when - schedule
        uint48 executeAt = uint48(block.timestamp + TIMELOCK_24H);
        vm.prank(timelockedOwner);
        accessManager.schedule(address(plasmaVault), data, executeAt);

        // then - not applied before the delay
        assertFalse(accessManager.isRedemptionDelayExempt(depositor), "not exempt while scheduled");
        vm.warp(executeAt - 1);
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId));
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);

        // when - executed after the delay
        vm.warp(executeAt);
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayExemptionUpdated(depositor, true);
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);

        // then
        assertTrue(accessManager.isRedemptionDelayExempt(depositor), "exempt after execution");
        assertEq(accessManager.getSchedule(operationId), 0, "schedule consumed");
    }

    function testShouldGuardianCancelScheduledExemptionChange() public {
        // given
        _setupTimelockedOwner();
        address[] memory accounts = new address[](1);
        accounts[0] = depositor;
        bytes memory data = _setExemptionCalldata(accounts, true);
        bytes32 operationId = accessManager.hashOperation(timelockedOwner, address(plasmaVault), data);

        vm.prank(timelockedOwner);
        accessManager.schedule(address(plasmaVault), data, uint48(block.timestamp + TIMELOCK_24H));

        // when
        vm.prank(guardian);
        accessManager.cancel(timelockedOwner, address(plasmaVault), data);

        // then
        assertEq(accessManager.getSchedule(operationId), 0, "operation cancelled");
        vm.warp(block.timestamp + TIMELOCK_24H + 1);
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId));
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);
        assertFalse(accessManager.isRedemptionDelayExempt(depositor), "still not exempt");
    }

    // ------------------------------------------------------------------
    // The four gated operations under a non-zero vault delay
    // ------------------------------------------------------------------

    function testShouldExemptDepositorWithdrawImmediately() public {
        // given
        _exempt(depositor, true);
        _deposit(depositor, DEPOSIT_AMOUNT);

        // when - same block as the deposit
        vm.prank(depositor);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, depositor, depositor);

        // then
        assertEq(underlyingToken.balanceOf(depositor), DEPOSIT_AMOUNT / 2, "assets received");
    }

    function testShouldExemptDepositorRedeemImmediately() public {
        // given
        _exempt(depositor, true);
        _deposit(depositor, DEPOSIT_AMOUNT);
        uint256 shares = plasmaVault.balanceOf(depositor);

        // when
        vm.prank(depositor);
        plasmaVault.redeem(shares / 2, depositor, depositor);

        // then
        assertEq(plasmaVault.balanceOf(depositor), shares - shares / 2, "shares burned");
        assertGt(underlyingToken.balanceOf(depositor), 0, "assets received");
    }

    function testShouldExemptDepositorTransferImmediately() public {
        // given
        _enableTransferShares();
        _exempt(depositor, true);
        _deposit(depositor, DEPOSIT_AMOUNT);
        uint256 shares = plasmaVault.balanceOf(depositor);

        // when
        vm.prank(depositor);
        plasmaVault.transfer(receiver, shares / 2);

        // then
        assertEq(plasmaVault.balanceOf(receiver), shares / 2, "shares transferred");
    }

    function testShouldExemptDepositorTransferFromImmediately() public {
        // given - the spender never deposited, so it is unlocked on its own
        _enableTransferShares();
        _exempt(depositor, true);
        _deposit(depositor, DEPOSIT_AMOUNT);
        uint256 shares = plasmaVault.balanceOf(depositor);
        vm.prank(depositor);
        plasmaVault.approve(spender, shares);

        // when
        vm.prank(spender);
        plasmaVault.transferFrom(depositor, receiver, shares / 2);

        // then
        assertEq(plasmaVault.balanceOf(receiver), shares / 2, "shares transferred");
    }

    function testShouldRevertNonExemptDepositorWithAccountIsLocked() public {
        // given - the exemption of another account must not leak to the depositor
        _enableTransferShares();
        _exempt(other, true);
        _deposit(depositor, DEPOSIT_AMOUNT);
        uint256 unlockTime = block.timestamp + REDEMPTION_DELAY;
        uint256 shares = plasmaVault.balanceOf(depositor);
        vm.prank(depositor);
        plasmaVault.approve(spender, shares);

        // when/then
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", unlockTime));
        vm.prank(depositor);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, depositor, depositor);

        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", unlockTime));
        vm.prank(depositor);
        plasmaVault.redeem(shares / 2, depositor, depositor);

        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", unlockTime));
        vm.prank(depositor);
        plasmaVault.transfer(receiver, shares / 2);

        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", unlockTime));
        vm.prank(spender);
        plasmaVault.transferFrom(depositor, receiver, shares / 2);

        assertEq(plasmaVault.balanceOf(depositor), shares, "nothing moved");
    }

    function testShouldExemptAfterDepositThroughVault() public {
        // given - locked first, exempted later, no new deposit
        _deposit(depositor, DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", block.timestamp + REDEMPTION_DELAY));
        vm.prank(depositor);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, depositor, depositor);

        // when
        _exempt(depositor, true);

        // then
        vm.prank(depositor);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, depositor, depositor);
        assertEq(underlyingToken.balanceOf(depositor), DEPOSIT_AMOUNT / 2, "assets received");
    }

    function testShouldRelockAfterRevokeThroughVaultFromOriginalDeposit() public {
        // given
        _exempt(depositor, true);
        _deposit(depositor, DEPOSIT_AMOUNT);
        uint256 unlockTime = block.timestamp + REDEMPTION_DELAY;
        vm.prank(depositor);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 4, depositor, depositor);

        // when
        _exempt(depositor, false);

        // then - locked from the original deposit
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", unlockTime));
        vm.prank(depositor);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 4, depositor, depositor);

        // and - released once the original lock elapses
        vm.warp(unlockTime);
        vm.prank(depositor);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 4, depositor, depositor);
        assertEq(underlyingToken.balanceOf(depositor), DEPOSIT_AMOUNT / 2, "assets received");
    }

    // ------------------------------------------------------------------
    // Safety: the exemption never covers the other party of the call
    // ------------------------------------------------------------------

    function testShouldNotLetExemptSpenderMoveLockedOwnerShares() public {
        // given - a locked, non-exempt owner and an exempt spender that deposited later
        _enableTransferShares();
        _deposit(depositor, DEPOSIT_AMOUNT);
        uint256 ownerUnlockTime = block.timestamp + REDEMPTION_DELAY;
        vm.warp(block.timestamp + 1 hours);
        _deposit(spender, DEPOSIT_AMOUNT);
        _exempt(spender, true);

        uint256 shares = plasmaVault.balanceOf(depositor);
        vm.prank(depositor);
        plasmaVault.approve(spender, shares);

        // when/then - the owner's lock is what reverts, not the spender's
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", ownerUnlockTime));
        vm.prank(spender);
        plasmaVault.transferFrom(depositor, receiver, shares / 2);

        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", ownerUnlockTime));
        vm.prank(spender);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, spender, depositor);

        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", ownerUnlockTime));
        vm.prank(spender);
        plasmaVault.redeem(shares / 2, spender, depositor);

        assertEq(plasmaVault.balanceOf(depositor), shares, "owner shares untouched");
    }

    function testShouldLockNonExemptOperatorOfExemptOwnerOnTransferFrom() public {
        // given
        _enableTransferShares();
        uint256 operatorUnlockTime = _exemptOwnerAndFreshOperator();
        uint256 shares = plasmaVault.balanceOf(depositor);

        // when/then - the exempt owner does not unlock the operator
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", operatorUnlockTime));
        vm.prank(spender);
        plasmaVault.transferFrom(depositor, receiver, shares / 2);

        // and - succeeds once the operator's own delay passed
        vm.warp(operatorUnlockTime);
        vm.prank(spender);
        plasmaVault.transferFrom(depositor, receiver, shares / 2);
        assertEq(plasmaVault.balanceOf(receiver), shares / 2, "shares transferred");
    }

    function testShouldLockNonExemptOperatorOfExemptOwnerOnWithdraw() public {
        // given
        uint256 operatorUnlockTime = _exemptOwnerAndFreshOperator();

        // when/then
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", operatorUnlockTime));
        vm.prank(spender);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, receiver, depositor);

        // and
        vm.warp(operatorUnlockTime);
        vm.prank(spender);
        plasmaVault.withdraw(DEPOSIT_AMOUNT / 2, receiver, depositor);
        assertEq(underlyingToken.balanceOf(receiver), DEPOSIT_AMOUNT / 2, "assets received");
    }

    function testShouldLockNonExemptOperatorOfExemptOwnerOnRedeem() public {
        // given
        uint256 operatorUnlockTime = _exemptOwnerAndFreshOperator();
        uint256 shares = plasmaVault.balanceOf(depositor);

        // when/then
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", operatorUnlockTime));
        vm.prank(spender);
        plasmaVault.redeem(shares / 2, receiver, depositor);

        // and
        vm.warp(operatorUnlockTime);
        vm.prank(spender);
        plasmaVault.redeem(shares / 2, receiver, depositor);
        assertGt(underlyingToken.balanceOf(receiver), 0, "assets received");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Exempt owner (`depositor`) deposits; an hour later a non-exempt operator (`spender`) deposits and
    /// receives the owner's allowance. Returns the operator's unlock time.
    function _exemptOwnerAndFreshOperator() private returns (uint256 operatorUnlockTime) {
        _exempt(depositor, true);
        _deposit(depositor, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 1 hours);
        _deposit(spender, DEPOSIT_AMOUNT);
        operatorUnlockTime = block.timestamp + REDEMPTION_DELAY;

        uint256 ownerShares = plasmaVault.balanceOf(depositor);
        vm.prank(depositor);
        plasmaVault.approve(spender, ownerShares);
    }

    function _exempt(address account_, bool exempt_) private {
        address[] memory accounts = new address[](1);
        accounts[0] = account_;
        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelayExemption(accounts, exempt_);
    }

    function _enableTransferShares() private {
        vm.prank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).enableTransferShares();
    }

    function _deposit(address account_, uint256 amount_) private {
        vm.prank(owner);
        accessManager.grantRole(Roles.WHITELIST_ROLE, account_, 0);

        underlyingToken.mint(account_, amount_);
        vm.startPrank(account_);
        underlyingToken.approve(address(plasmaVault), amount_);
        plasmaVault.deposit(amount_, account_);
        vm.stopPrank();
    }

    function _setExemptionCalldata(address[] memory accounts_, bool exempt_) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IPlasmaVaultGovernance.setRedemptionDelayExemption.selector, accounts_, exempt_);
    }

    /// @dev Production-like timelock setup (see RedemptionDelayTimelockTest)
    function _setupTimelockedOwner() private {
        uint64[] memory roleIds = new uint64[](1);
        roleIds[0] = Roles.OWNER_ROLE;
        uint256[] memory delays = new uint256[](1);
        delays[0] = TIMELOCK_24H;

        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setMinimalExecutionDelaysForRoles(roleIds, delays);
        vm.prank(owner);
        accessManager.grantRole(Roles.OWNER_ROLE, timelockedOwner, uint32(TIMELOCK_24H));
        vm.prank(owner);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, guardian, 0);
    }
}
