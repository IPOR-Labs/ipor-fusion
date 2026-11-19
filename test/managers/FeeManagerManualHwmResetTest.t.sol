// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title Manual HWM reset below the stored mark (IL-9637, Olympix L06)
/// @notice Pins the "Reset high watermark" feature (IL-6921): updateHighWaterMarkPerformanceFee also lowers the HWM
///         to the current rate, so the recovery back to the old mark is charged again. Only the role mapped to the
///         function (OWNER_ROLE, as in IporFusionAccessManagerInitializerLibV1) can do it, and an owner granted with
///         an execution delay has to schedule it in the access manager, where GUARDIAN_ROLE can cancel it.
/// @dev Pinning test: the behaviour is intended and the same on the base commit. Rates are compared with the HWM in
///      the unit the FeeManager keeps it in (the scale is read from HIGH_WATER_MARK_SCALE(), 1 before IL-9601).
contract FeeManagerManualHwmResetTest is Test {
    event HighWaterMarkPerformanceFeeUpdated(uint128 highWaterMark);

    address public atomist = address(this);
    address public alpha = address(0x1);
    address public owner = address(0x0A11);
    address public timelockedOwner = address(0x0A12);
    address public guardian = address(0x0A13);
    address public user = address(0xA11CE);

    /// @dev 20% performance fee, all of it the IPOR DAO share (FeeManager percentages use 2 decimals, 10000 = 100%)
    uint256 public constant PERFORMANCE_FEE = 2000;
    uint32 public constant OWNER_EXECUTION_DELAY = 1 days;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    FeeManager public feeManager;
    address public performanceFeeAccount;
    uint256 public oneShare;
    uint256 public userDeposit;

    function setUp() public {
        _deployVault();
        _deposit();
    }

    /// @dev After a crystallized gain and a 30% loss the owner lowers the HWM to the current rate and the event
    ///      carries it; other callers, ALPHA_ROLE included, are refused
    function testShouldLowerHighWaterMarkBelowStoredOnlyByOwner() public {
        asset.mint(address(plasmaVault), userDeposit / 10);
        _crystallize();
        uint256 storedHighWaterMark = _hwm();
        _loss((plasmaVault.totalAssets() * 3) / 10);
        uint256 rate = _rate();
        assertLt(rate, storedHighWaterMark, "precondition: rate below the stored HWM");

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", user));
        vm.prank(user);
        feeManager.updateHighWaterMarkPerformanceFee();

        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", alpha));
        vm.prank(alpha);
        feeManager.updateHighWaterMarkPerformanceFee();

        assertEq(_hwm(), storedHighWaterMark, "refused callers leave the HWM");

        vm.expectEmit(address(feeManager));
        emit HighWaterMarkPerformanceFeeUpdated(uint128(rate));
        vm.prank(owner);
        feeManager.updateHighWaterMarkPerformanceFee();

        assertEq(_hwm(), rate, "owner lowered the HWM to the current rate");
    }

    /// @dev The recovery from a loss back to the old mark: fee-free without the reset (updateInterval 0 keeps the
    ///      HWM at the peak), charged at 20% after the owner lowered the HWM
    function testShouldChargeRecoveryAgainAfterManualResetBelowStored() public {
        uint256 storedHighWaterMark = _hwm();
        uint256 loss = userDeposit / 5;
        _loss(loss);
        uint256 recovery = loss / 2;

        uint256 snapshot = vm.snapshotState();

        asset.mint(address(plasmaVault), recovery);
        _crystallize();
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "without the reset the recovery is fee-free");
        assertEq(_hwm(), storedHighWaterMark, "without the reset the HWM stays at the peak");

        vm.revertToState(snapshot);

        vm.prank(owner);
        feeManager.updateHighWaterMarkPerformanceFee();
        assertLt(_hwm(), storedHighWaterMark, "the reset lowered the HWM");

        asset.mint(address(plasmaVault), recovery);
        _crystallize();

        uint256 feeShares = plasmaVault.balanceOf(performanceFeeAccount);
        assertGt(feeShares, 0, "after the reset the recovery is charged");
        assertApproxEqRel(
            plasmaVault.convertToAssets(feeShares),
            (recovery * PERFORMANCE_FEE) / 10000,
            1e14,
            "the fee shares are worth 20% of the recovery"
        );
    }

    /// @dev An owner granted with an execution delay cannot reset directly: the reset is scheduled, cannot run before
    ///      the delay and lowers the HWM when executed after it
    function testShouldRequireScheduleForOwnerWithExecutionDelay() public {
        _grantTimelockedOwner();
        uint256 storedHighWaterMark = _hwm();
        _loss(userDeposit / 2);
        uint256 rate = _rate();

        bytes memory data = abi.encodeWithSelector(FeeManager.updateHighWaterMarkPerformanceFee.selector);
        bytes32 operationId = accessManager.hashOperation(timelockedOwner, address(feeManager), data);

        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId));
        vm.prank(timelockedOwner);
        feeManager.updateHighWaterMarkPerformanceFee();

        uint48 executeAt = uint48(block.timestamp + OWNER_EXECUTION_DELAY);
        vm.prank(timelockedOwner);
        accessManager.schedule(address(feeManager), data, executeAt);
        assertEq(accessManager.getSchedule(operationId), executeAt, "the reset is scheduled and public");

        vm.warp(executeAt - 1);
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId));
        vm.prank(timelockedOwner);
        accessManager.execute(address(feeManager), data);
        assertEq(_hwm(), storedHighWaterMark, "HWM unchanged before the delay elapsed");

        vm.warp(executeAt);
        vm.prank(timelockedOwner);
        accessManager.execute(address(feeManager), data);

        assertEq(_hwm(), rate, "the scheduled reset lowered the HWM");
        assertEq(accessManager.getSchedule(operationId), 0, "the schedule is consumed");
    }

    /// @dev GUARDIAN_ROLE, the guardian of OWNER_ROLE, cancels a scheduled reset before it runs
    function testShouldLetGuardianCancelScheduledManualReset() public {
        _grantTimelockedOwner();
        uint256 storedHighWaterMark = _hwm();
        _loss(userDeposit / 2);

        bytes memory data = abi.encodeWithSelector(FeeManager.updateHighWaterMarkPerformanceFee.selector);
        bytes32 operationId = accessManager.hashOperation(timelockedOwner, address(feeManager), data);
        vm.prank(timelockedOwner);
        accessManager.schedule(address(feeManager), data, uint48(block.timestamp + OWNER_EXECUTION_DELAY));

        vm.prank(guardian);
        accessManager.cancel(timelockedOwner, address(feeManager), data);
        assertEq(accessManager.getSchedule(operationId), 0, "the schedule is cancelled");

        vm.warp(block.timestamp + OWNER_EXECUTION_DELAY);
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId));
        vm.prank(timelockedOwner);
        accessManager.execute(address(feeManager), data);

        assertEq(_hwm(), storedHighWaterMark, "the cancelled reset left the HWM");
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev OWNER_ROLE with an execution delay; GUARDIAN_ROLE guards OWNER_ROLE as after IporFusionAccessManager
    ///      initialize (every role mapped to a function gets GUARDIAN_ROLE as its guardian); the guardian account
    ///      holds only GUARDIAN_ROLE, so its cancel is not an admin cancel
    function _grantTimelockedOwner() internal {
        accessManager.grantRole(Roles.OWNER_ROLE, timelockedOwner, OWNER_EXECUTION_DELAY);
        accessManager.setRoleGuardian(Roles.OWNER_ROLE, Roles.GUARDIAN_ROLE);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, guardian, 0);
    }

    /// @dev Share price in the HWM unit: assets per 10 ** decimals() shares times the FeeManager rate scale
    function _rate() internal view returns (uint256) {
        return plasmaVault.convertToAssets(oneShare * _hwmScale());
    }

    /// @dev HIGH_WATER_MARK_SCALE() of the FeeManager (IL-9601); 1 on a FeeManager without it
    function _hwmScale() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(feeManager).staticcall(
            abi.encodeWithSignature("HIGH_WATER_MARK_SCALE()")
        );
        return ok && data.length == 32 ? abi.decode(data, (uint256)) : 1;
    }

    function _hwm() internal view returns (uint256) {
        return feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
    }

    function _crystallize() internal {
        vm.prank(alpha);
        plasmaVault.execute(new FuseAction[](0));
    }

    function _loss(uint256 amount_) internal {
        vm.prank(address(plasmaVault));
        asset.transfer(address(0xdead), amount_);
    }

    function _deposit() internal {
        asset.mint(user, userDeposit);
        vm.startPrank(user);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(userDeposit, user);
        vm.stopPrank();
    }

    function _deployVault() internal {
        asset = new MockERC20Decimals("Mock Asset", "mA", 6);
        userDeposit = 1_000_000 * 10 ** 6;

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mA",
                "ipfmA",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({marketId: 1, fuse: address(new ZeroBalanceFuse(1))});
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            balanceFuses,
            new MarketSubstratesConfig[](0)
        );

        performanceFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        feeManager = FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER());
        oneShare = 10 ** uint256(plasmaVault.decimals());

        /// @dev The production initializer (IporFusionAccessManagerInitializerLibV1) maps the reset to OWNER_ROLE;
        ///      RoleLib maps it to ALPHA_ROLE
        bytes4[] memory resetSig = new bytes4[](1);
        resetSig[0] = FeeManager.updateHighWaterMarkPerformanceFee.selector;
        accessManager.setTargetFunctionRole(address(feeManager), resetSig, Roles.OWNER_ROLE);
        accessManager.grantRole(Roles.OWNER_ROLE, owner, 0);
    }
}
