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
    IForkFeeManager
} from "./RealizeManagementFeeFuseForkBase.sol";

/// @title RealizeManagementFeeFuseCloneForkBase
/// @notice IL-8870. Shared setup of the Arbitrum, Ink and HyperEVM fork suites: a vault cloned from the live
///         FusionFactory (the template is asserted), the roles granted the way a factory owner does it (owner grants
///         ATOMIST, ATOMIST grants ALPHA, FUSE_MANAGER and WHITELIST), and the fuse added by the FUSE_MANAGER.
/// @dev Every concrete suite has its own fork block and at most one warp phase, which runs in `setUp`.
abstract contract RealizeManagementFeeFuseCloneForkBase is RealizeManagementFeeFuseForkBase {
    /// @dev Index of the DAO fee package (management fee 0.3%, performance fee 2%) that all live factories offer
    uint256 internal constant DAO_FEE_PACKAGE = 1;

    address internal owner = makeAddr("owner");
    address internal atomist = makeAddr("atomist");

    Setup internal s;
    RealizeManagementFeeFuse internal fuse;
    address internal accessManager;

    /// @notice Clones a vault from `factory_`, grants the roles and adds the fuse
    /// @dev `owner` is the initial owner of the clone. Fails when the factory's current template is not `template_`.
    function _cloneAndConfigure(address factory_, address template_, address asset_, uint256 unit_) internal {
        FusionFactoryStorageLib.BaseAddresses memory bases = FusionFactory(factory_).getBaseAddresses();
        assertEq(bases.plasmaVaultCoreBase, template_, "the factory template is not the expected family");

        FusionFactoryLogicLib.FusionInstance memory instance = FusionFactory(factory_).clone(
            "IL-8870 fork",
            "IL8870",
            asset_,
            0,
            owner,
            DAO_FEE_PACKAGE
        );

        _configure(instance.plasmaVault, instance.feeManager, instance.accessManager, template_, unit_);
    }

    /// @notice Grants the roles on an existing vault (its `owner_` holds OWNER_ROLE) and adds the fuse
    function _configure(
        address vault_,
        address feeManager_,
        address accessManager_,
        address template_,
        uint256 unit_
    ) internal {
        accessManager = accessManager_;
        s = Setup({
            vault: vault_,
            feeManager: feeManager_,
            alpha: makeAddr("alpha"),
            fuseManager: makeAddr("fuseManager"),
            depositor: makeAddr("depositor"),
            template: template_,
            unit: unit_
        });
        _assertCloneTemplate(s.vault, s.template);

        _grantAtomist();
        vm.startPrank(atomist);
        IporFusionAccessManager(accessManager).grantRole(Roles.ALPHA_ROLE, s.alpha, 0);
        IporFusionAccessManager(accessManager).grantRole(Roles.FUSE_MANAGER_ROLE, s.fuseManager, 0);
        IporFusionAccessManager(accessManager).grantRole(Roles.WHITELIST_ROLE, s.depositor, 0);
        vm.stopPrank();

        fuse = _deployAndAddFuse(s);
    }

    /// @notice The owner grants ATOMIST_ROLE to `atomist`
    function _grantAtomist() internal virtual {
        vm.prank(owner);
        IporFusionAccessManager(accessManager).grantRole(Roles.ATOMIST_ROLE, atomist, 0);
    }

    /// @notice The whitelisted depositor deposits `amount_` of the asset (dealt first)
    function _deposit(uint256 amount_) internal {
        address asset = IERC4626(s.vault).asset();
        deal(asset, s.depositor, amount_);
        vm.startPrank(s.depositor);
        IERC20(asset).approve(s.vault, amount_);
        IForkLegacyVault(s.vault).deposit(amount_, s.depositor);
        vm.stopPrank();
    }

    /// @notice Donates `amount_` of the asset to the vault: assets without shares, so one share is worth far more
    ///         than one asset unit and a small fee converts to zero shares
    function _donate(uint256 amount_) internal {
        address asset = IERC4626(s.vault).asset();
        deal(asset, s.vault, IERC20(asset).balanceOf(s.vault) + amount_);
    }

    /// @notice Sets the high-water mark to the current rate, so that a donation does not make `execute` charge a
    ///         performance fee that would hide the management fee comparison
    function _resetHighWaterMark() internal {
        vm.prank(owner);
        IForkFeeManager(s.feeManager).updateHighWaterMarkPerformanceFee();
    }

    /// @notice Common assertions of the "fuse equals deposit" suites on a vault with a plain accrual
    function _assertPlainCollection(bool sameRateAndSupply_) internal {
        Branches memory b = _runBranches(s, fuse);

        /// @dev totalAssets() is gross on F1 and F2, so the collection cannot change the assets
        assertEq(b.fuse.totalAssets, b.before.totalAssets, "totalAssets changed by the collection");
        _assertFuseEqualsDeposit(s, b, sameRateAndSupply_);
        if (sameRateAndSupply_) {
            assertLt(b.fuse.rate, b.before.rate, "collection must lower the share price");
        }
        /// @dev the vault minted fee shares: the supply grows exactly by them
        assertEq(
            b.fuse.totalSupply - b.before.totalSupply,
            b.fuse.feeAccountShares - b.before.feeAccountShares,
            "only the fee shares were minted"
        );
    }
}

/// @title RealizeManagementFeeFuseArbF1ForkTest
/// @notice IL-8870. F1 vault (Arbitrum template 0x8626...c25f, factory template between migrations 2026-08-06_001 and
///         2026-10-22_001) cloned from the live FusionFactory. USDC, 0.3% management fee, 30 days of accrual.
contract RealizeManagementFeeFuseArbF1ForkTest is RealizeManagementFeeFuseCloneForkBase {
    /// @dev Own fork block of this suite; inside the F1 window (491 679 032 .. 517 259 968)
    uint256 internal constant FORK_BLOCK = 500_000_000;

    address internal constant FACTORY = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;
    address internal constant F1_TEMPLATE = 0x862694442FE0F605750c54793E45fe31B4fc238f;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal constant ACCRUAL = 30 days;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), FORK_BLOCK);
        _cloneAndConfigure(FACTORY, F1_TEMPLATE, USDC, 1e6);

        /// @dev the first deposit starts the fee accrual (an empty vault accrues nothing)
        _deposit(DEPOSIT);
    }

    /// @dev Would fail if the legacy path minted another amount than the deposit-time realization of the F1 template,
    ///      left another clock or pending value, or did not emit ManagementFeeRealized and
    ///      RealizeManagementFeeFuseEnter. The suite fails in setUp when the template is not F1.
    function testShouldRealizeLikeDepositOnArbitrumF1() public {
        /// @dev the only warp of this suite; the other test of the contract needs no accrual
        vm.warp(vm.getBlockTimestamp() + ACCRUAL);
        _assertPlainCollection(true);
    }

    /// @dev Would fail if the vault already had the entry (a new vault answers `WrongCaller` instead).
    function testShouldHaveNoRealizeManagementFeeInternalEntryOutsideExecute() public {
        _assertEntryAbsentOutsideExecute(s.vault);
    }
}

/// @title RealizeManagementFeeFuseArbF2ForkTest
/// @notice IL-8870. F2 vault (Arbitrum template 0x730e...537f, Release 2026-10, pending management fee slot) cloned
///         from the live FusionFactory right after migration 2026-10-22_003. USDC, 0.3% management fee, 30 days.
contract RealizeManagementFeeFuseArbF2ForkTest is RealizeManagementFeeFuseCloneForkBase {
    /// @dev Own fork block of this suite; after the end of 2026-10-22_003 (517 370 367)
    uint256 internal constant FORK_BLOCK = 517_400_000;

    address internal constant FACTORY = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;
    address internal constant F2_TEMPLATE = 0x730e6160b5f451762aEb117DeBe96a36a6F537FF;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal constant ACCRUAL = 30 days;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), FORK_BLOCK);
        _cloneAndConfigure(FACTORY, F2_TEMPLATE, USDC, 1e6);
        _deposit(DEPOSIT);
    }

    /// @dev Would fail if the legacy path minted another amount than the deposit-time realization of the F2 template,
    ///      left another clock or pending value, or did not emit ManagementFeeRealized and
    ///      RealizeManagementFeeFuseEnter. The suite fails in setUp when the template is not F2.
    function testShouldRealizeLikeDepositOnArbitrumF2() public {
        /// @dev the only warp of this suite; the other test of the contract needs no accrual
        vm.warp(vm.getBlockTimestamp() + ACCRUAL);
        _assertPlainCollection(true);
    }

    /// @dev Would fail if the vault already had the entry.
    function testShouldHaveNoRealizeManagementFeeInternalEntryOutsideExecute() public {
        _assertEntryAbsentOutsideExecute(s.vault);
    }
}

/// @title RealizeManagementFeeFuseArbF2PendingForkTest
/// @notice IL-8870. F2 keeps a fee that rounded to zero shares in the pending management fee slot. Here the pending fee
///         is created by a real F2 deposit: the vault holds donated assets with almost no shares, so the fee of one
///         hour converts to zero shares and is stored. A huge deposit then makes the next fee convert to shares, and
///         the fuse must mint the pending fee together with the new accrual and clear the slot, like a deposit does.
contract RealizeManagementFeeFuseArbF2PendingForkTest is RealizeManagementFeeFuseCloneForkBase {
    /// @dev Own fork block of this suite
    uint256 internal constant FORK_BLOCK = 517_450_000;

    address internal constant FACTORY = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;
    address internal constant F2_TEMPLATE = 0x730e6160b5f451762aEb117DeBe96a36a6F537FF;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev 1000 wei of USDC: a handful of shares
    uint256 internal constant FIRST_DEPOSIT = 1_000;
    /// @dev 1 000 000 USDC without shares
    uint256 internal constant DONATION = 1_000_000e6;
    /// @dev 1 000 000 000 USDC: after it the fee of one hour is worth several shares
    uint256 internal constant BIG_DEPOSIT = 1_000_000_000e6;

    uint256 internal pendingStored;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), FORK_BLOCK);
        _cloneAndConfigure(FACTORY, F2_TEMPLATE, USDC, 1e6);
        /// @dev one deposit unit must still convert to shares at the coarse price (1 share = 1e7 asset wei)
        s.unit = 1e12;

        _deposit(FIRST_DEPOSIT);
        _donate(DONATION);
        _resetHighWaterMark();

        /// @dev first warp phase: the fee of one hour on the donated assets is zero shares
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        /// @dev this deposit realizes the fee first: zero shares, so the fee goes to the pending slot
        _deposit(BIG_DEPOSIT);
        pendingStored = uint256(vm.load(s.vault, PENDING_MANAGEMENT_FEE_SLOT));

        /// @dev second warp phase (same setUp): fee accrues on the big deposit and converts to shares
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _resetHighWaterMark();
    }

    /// @dev Would fail if the fuse dropped the pending fee (minted only the new accrual), left the slot non-zero, or
    ///      minted another amount than a deposit-time realization. The assertion on `pendingStored` proves the
    ///      scenario really carries a pending fee into the call.
    function testShouldMintPendingFeeAndClearSlotLikeDepositOnArbitrumF2() public {
        assertGt(pendingStored, 0, "scenario must store a pending fee");

        Branches memory b = _runBranches(s, fuse);

        assertEq(b.before.pending, pendingStored, "pending changed before the call");
        assertGt(
            b.unrealizedFeeBefore,
            b.before.pending,
            "unrealized fee must include the pending fee and the accrual"
        );
        assertEq(b.fuse.totalAssets, b.before.totalAssets, "totalAssets changed by the collection");
        /// @dev the rate probe resolves one share, the donated vault has a coarse price: only the shares are compared
        _assertFuseEqualsDeposit(s, b, false);
        assertEq(
            b.fuse.totalSupply - b.before.totalSupply,
            b.fuse.feeAccountShares - b.before.feeAccountShares,
            "only the fee shares were minted"
        );
    }
}

/// @title RealizeManagementFeeFuseArbF2ZeroSharesForkTest
/// @notice IL-8870. F2 vault whose accrued fee is positive in underlying but converts to zero shares (donated assets,
///         a handful of shares): the fuse must leave the state untouched (clock, pending slot, supply, fee account),
///         emit nothing and keep the fee accrued for a later realization.
contract RealizeManagementFeeFuseArbF2ZeroSharesForkTest is RealizeManagementFeeFuseCloneForkBase {
    /// @dev Own fork block of this suite
    uint256 internal constant FORK_BLOCK = 517_500_000;

    address internal constant FACTORY = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;
    address internal constant F2_TEMPLATE = 0x730e6160b5f451762aEb117DeBe96a36a6F537FF;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 internal constant FIRST_DEPOSIT = 1_000;
    uint256 internal constant DONATION = 1_000_000e6;
    /// @dev one deposit unit must still convert to shares at the coarse price (1 share = 1e7 asset wei)
    uint256 internal constant DEPOSIT_UNIT = 1e12;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), FORK_BLOCK);
        _cloneAndConfigure(FACTORY, F2_TEMPLATE, USDC, 1e6);

        _deposit(FIRST_DEPOSIT);
        _donate(DONATION);
        _resetHighWaterMark();

        /// @dev the only warp of this suite
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    /// @dev Would fail if the fuse moved the fee clock, wrote the pending slot, minted, or emitted an event while the
    ///      fee converts to zero shares. The preconditions prove the fee is positive in underlying and zero in shares,
    ///      so the early return is the branch under test and not the zero-fee branch.
    function testShouldLeaveStateUntouchedWhenFeeConvertsToZeroShares() public {
        uint256 fee = IForkLegacyVault(s.vault).getUnrealizedManagementFee();
        assertGt(fee, 0, "the fee must be positive in underlying");
        assertEq(IERC4626(s.vault).convertToShares(fee), 0, "the fee must convert to zero shares");
        assertGt(IERC20(s.vault).totalSupply(), 0, "the vault must have shares");

        Snapshot memory beforeCall = _snapshot(s);
        uint256 id = vm.snapshotState();

        vm.recordLogs();
        _execute(s, fuse, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Snapshot memory afterCall = _snapshot(s);
        assertEq(afterCall.clock, beforeCall.clock, "fee clock moved");
        assertEq(afterCall.pending, beforeCall.pending, "pending slot changed");
        assertEq(afterCall.feeAccountShares, beforeCall.feeAccountShares, "fee account shares changed");
        assertEq(afterCall.totalSupply, beforeCall.totalSupply, "supply changed");
        assertEq(afterCall.totalAssets, beforeCall.totalAssets, "assets changed");
        assertEq(afterCall.performanceFeeShares, beforeCall.performanceFeeShares, "performance fee charged");
        assertEq(IForkLegacyVault(s.vault).getUnrealizedManagementFee(), fee, "the accrued fee was lost");
        assertEq(_countLogs(logs, s.vault, ManagementFeeRealized.selector), 0, "ManagementFeeRealized emitted");
        assertEq(_countLogs(logs, s.vault, RealizeManagementFeeFuseEnter.selector), 0, "fuse event emitted");

        /// @dev DA-9: on F2 a deposit in the same state does NOT leave the state untouched. It stores the fee that
        ///      converts to zero shares in the pending slot and moves the clock, so the fuse and the deposit diverge
        ///      here. The fee stays accrued either way, which is why the divergence has no effect on the fee owed.
        vm.revertToState(id);
        s.unit = DEPOSIT_UNIT;
        _depositOneUnit(s);
        Snapshot memory afterDeposit = _snapshot(s);
        assertEq(afterDeposit.pending, fee, "deposit must store the zero-share fee as pending");
        assertGt(afterDeposit.pending, afterCall.pending, "deposit-branch: pending slot not written");
        assertEq(afterDeposit.clock, block.timestamp, "deposit-branch: clock not moved to now");
        assertGt(afterDeposit.clock, afterCall.clock, "deposit-branch: clock must differ from the fuse branch");
        assertEq(afterDeposit.feeAccountShares, beforeCall.feeAccountShares, "deposit minted fee shares");
    }
}

/// @title RealizeManagementFeeFuseArbF2LiveNoFeeForkTest
/// @notice IL-8870. A live F2 vault from the factory (created after migration 2026-10-22_003, management fee 0, target closed until the owner opens it, owner without execution delay) that
///         holds a deposit and 30 days of time: the fuse changes nothing, compared with an empty `execute`. The roles
///         come from the live owner of the vault, the way an atomist would grant them.
contract RealizeManagementFeeFuseArbF2LiveNoFeeForkTest is RealizeManagementFeeFuseCloneForkBase {
    /// @dev Own fork block of this suite; the vault was created at block 518 069 762
    uint256 internal constant FORK_BLOCK = 518_300_000;

    address internal constant F2_TEMPLATE = 0x730e6160b5f451762aEb117DeBe96a36a6F537FF;
    address internal constant LIVE_VAULT = 0x7963Ea3981a2d59BF42eB53D01108F1c374b8c44;
    address internal constant LIVE_FEE_MANAGER = 0x51e8D1B2478Ce8d3668509352C8E40ca1e27BAc4;
    address internal constant LIVE_OWNER = 0x0B50beaE6aac0425e31d5a29080F2A7Dec22754a;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev the live vault caps deposits at 1e9 asset wei per call
    uint256 internal constant DEPOSIT = 500e6;

    /// @dev The live vault is created with a closed access target: the owner grants GUARDIAN to a guardian, who opens
    ///      it (`updateTargetClosed`); then the owner grants ATOMIST
    function _grantAtomist() internal override {
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        IporFusionAccessManager(accessManager).grantRole(Roles.GUARDIAN_ROLE, guardian, 0);
        vm.prank(guardian);
        IporFusionAccessManager(accessManager).updateTargetClosed(LIVE_VAULT, false);
        super._grantAtomist();
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), FORK_BLOCK);
        owner = LIVE_OWNER;
        _configure(LIVE_VAULT, LIVE_FEE_MANAGER, IForkAuthority(LIVE_VAULT).authority(), F2_TEMPLATE, 1e6);
        assertEq(IERC4626(LIVE_VAULT).asset(), USDC, "unexpected asset");

        _deposit(DEPOSIT);

        /// @dev the only warp of this suite
        vm.warp(vm.getBlockTimestamp() + 30 days);
    }

    /// @dev Would fail if the fuse minted, moved the clock or emitted for a vault with a zero management fee. The
    ///      preconditions prove the fee is configured to 0 and the vault has shares.
    function testShouldChangeNothingOnLiveF2VaultWithoutManagementFee() public {
        (, uint16 feeInPercentage, ) = IForkLegacyVault(s.vault).getManagementFeeData();
        assertEq(feeInPercentage, 0, "the vault must have no management fee");
        assertGt(IERC20(s.vault).totalSupply(), 0, "the vault must have shares");
        assertEq(IForkLegacyVault(s.vault).getUnrealizedManagementFee(), 0, "no fee can accrue");

        Branches memory b = _runBranches(s, fuse);

        assertEq(b.fuse.feeAccountShares, b.before.feeAccountShares, "fee account shares changed");
        assertEq(b.fuse.feeAccountShares, b.emptyExecute.feeAccountShares, "fuse != empty execute: fee shares");
        assertEq(b.fuse.clock, b.emptyExecute.clock, "fuse != empty execute: clock");
        assertEq(b.fuse.pending, b.emptyExecute.pending, "fuse != empty execute: pending");
        assertEq(b.fuse.totalSupply, b.emptyExecute.totalSupply, "fuse != empty execute: supply");
        assertEq(b.fuse.totalAssets, b.emptyExecute.totalAssets, "fuse != empty execute: assets");
        assertEq(_countLogs(b.fuseLogs, s.vault, ManagementFeeRealized.selector), 0, "ManagementFeeRealized emitted");
        assertEq(_countLogs(b.fuseLogs, s.vault, RealizeManagementFeeFuseEnter.selector), 0, "fuse event emitted");
    }
}

/// @notice The vault is an AccessManaged contract
interface IForkAuthority {
    function authority() external view returns (address);
}

/// @title RealizeManagementFeeFuseInkF1ForkTest
/// @notice IL-8870. F1 vault (Ink, factory after migration 2026-09-15_001) cloned from the live FusionFactory.
///         USDT0, 0.3% management fee, 30 days of accrual.
contract RealizeManagementFeeFuseInkF1ForkTest is RealizeManagementFeeFuseCloneForkBase {
    /// @dev Own fork block of this suite; after the migration (55 933 036)
    uint256 internal constant FORK_BLOCK = 57_000_000;

    address internal constant FACTORY = 0xEC53f69Bd1D991a2F99e96DE66E81D0E42A61D8D;
    address internal constant F1_TEMPLATE = 0x02b78fB2cc2FdDeCf11d1CA785b49A5521156Fdb;
    address internal constant USDT0 = 0x0200C29006150606B650577BBE7B6248F58470c1;

    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal constant ACCRUAL = 30 days;

    function setUp() public {
        vm.createSelectFork(vm.envString("INK_PROVIDER_URL"), FORK_BLOCK);
        /// @dev The Ink price oracle middleware has no price source for any asset (checked at blocks 57M..59.4M), so
        ///      `execute` could not value the underlying. Only the oracle answer for the asset is fixed to 1 USD; the
        ///      vault, the fee logic and the factory are the on-chain ones.
        vm.mockCall(
            address(FusionFactory(FACTORY).getPriceOracleMiddleware()),
            abi.encodeWithSignature("getAssetPrice(address)", USDT0),
            abi.encode(uint256(1e18), uint256(18))
        );
        _cloneAndConfigure(FACTORY, F1_TEMPLATE, USDT0, 1e6);
        _deposit(DEPOSIT);
    }

    /// @dev Would fail if the legacy path minted another amount than the deposit-time realization of the Ink template,
    ///      left another clock or pending value, or did not emit ManagementFeeRealized and
    ///      RealizeManagementFeeFuseEnter.
    function testShouldRealizeLikeDepositOnInkF1() public {
        /// @dev the only warp of this suite; the other test of the contract needs no accrual
        vm.warp(vm.getBlockTimestamp() + ACCRUAL);
        _assertPlainCollection(true);
    }

    /// @dev Would fail if the vault already had the entry.
    function testShouldHaveNoRealizeManagementFeeInternalEntryOutsideExecute() public {
        _assertEntryAbsentOutsideExecute(s.vault);
    }
}

/// @title RealizeManagementFeeFuseHyperEvmF2ForkTest
/// @notice IL-8870. F2 vault (HyperEVM, factory template 0xcfd0...5b27 after migration 2026-10-22, block >= 49 263
///         384) cloned from the live FusionFactory. Runs only when `HYPEREVM_MAINNET_FORK_RPC` is set; without it the
///         suite is skipped in `setUp`. Native USDC (6 decimals), 0.3% management fee, 30 days of accrual.
contract RealizeManagementFeeFuseHyperEvmF2ForkTest is RealizeManagementFeeFuseCloneForkBase {
    /// @dev Own fork block of this suite; after the migration (49 263 384)
    uint256 internal constant FORK_BLOCK = 49_300_000;

    address internal constant FACTORY = 0x6bBc827F34b4e862d15215ABd4AC0E3886181665;
    address internal constant F2_TEMPLATE = 0xcFd0b2178D0Dd2DBCEfd95B8F0bdB27480B5325C;
    address internal constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;

    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal constant ACCRUAL = 30 days;

    function setUp() public {
        string memory rpc = vm.envOr("HYPEREVM_MAINNET_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        _cloneAndConfigure(FACTORY, F2_TEMPLATE, USDC, 1e6);
        _deposit(DEPOSIT);
    }

    /// @dev Would fail if the legacy path minted another amount than the deposit-time realization of the F2 template,
    ///      left another clock or pending value, or did not emit ManagementFeeRealized and
    ///      RealizeManagementFeeFuseEnter.
    function testShouldRealizeLikeDepositOnHyperEvmF2() public {
        /// @dev the only warp of this suite; the other test of the contract needs no accrual
        vm.warp(vm.getBlockTimestamp() + ACCRUAL);
        _assertPlainCollection(true);
    }

    /// @dev Would fail if the vault already had the entry.
    function testShouldHaveNoRealizeManagementFeeInternalEntryOutsideExecute() public {
        _assertEntryAbsentOutsideExecute(s.vault);
    }
}
