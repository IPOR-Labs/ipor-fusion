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
import {PlasmaVault, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";

/// @title RedemptionDelayTimelockTest
/// @notice Proves that the IL-7910 redemption delay setter can be put behind the OWNER_ROLE timelock.
/// @dev Uses a vault created by FusionFactory (local, no fork) so the role wiring produced by
/// IporFusionAccessManagerInitializerLibV1 is exercised end-to-end:
///      - PlasmaVaultGovernance.setRedemptionDelay is the OWNER_ROLE entry point on the vault target,
///      - IporFusionAccessManager.setRedemptionDelay is reserved for the vault (TECH_PLASMA_VAULT_ROLE).
///      An owner granted with an execution delay must schedule the change, wait, then execute - and a
///      guardian may cancel it - exactly like every other governance function. The entry point cannot
///      live on the access manager itself: OpenZeppelin AccessManager refuses to schedule/execute its own
///      custom functions (only the built-in admin selectors are recognised when the target is the manager),
///      so a setter restricted there to the OWNER_ROLE would be immediate for owners without a delay and
///      unusable for owners with one.
contract RedemptionDelayTimelockTest is Test {
    uint256 private constant TIMELOCK_24H = 24 hours;
    uint256 private constant INITIAL_REDEMPTION_DELAY = 1 days;
    uint256 private constant NEW_REDEMPTION_DELAY = 3 days;
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
    address private depositor;
    address private daoFeeRecipient;
    address private daoFeeManager;
    address private maintenanceManager;

    IporFusionAccessManager private accessManager;
    PlasmaVault private plasmaVault;

    event RedemptionDelayUpdated(uint256 oldRedemptionDelayInSeconds, uint256 newRedemptionDelayInSeconds);

    function setUp() public {
        owner = makeAddr("owner");
        timelockedOwner = makeAddr("timelockedOwner");
        guardian = makeAddr("guardian");
        atomist = makeAddr("atomist");
        depositor = makeAddr("depositor");
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

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Vault",
            "TVAULT",
            address(underlyingToken),
            INITIAL_REDEMPTION_DELAY,
            owner,
            0
        );

        accessManager = IporFusionAccessManager(instance.accessManager);
        plasmaVault = PlasmaVault(payable(instance.plasmaVault));
    }

    function testShouldFactoryWireRedemptionDelaySetterForTimelock() public view {
        // then - the owner-facing entry point is on the vault target, the access manager one is vault-only
        assertEq(
            accessManager.getTargetFunctionRole(
                address(plasmaVault),
                IPlasmaVaultGovernance.setRedemptionDelay.selector
            ),
            Roles.OWNER_ROLE,
            "PlasmaVaultGovernance.setRedemptionDelay should be OWNER_ROLE restricted"
        );
        assertEq(
            accessManager.getTargetFunctionRole(
                address(accessManager),
                IporFusionAccessManager.setRedemptionDelay.selector
            ),
            Roles.TECH_PLASMA_VAULT_ROLE,
            "IporFusionAccessManager.setRedemptionDelay should be TECH_PLASMA_VAULT_ROLE restricted"
        );
        assertEq(
            accessManager.getRoleGuardian(Roles.OWNER_ROLE),
            Roles.GUARDIAN_ROLE,
            "GUARDIAN_ROLE should be able to cancel scheduled OWNER_ROLE operations"
        );
    }

    function testShouldOwnerWithoutExecutionDelaySetRedemptionDelayImmediatelyThroughVault() public {
        // given
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), INITIAL_REDEMPTION_DELAY);

        // when
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayUpdated(INITIAL_REDEMPTION_DELAY, NEW_REDEMPTION_DELAY);
        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelay(NEW_REDEMPTION_DELAY);

        // then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), NEW_REDEMPTION_DELAY);
    }

    function testShouldRequireScheduleAndWaitForOwnerWithExecutionDelay() public {
        // given
        _setupTimelockedOwner();

        bytes memory data = _setRedemptionDelayCalldata(NEW_REDEMPTION_DELAY);
        bytes32 operationId = accessManager.hashOperation(timelockedOwner, address(plasmaVault), data);

        // when/then - a direct call by the timelocked owner is refused until the operation is scheduled
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId));
        vm.prank(timelockedOwner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelay(NEW_REDEMPTION_DELAY);

        // when - the owner schedules the change on the vault target
        uint48 executeAt = uint48(block.timestamp + TIMELOCK_24H);
        vm.prank(timelockedOwner);
        (bytes32 scheduledOperationId, ) = accessManager.schedule(address(plasmaVault), data, executeAt);

        // then
        assertEq(scheduledOperationId, operationId, "scheduled operation id");
        assertEq(accessManager.getSchedule(operationId), executeAt, "operation should be scheduled");
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), INITIAL_REDEMPTION_DELAY, "unchanged until executed");

        // when/then - execution before the delay elapses is refused
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId));
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);

        vm.warp(executeAt - 1);
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId));
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);

        // when - the delay elapsed, the owner executes the scheduled change
        vm.warp(executeAt);
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayUpdated(INITIAL_REDEMPTION_DELAY, NEW_REDEMPTION_DELAY);
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);

        // then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), NEW_REDEMPTION_DELAY);
        assertEq(accessManager.getSchedule(operationId), 0, "schedule should be consumed");

        // and - the consumed schedule cannot be replayed
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId));
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);
    }

    function testShouldConsumeScheduledRedemptionDelayChangeByDirectCallAfterDelay() public {
        // given
        _setupTimelockedOwner();

        bytes memory data = _setRedemptionDelayCalldata(NEW_REDEMPTION_DELAY);
        bytes32 operationId = accessManager.hashOperation(timelockedOwner, address(plasmaVault), data);

        vm.prank(timelockedOwner);
        accessManager.schedule(address(plasmaVault), data, uint48(block.timestamp + TIMELOCK_24H));

        vm.warp(block.timestamp + TIMELOCK_24H);

        // when - calling the vault directly consumes the scheduled operation (AccessManaged flow)
        vm.prank(timelockedOwner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelay(NEW_REDEMPTION_DELAY);

        // then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), NEW_REDEMPTION_DELAY);
        assertEq(accessManager.getSchedule(operationId), 0, "schedule should be consumed");
    }

    function testShouldGuardianCancelScheduledRedemptionDelayChange() public {
        // given
        _setupTimelockedOwner();

        bytes memory data = _setRedemptionDelayCalldata(0);
        bytes32 operationId = accessManager.hashOperation(timelockedOwner, address(plasmaVault), data);

        vm.prank(timelockedOwner);
        (, uint32 scheduleNonce) = accessManager.schedule(
            address(plasmaVault),
            data,
            uint48(block.timestamp + TIMELOCK_24H)
        );

        // when
        vm.prank(guardian);
        uint32 cancelNonce = accessManager.cancel(timelockedOwner, address(plasmaVault), data);

        // then
        assertEq(cancelNonce, scheduleNonce, "cancel nonce should match schedule nonce");
        assertEq(accessManager.getSchedule(operationId), 0, "operation should be cancelled");

        vm.warp(block.timestamp + TIMELOCK_24H + 1);

        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId));
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);

        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId));
        vm.prank(timelockedOwner);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelay(0);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), INITIAL_REDEMPTION_DELAY, "delay should be unchanged");
    }

    function testShouldNotScheduleRedemptionDelayChangeEarlierThanExecutionDelay() public {
        // given
        _setupTimelockedOwner();

        bytes memory data = _setRedemptionDelayCalldata(NEW_REDEMPTION_DELAY);

        // when/then
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessManagerUnauthorizedCall(address,address,bytes4)",
                timelockedOwner,
                address(plasmaVault),
                IPlasmaVaultGovernance.setRedemptionDelay.selector
            )
        );
        vm.prank(timelockedOwner);
        accessManager.schedule(address(plasmaVault), data, uint48(block.timestamp + TIMELOCK_24H - 1));
    }

    function testShouldNotGrantOwnerRoleBelowMinimalExecutionDelay() public {
        // given - the minimal execution delay makes every future owner timelocked
        _setupTimelockedOwner();
        address anotherOwner = makeAddr("anotherOwner");

        // when/then
        vm.expectRevert(
            abi.encodeWithSignature("TooShortExecutionDelayForRole(uint64,uint32)", Roles.OWNER_ROLE, uint32(1 hours))
        );
        vm.prank(owner);
        accessManager.grantRole(Roles.OWNER_ROLE, anotherOwner, uint32(1 hours));
    }

    function testShouldNotScheduleRedemptionDelayChangeWhenNotOwner() public {
        // given
        _setupTimelockedOwner();

        vm.prank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);

        bytes memory data = _setRedemptionDelayCalldata(NEW_REDEMPTION_DELAY);

        // when/then
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessManagerUnauthorizedCall(address,address,bytes4)",
                atomist,
                address(plasmaVault),
                IPlasmaVaultGovernance.setRedemptionDelay.selector
            )
        );
        vm.prank(atomist);
        accessManager.schedule(address(plasmaVault), data, uint48(block.timestamp + TIMELOCK_24H));

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", atomist));
        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).setRedemptionDelay(NEW_REDEMPTION_DELAY);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), INITIAL_REDEMPTION_DELAY);
    }

    function testShouldNotBypassTimelockByCallingAccessManagerDirectly() public {
        // given - the reviewer's scenario: an owner going straight to the access manager
        _setupTimelockedOwner();

        bytes memory accessManagerData = abi.encodeWithSelector(
            IporFusionAccessManager.setRedemptionDelay.selector,
            NEW_REDEMPTION_DELAY
        );

        // when/then - the access manager setter is reserved for the vault, for every owner
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", timelockedOwner));
        vm.prank(timelockedOwner);
        accessManager.setRedemptionDelay(NEW_REDEMPTION_DELAY);

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", owner));
        vm.prank(owner);
        accessManager.setRedemptionDelay(NEW_REDEMPTION_DELAY);

        // and - AccessManager cannot schedule its own custom functions at all, which is why the
        // timelock-capable entry point has to live on the vault
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessManagerUnauthorizedCall(address,address,bytes4)",
                timelockedOwner,
                address(accessManager),
                IporFusionAccessManager.setRedemptionDelay.selector
            )
        );
        vm.prank(timelockedOwner);
        accessManager.schedule(address(accessManager), accessManagerData, uint48(block.timestamp + TIMELOCK_24H));

        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessManagerUnauthorizedCall(address,address,bytes4)",
                timelockedOwner,
                address(accessManager),
                IporFusionAccessManager.setRedemptionDelay.selector
            )
        );
        vm.prank(timelockedOwner);
        accessManager.execute(address(accessManager), accessManagerData);

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), INITIAL_REDEMPTION_DELAY);
    }

    function testShouldMoveExistingDepositorLockWhenTimelockedChangeExecutes() public {
        // given - a depositor locked under the initial 1 day delay
        _setupTimelockedOwner();
        _whitelistAndDeposit();

        uint256 depositTimestamp = block.timestamp;
        assertEq(accessManager.getAccountLockTime(depositor), depositTimestamp + INITIAL_REDEMPTION_DELAY);

        bytes memory data = _setRedemptionDelayCalldata(NEW_REDEMPTION_DELAY);

        vm.prank(timelockedOwner);
        accessManager.schedule(address(plasmaVault), data, uint48(block.timestamp + TIMELOCK_24H));

        // when - the raise executes exactly when the depositor's original lock would have expired
        vm.warp(depositTimestamp + TIMELOCK_24H);
        vm.prank(timelockedOwner);
        accessManager.execute(address(plasmaVault), data);

        // then - the lock is extended, measured from the depositor's own deposit
        assertEq(accessManager.getAccountLockTime(depositor), depositTimestamp + NEW_REDEMPTION_DELAY);

        uint256 shares = plasmaVault.balanceOf(depositor);
        uint256 sharesToRedeem = shares / 2;

        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTimestamp + NEW_REDEMPTION_DELAY));
        vm.prank(depositor);
        plasmaVault.redeem(sharesToRedeem, depositor, depositor);

        // and - releases once the new delay elapses from the original deposit
        vm.warp(depositTimestamp + NEW_REDEMPTION_DELAY);
        vm.prank(depositor);
        plasmaVault.redeem(sharesToRedeem, depositor, depositor);

        assertEq(plasmaVault.balanceOf(depositor), shares - sharesToRedeem);
    }

    /// @dev Production-like timelock setup: the bootstrapping owner (no delay) raises the minimal execution
    /// delay for OWNER_ROLE, grants a timelocked owner and a guardian
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

        (bool isOwner, uint32 executionDelay) = accessManager.hasRole(Roles.OWNER_ROLE, timelockedOwner);
        assertTrue(isOwner, "timelocked owner should hold OWNER_ROLE");
        assertEq(executionDelay, uint32(TIMELOCK_24H), "timelocked owner should have the execution delay");
    }

    function _whitelistAndDeposit() private {
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        underlyingToken.mint(depositor, DEPOSIT_AMOUNT);

        vm.startPrank(depositor);
        underlyingToken.approve(address(plasmaVault), DEPOSIT_AMOUNT);
        plasmaVault.deposit(DEPOSIT_AMOUNT, depositor);
        vm.stopPrank();
    }

    function _setRedemptionDelayCalldata(uint256 redemptionDelayInSeconds_) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IPlasmaVaultGovernance.setRedemptionDelay.selector, redemptionDelayInSeconds_);
    }
}
