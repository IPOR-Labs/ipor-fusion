// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {RealizeManagementFeeFuse} from "../../../contracts/fuses/management_fee/RealizeManagementFeeFuse.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {
    RealizeManagementFeeFuseForkBase,
    IForkLegacyVault,
    IForkFeeManager,
    ForkFuseAction
} from "./RealizeManagementFeeFuseForkBase.sol";

/// @title RealizeManagementFeeFuseEthUsdcF1ForkTest
/// @notice IL-8870. Live Tesseract USDC vault on Ethereum (F1 template, `totalAssets()` gross, fee accrued about
///         30 days): `execute([RealizeManagementFeeFuse])` must give the same result as the collection that a 1-unit
///         deposit performs. The roles are the live role holders, impersonated with `vm.prank`.
contract RealizeManagementFeeFuseEthUsdcF1ForkTest is RealizeManagementFeeFuseForkBase {
    /// @dev Own fork block of this suite (no other suite uses it)
    uint256 internal constant FORK_BLOCK = 26_275_000;

    address internal constant VAULT = 0x2B8252698D5276477F7Ef374aDA08F817e02cAAd;
    address internal constant TEMPLATE = 0x967fE60231eA5133F2C6516a3a14aE341c115286;
    address internal constant FEE_MANAGER = 0xeCE3a27285469788df695bB58e69A3ac6551756D;
    address internal constant ALPHA = 0x1a51aD9b8f2713aBd9a9C297fe76ab64DC27C743;
    address internal constant FUSE_MANAGER = 0x20fE2cCFb4995b8af95515fEa4083e6192818BA9;
    /// @dev holds WHITELIST_ROLE on the vault
    address internal constant WHITELISTED = 0x6c441a03b149f4CD73EAeC31F10A0f3C952f0dF2;

    Setup internal s;
    RealizeManagementFeeFuse internal fuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);
        s = Setup({
            vault: VAULT,
            feeManager: FEE_MANAGER,
            alpha: ALPHA,
            fuseManager: FUSE_MANAGER,
            depositor: WHITELISTED,
            template: TEMPLATE,
            unit: 1e6
        });
        _assertCloneTemplate(s.vault, s.template);
        fuse = _deployAndAddFuse(s);
    }

    /// @dev Would fail if the legacy path minted a different amount than the deposit-time realization, left another
    ///      clock or pending value, or did not emit ManagementFeeRealized and RealizeManagementFeeFuseEnter.
    function testShouldRealizeLikeDepositOnEthereumTesseractUsdc() public {
        Branches memory b = _runBranches(s, fuse);

        /// @dev F1: totalAssets() is gross, so the collection cannot change the assets
        assertEq(b.fuse.totalAssets, b.before.totalAssets, "totalAssets changed by the collection");
        assertLt(b.fuse.rate, b.before.rate, "collection must lower the share price");
        _assertFuseEqualsDeposit(s, b, true);
    }

    /// @dev The fee is collected out of execute by the vault itself (`execute` -> fuse delegatecall). Would fail if
    ///      the fuse kept working outside `execute` on an old vault, or if the vault already had the entry.
    function testShouldHaveNoRealizeManagementFeeInternalEntryOutsideExecute() public {
        _assertEntryAbsentOutsideExecute(s.vault);
    }

    /// @dev With the rate above the high-water mark (a donation of 1% of the assets), a performance fee is due.
    ///      Collection lowers the rate by the fee before the performance fee is computed, so the performance fee after
    ///      `execute([fuse])` is lower than after `execute([])`. Would fail if the collection did not lower the rate.
    function testShouldChargeLowerPerformanceFeeAfterCollectionThanAfterEmptyExecute() public {
        address asset = IERC4626(s.vault).asset();
        uint256 donation = IERC4626(s.vault).totalAssets() / 100;
        deal(asset, s.vault, IERC20(asset).balanceOf(s.vault) + donation);

        Branches memory b = _runBranches(s, fuse);

        assertGt(b.before.totalAssets, 0);
        assertGt(b.before.rate, b.before.highWaterMark * RATE_PROBE_MULTIPLIER, "rate must be above the HWM");
        assertGt(
            b.emptyExecute.performanceFeeShares,
            b.before.performanceFeeShares,
            "empty execute must charge a performance fee"
        );
        assertGt(
            b.fuse.performanceFeeShares,
            b.before.performanceFeeShares,
            "execute with the fuse must still charge a performance fee"
        );
        assertLt(
            b.fuse.performanceFeeShares,
            b.emptyExecute.performanceFeeShares,
            "collection must lower the performance fee"
        );
        _assertFuseEqualsDeposit(s, b, false);
    }
}

/// @title RealizeManagementFeeFuseBaseCbEthF1ForkTest
/// @notice IL-8870. Live Tesseract cbETH vault on Base (F1 template, 18-decimal asset, 0.25% fee, fee accrued about 16
///         days) and a live Base F1 vault with `feeInPercentage == 0`.
contract RealizeManagementFeeFuseBaseCbEthF1ForkTest is RealizeManagementFeeFuseForkBase {
    /// @dev Own fork block of this suite (no other suite uses it)
    uint256 internal constant FORK_BLOCK = 53_103_500;

    address internal constant VAULT = 0xfeB895C95b21F2f546D8F70e8C79CC3FD14a69eF;
    address internal constant TEMPLATE = 0x7924184350e9d555a576153Fe5fEEEC86270530a;
    address internal constant FEE_MANAGER = 0x5dc2Cd59D6BDDB8236CDbDC7E58BCE6Cd09418F3;
    address internal constant ALPHA = 0x1a51aD9b8f2713aBd9a9C297fe76ab64DC27C743;
    address internal constant FUSE_MANAGER = 0x20fE2cCFb4995b8af95515fEa4083e6192818BA9;
    /// @dev holds WHITELIST_ROLE on the vault
    address internal constant WHITELISTED = 0xa6260F0f4b4Fd74CD41d4ec6efA63184aAEA8036;

    /// @dev Live Base F1 vault (tesscbETHlp) with a management fee of 0
    address internal constant NO_FEE_VAULT = 0x3e212F136244465d8E524Fb658E6Daa1fb0593bF;
    /// @dev holds ALPHA_ROLE, FUSE_MANAGER_ROLE and ATOMIST_ROLE on NO_FEE_VAULT
    address internal constant NO_FEE_VAULT_OPERATOR = 0x580CB2bd64bbceCb40eAFf341F45A7f641Ff3119;

    Setup internal s;
    RealizeManagementFeeFuse internal fuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK);
        s = Setup({
            vault: VAULT,
            feeManager: FEE_MANAGER,
            alpha: ALPHA,
            fuseManager: FUSE_MANAGER,
            depositor: WHITELISTED,
            template: TEMPLATE,
            unit: 1e18
        });
        _assertCloneTemplate(s.vault, s.template);
        fuse = _deployAndAddFuse(s);
    }

    /// @dev Would fail if the legacy path minted a different amount than the deposit-time realization, left another
    ///      clock or pending value, or did not emit ManagementFeeRealized and RealizeManagementFeeFuseEnter.
    function testShouldRealizeLikeDepositOnBaseTesseractCbEth() public {
        Branches memory b = _runBranches(s, fuse);

        assertEq(b.fuse.totalAssets, b.before.totalAssets, "totalAssets changed by the collection");
        assertLt(b.fuse.rate, b.before.rate, "collection must lower the share price");
        _assertFuseEqualsDeposit(s, b, true);
    }

    /// @dev Would fail if the vault already had the entry (a new vault answers `WrongCaller` instead).
    function testShouldHaveNoRealizeManagementFeeInternalEntryOutsideExecute() public {
        _assertEntryAbsentOutsideExecute(s.vault);
    }

    /// @dev A vault whose management fee is 0 has nothing to collect: no mint, no clock move, no event of the fuse
    ///      and no ManagementFeeRealized. Would fail if the fuse minted or emitted for a zero fee.
    function testShouldChangeNothingOnVaultWithoutManagementFee() public {
        _assertCloneTemplate(NO_FEE_VAULT, TEMPLATE);
        (address feeAccount, uint16 feeInPercentage, uint32 clockBefore) = IForkLegacyVault(NO_FEE_VAULT)
            .getManagementFeeData();
        assertEq(feeInPercentage, 0, "the vault must have no management fee");
        assertGt(IERC20(NO_FEE_VAULT).totalSupply(), 0, "the vault must have shares");
        assertEq(IForkLegacyVault(NO_FEE_VAULT).getUnrealizedManagementFee(), 0, "no fee can accrue");

        Setup memory noFee = Setup({
            vault: NO_FEE_VAULT,
            feeManager: address(0),
            alpha: NO_FEE_VAULT_OPERATOR,
            fuseManager: NO_FEE_VAULT_OPERATOR,
            depositor: address(0),
            template: TEMPLATE,
            unit: 1e18
        });
        RealizeManagementFeeFuse noFeeFuse = _deployAndAddFuse(noFee);

        uint256 feeAccountSharesBefore = IERC20(NO_FEE_VAULT).balanceOf(feeAccount);
        uint256 supplyBefore = IERC20(NO_FEE_VAULT).totalSupply();

        vm.recordLogs();
        _execute(noFee, noFeeFuse, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (, , uint32 clockAfter) = IForkLegacyVault(NO_FEE_VAULT).getManagementFeeData();
        assertEq(clockAfter, clockBefore, "clock moved");
        assertEq(IERC20(NO_FEE_VAULT).balanceOf(feeAccount), feeAccountSharesBefore, "fee account shares changed");
        assertEq(IERC20(NO_FEE_VAULT).totalSupply(), supplyBefore, "supply changed");
        assertEq(_countLogs(logs, NO_FEE_VAULT, ManagementFeeRealized.selector), 0, "ManagementFeeRealized emitted");
        assertEq(_countLogs(logs, NO_FEE_VAULT, RealizeManagementFeeFuseEnter.selector), 0, "fuse event emitted");
    }
}

/// @title RealizeManagementFeeFuseEthF0ForkBase
/// @notice IL-8870. F0 vault (template of the 2026-02-11 migration, `totalAssets()` NET of the accrued fee) cloned from
///         the live FusionFactory at a block inside the F0 window (the factory template was
///         0xfB696D...7541 from before block 24 434 147 until 24 742 518). Fee 0.3%, performance fee 2% (DAO package 1),
///         18-decimal asset so the share price resolves the second-order effect of D-007.
/// @dev Every concrete suite forks its own block inside the F0 window (none is shared with another suite, for example
///      the Midas suite at 24_500_000) and has at most one test that warps; the warp is `_accrue()` inside that test.
abstract contract RealizeManagementFeeFuseEthF0ForkBase is RealizeManagementFeeFuseForkBase {
    address internal constant FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address internal constant F0_TEMPLATE = 0xfB696Db7a9Da52b7225c61EdFb56537544307541;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    uint256 internal constant DAO_FEE_PACKAGE = 1;

    uint256 internal constant DEPOSIT = 1_000_000e18;
    uint256 internal constant ACCRUAL = 30 days;

    address internal owner = makeAddr("owner");
    address internal atomist = makeAddr("atomist");

    Setup internal s;
    RealizeManagementFeeFuse internal fuse;
    address internal accessManager;

    /// @notice Fork block of the concrete suite; must lie inside the F0 window (the factory template is asserted)
    function _forkBlock() internal pure virtual returns (uint256);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _forkBlock());

        FusionFactoryStorageLib.BaseAddresses memory bases = FusionFactory(FACTORY).getBaseAddresses();
        assertEq(bases.plasmaVaultCoreBase, F0_TEMPLATE, "the factory is outside the F0 window");

        FusionFactoryLogicLib.FusionInstance memory instance = FusionFactory(FACTORY).clone(
            "F0 fork",
            "F0F",
            DAI,
            0,
            owner,
            DAO_FEE_PACKAGE
        );
        accessManager = instance.accessManager;

        s = Setup({
            vault: instance.plasmaVault,
            feeManager: instance.feeManager,
            alpha: makeAddr("alpha"),
            fuseManager: makeAddr("fuseManager"),
            depositor: makeAddr("depositor"),
            template: F0_TEMPLATE,
            unit: 1e18
        });
        _assertCloneTemplate(s.vault, s.template);

        vm.prank(owner);
        IporFusionAccessManager(accessManager).grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.startPrank(atomist);
        IporFusionAccessManager(accessManager).grantRole(Roles.ALPHA_ROLE, s.alpha, 0);
        IporFusionAccessManager(accessManager).grantRole(Roles.FUSE_MANAGER_ROLE, s.fuseManager, 0);
        IporFusionAccessManager(accessManager).grantRole(Roles.WHITELIST_ROLE, s.depositor, 0);
        vm.stopPrank();

        fuse = _deployAndAddFuse(s);

        /// @dev the first deposit starts the fee accrual (an empty vault accrues nothing)
        deal(DAI, s.depositor, DEPOSIT);
        vm.startPrank(s.depositor);
        IERC20(DAI).approve(s.vault, DEPOSIT);
        IForkLegacyVault(s.vault).deposit(DEPOSIT, s.depositor);
        vm.stopPrank();
    }

    /// @notice Lets the fee accrue; the only warp of a suite, called by its single warping test
    function _accrue() internal {
        vm.warp(vm.getBlockTimestamp() + ACCRUAL);
    }
}

/// @title RealizeManagementFeeFuseEthF0ForkTest
/// @notice IL-8870. F0 fuse equals the deposit-time realization (single warping test) and the entry is absent outside
///         `execute`.
contract RealizeManagementFeeFuseEthF0ForkTest is RealizeManagementFeeFuseEthF0ForkBase {
    function _forkBlock() internal pure override returns (uint256) {
        /// @dev Own fork block of this suite; inside the F0 window of the factory
        return 24_520_000;
    }

    /// @dev F0 reports `totalAssets()` net of the accrued fee; after the collection (fee clock moved) it is gross. Also
    ///      the fuse equals the deposit-time realization. Would fail if the suite ran on a family that is not F0, or
    ///      if the fuse priced the shares on another basis than the deposit (net assets).
    function testShouldRealizeLikeDepositOnEthereumF0() public {
        _accrue();
        Branches memory b = _runBranches(s, fuse);

        assertEq(b.before.totalAssets, DEPOSIT - b.unrealizedFeeBefore, "F0 totalAssets() is not net of the fee");
        assertEq(b.fuse.totalAssets, DEPOSIT, "after the collection totalAssets() is gross");
        assertEq(b.deposit.totalAssets, DEPOSIT + s.unit, "deposit: totalAssets() is gross after the collection");
        _assertFuseEqualsDeposit(s, b, true);
    }

    /// @dev Would fail if the vault already had the entry.
    function testShouldHaveNoRealizeManagementFeeInternalEntryOutsideExecute() public {
        _assertEntryAbsentOutsideExecute(s.vault);
    }
}

/// @title RealizeManagementFeeFuseEthF0HighWaterMarkForkTest
/// @notice IL-8870. D-007 on F0 at the high-water mark (single warping test, own fork block).
contract RealizeManagementFeeFuseEthF0HighWaterMarkForkTest is RealizeManagementFeeFuseEthF0ForkBase {
    function _forkBlock() internal pure override returns (uint256) {
        /// @dev Own fork block of this suite; inside the F0 window of the factory
        return 24_600_000;
    }

    /// @dev D-007 (Pete, option a): on F0 the fuse follows the deposit-time order, which lifts the unit price by about
    ///      (F/G)^2. At the high-water mark this can charge a dust performance fee that an empty `execute` does not.
    ///      Asserts: (1) `execute([])` at the HWM charges nothing; (2) the fuse charges a performance fee equal to the
    ///      branch "deposit 1 unit, then `execute([])`"; (3) the rate after the collection exceeds the rate before by
    ///      about rate * (F/G)^2. Would fail if the fuse priced on another basis (no rate lift or another fee).
    function testShouldChargeSamePerformanceFeeAsDepositThenEmptyExecuteAtHighWaterMark() public {
        _accrue();

        /// @dev HWM = the current (net) rate
        vm.prank(owner);
        IForkFeeManager(s.feeManager).updateHighWaterMarkPerformanceFee();

        HighWaterMarkBranches memory h;
        h.before = _snapshot(s);
        h.fee = IForkLegacyVault(s.vault).getUnrealizedManagementFee();
        assertApproxEqAbs(
            h.before.highWaterMark * RATE_PROBE_MULTIPLIER,
            h.before.rate,
            RATE_PROBE_MULTIPLIER,
            "HWM must equal the current rate"
        );

        uint256 id = vm.snapshotState();

        /// @dev branch 3: empty execute at the HWM
        _execute(s, fuse, false);
        h.emptyExecute = _snapshot(s);
        vm.revertToState(id);
        id = vm.snapshotState();

        /// @dev branch 1: the fuse
        _execute(s, fuse, true);
        h.viaFuse = _snapshot(s);
        vm.revertToState(id);
        id = vm.snapshotState();

        /// @dev branch 4: deposit 1 unit, then an empty execute
        _depositOneUnit(s);
        _execute(s, fuse, false);
        h.depositThenEmpty = _snapshot(s);
        vm.revertToState(id);

        _assertHighWaterMarkBranches(h);
    }

    struct HighWaterMarkBranches {
        Snapshot before;
        Snapshot emptyExecute;
        Snapshot viaFuse;
        Snapshot depositThenEmpty;
        uint256 fee;
    }

    function _assertHighWaterMarkBranches(HighWaterMarkBranches memory h_) internal {
        assertEq(
            h_.emptyExecute.performanceFeeShares,
            h_.before.performanceFeeShares,
            "an empty execute at the HWM must charge no performance fee"
        );
        uint256 feeByFuse = h_.viaFuse.performanceFeeShares - h_.before.performanceFeeShares;
        uint256 feeByDeposit = h_.depositThenEmpty.performanceFeeShares - h_.before.performanceFeeShares;
        assertGt(feeByFuse, 0, "the F0 order must charge a dust performance fee at the HWM");
        assertApproxEqRel(feeByFuse, feeByDeposit, 1e15, "performance fee: fuse != deposit then empty execute");

        /// @dev rate lift (F/G)^2, G = gross assets = DEPOSIT
        assertGt(h_.viaFuse.rate, h_.before.rate, "F0 order must lift the rate");
        uint256 expectedLift = (h_.before.rate * h_.fee * h_.fee) / (DEPOSIT * DEPOSIT);
        assertApproxEqRel(
            h_.viaFuse.rate - h_.before.rate,
            expectedLift,
            5e16,
            "rate lift is not about rate * (F/G)^2"
        );
    }
}
