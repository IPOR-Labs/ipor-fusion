// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {RealizeManagementFeeFuse} from "../../../contracts/fuses/management_fee/RealizeManagementFeeFuse.sol";

/// @notice Mirror of the vault's FuseAction struct (IL-8870: the fork suites talk to on-chain bytecode of old vault
///         versions through minimal interfaces, so they do not depend on the code under change)
struct ForkFuseAction {
    address fuse;
    bytes data;
}

/// @notice Minimal view of the vault entry points that exist on every deployed PlasmaVault family (F0, F1, F2)
interface IForkLegacyVault {
    function execute(ForkFuseAction[] calldata calls_) external;

    function addFuses(address[] calldata fuses_) external;

    function getUnrealizedManagementFee() external view returns (uint256);

    function getManagementFeeData()
        external
        view
        returns (address feeAccount, uint16 feeInPercentage, uint32 lastUpdate);

    function getPerformanceFeeData() external view returns (address feeAccount, uint16 feeInPercentage);

    function deposit(uint256 assets_, address receiver_) external returns (uint256);
}

/// @notice The entry that only vaults built with IL-8870 have
interface IForkNewEntry {
    function realizeManagementFeeInternal() external returns (uint256);
}

/// @notice Minimal view of the FeeManager high water mark storage
interface IForkFeeManager {
    function updateHighWaterMarkPerformanceFee() external;

    function getPlasmaVaultHighWaterMarkPerformanceFee()
        external
        view
        returns (uint128 highWaterMark, uint32 lastUpdate, uint32 updateInterval);
}

/// @title RealizeManagementFeeFuseForkBase - shared harness of the fork tests of RealizeManagementFeeFuse on old vaults
/// @notice IL-8870. Runs the fuse against ON-CHAIN bytecode of PlasmaVault families that do not have
///         `realizeManagementFeeInternal()` (F0: February 2026 templates, F1: templates after ipor-fusion #475) and
///         compares it with the collection that a 1-unit deposit performs on the same family.
/// @dev Every concrete suite forks with its own block (suites with the same URL and block share a fork backend and
///      leak `vm.warp` in parallel runs) and has at most one `vm.warp` case.
abstract contract RealizeManagementFeeFuseForkBase is Test {
    using Address for address;

    /// @dev Slot of the pending management fee (PlasmaVaultStorageLib.PENDING_MANAGEMENT_FEE_SLOT, F2 only)
    bytes32 internal constant PENDING_MANAGEMENT_FEE_SLOT =
        0x612d50d27ffbb749a9804ec5bba7933bff2377ff69afba55e14b5cf7180bff00;

    /// @dev Shares used to read the exchange rate with a resolution finer than one asset unit
    uint256 internal constant RATE_PROBE_MULTIPLIER = 1e6;

    /// @notice Everything a suite needs to know about the vault under test
    struct Setup {
        address vault;
        address feeManager;
        /// @dev holder of ALPHA_ROLE (runs `execute`)
        address alpha;
        /// @dev holder of FUSE_MANAGER_ROLE (runs `addFuses`)
        address fuseManager;
        /// @dev account allowed to deposit (whitelist) that receives the dealt asset
        address depositor;
        /// @dev expected EIP-1167 implementation of the vault clone
        address template;
        /// @dev one asset unit, 10 ** asset decimals
        uint256 unit;
    }

    /// @notice State of the vault that the comparisons look at
    struct Snapshot {
        uint256 feeAccountShares;
        uint256 clock;
        uint256 pending;
        uint256 rate;
        uint256 performanceFeeShares;
        uint256 highWaterMark;
        uint256 totalSupply;
        uint256 totalAssets;
    }

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);
    event RealizeManagementFeeFuseEnter(address version, uint256 feeShares);

    /// @notice Asserts that `vault` is an EIP-1167 clone of `template_`
    /// @dev Bytes 10..29 of the 45-byte runtime code are the implementation address. This guards against testing a
    ///      different vault family than the one the suite is meant to cover.
    function _assertCloneTemplate(address vault_, address template_) internal view {
        bytes memory code = vault_.code;
        assertEq(code.length, 45, "vault is not an EIP-1167 clone");
        bytes memory prefix = new bytes(10);
        for (uint256 i; i < 10; ++i) {
            prefix[i] = code[i];
        }
        assertEq(prefix, hex"363d3d373d3d3d363d73", "EIP-1167 prefix");
        address implementation;
        assembly {
            implementation := shr(96, mload(add(code, add(0x20, 10))))
        }
        assertEq(implementation, template_, "unexpected vault template");
    }

    /// @notice Deploys the fuse and registers it in the vault as the FUSE_MANAGER
    function _deployAndAddFuse(Setup memory s_) internal returns (RealizeManagementFeeFuse fuse_) {
        fuse_ = new RealizeManagementFeeFuse();
        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse_);
        vm.prank(s_.fuseManager);
        IForkLegacyVault(s_.vault).addFuses(fuses);
    }

    /// @notice Reads the state compared between the branches
    function _snapshot(Setup memory s_) internal view returns (Snapshot memory snap_) {
        IForkLegacyVault vault = IForkLegacyVault(s_.vault);
        (address feeAccount, , uint32 clock) = vault.getManagementFeeData();
        (address performanceFeeAccount, ) = vault.getPerformanceFeeData();
        (uint128 highWaterMark, , ) = IForkFeeManager(s_.feeManager).getPlasmaVaultHighWaterMarkPerformanceFee();

        snap_.feeAccountShares = IERC20(s_.vault).balanceOf(feeAccount);
        snap_.clock = clock;
        snap_.pending = uint256(vm.load(s_.vault, PENDING_MANAGEMENT_FEE_SLOT));
        snap_.rate = _rate(s_.vault);
        snap_.performanceFeeShares = IERC20(s_.vault).balanceOf(performanceFeeAccount);
        snap_.highWaterMark = highWaterMark;
        snap_.totalSupply = IERC20(s_.vault).totalSupply();
        snap_.totalAssets = IERC4626(s_.vault).totalAssets();
    }

    /// @notice Assets that `RATE_PROBE_MULTIPLIER` whole shares are worth
    function _rate(address vault_) internal view returns (uint256) {
        return IERC4626(vault_).convertToAssets(10 ** IERC20Metadata(vault_).decimals() * RATE_PROBE_MULTIPLIER);
    }

    /// @notice ALPHA runs `execute` with the fuse (`withFuse_`) or with an empty action list
    function _execute(Setup memory s_, RealizeManagementFeeFuse fuse_, bool withFuse_) internal {
        ForkFuseAction[] memory actions;
        if (withFuse_) {
            actions = new ForkFuseAction[](1);
            actions[0] = ForkFuseAction({
                fuse: address(fuse_),
                data: abi.encodeCall(RealizeManagementFeeFuse.enter, ())
            });
        } else {
            actions = new ForkFuseAction[](0);
        }
        vm.prank(s_.alpha);
        IForkLegacyVault(s_.vault).execute(actions);
    }

    /// @notice An allowed account deposits one asset unit (this is the deposit-time collection of the fee)
    function _depositOneUnit(Setup memory s_) internal {
        address asset = IERC4626(s_.vault).asset();
        deal(asset, s_.depositor, s_.unit);
        vm.startPrank(s_.depositor);
        IERC20(asset).approve(s_.vault, s_.unit);
        IForkLegacyVault(s_.vault).deposit(s_.unit, s_.depositor);
        vm.stopPrank();
    }

    /// @notice Number of logs with `topic0_` emitted by `emitter_`
    function _countLogs(
        Vm.Log[] memory logs_,
        address emitter_,
        bytes32 topic0_
    ) internal pure returns (uint256 count_) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length > 0 && logs_[i].topics[0] == topic0_) {
                ++count_;
            }
        }
    }

    /// @notice Data of the only log with `topic0_` emitted by `emitter_`; fails when there is not exactly one
    function _singleLogData(
        Vm.Log[] memory logs_,
        address emitter_,
        bytes32 topic0_
    ) internal pure returns (bytes memory) {
        uint256 found = type(uint256).max;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length > 0 && logs_[i].topics[0] == topic0_) {
                require(found == type(uint256).max, "more than one log");
                found = i;
            }
        }
        require(found != type(uint256).max, "log not found");
        return logs_[found].data;
    }

    /// @notice Result of the three F1/F2 branches started from the same state
    struct Branches {
        Snapshot before;
        Snapshot fuse;
        Snapshot deposit;
        Snapshot emptyExecute;
        uint256 unrealizedFeeBefore;
        Vm.Log[] fuseLogs;
    }

    /// @notice Runs the three branches from the current state and leaves the state as it was before
    /// @dev Branch 1: `execute([fuse])`. Branch 2: 1-unit deposit. Branch 3: `execute([])`. The state is restored with
    ///      `vm.revertToState` between the branches.
    function _runBranches(Setup memory s_, RealizeManagementFeeFuse fuse_) internal returns (Branches memory b_) {
        b_.before = _snapshot(s_);
        b_.unrealizedFeeBefore = IForkLegacyVault(s_.vault).getUnrealizedManagementFee();

        uint256 id = vm.snapshotState();

        vm.recordLogs();
        _execute(s_, fuse_, true);
        b_.fuseLogs = vm.getRecordedLogs();
        b_.fuse = _snapshot(s_);
        vm.revertToState(id);
        id = vm.snapshotState();

        _depositOneUnit(s_);
        b_.deposit = _snapshot(s_);
        vm.revertToState(id);
        id = vm.snapshotState();

        _execute(s_, fuse_, false);
        b_.emptyExecute = _snapshot(s_);
        vm.revertToState(id);
    }

    /// @notice Asserts the equalities that hold on every family between `execute([fuse])` and a deposit
    /// @dev Fails when the fuse mints a different amount than the deposit-time realization, leaves a different clock or
    ///      pending slot, or does not emit the two events with the minted shares. `sameRateAndSupply_` also compares the
    ///      rate and the minted supply; it is false when a performance fee is charged (it differs between the branches).
    function _assertFuseEqualsDeposit(Setup memory s_, Branches memory b_, bool sameRateAndSupply_) internal {
        assertGt(b_.unrealizedFeeBefore, 0, "no accrued fee to collect");
        assertGt(b_.fuse.feeAccountShares, b_.before.feeAccountShares, "fuse minted no fee shares");
        assertEq(b_.fuse.feeAccountShares, b_.deposit.feeAccountShares, "fee shares: fuse != deposit");
        assertEq(b_.fuse.clock, b_.deposit.clock, "fee clock: fuse != deposit");
        assertEq(b_.fuse.clock, block.timestamp, "fee clock not moved to now");
        assertGt(b_.fuse.clock, b_.before.clock, "fee clock did not advance");
        assertEq(b_.fuse.pending, b_.deposit.pending, "pending fee: fuse != deposit");
        assertEq(b_.fuse.pending, 0, "pending fee left behind");
        if (sameRateAndSupply_) {
            /// @dev the deposit adds one unit at the post-collection rate, so the rates agree up to rounding
            assertApproxEqAbs(b_.fuse.rate, b_.deposit.rate, 2, "rate: fuse != deposit");
            assertEq(
                b_.fuse.totalSupply - b_.before.totalSupply,
                b_.fuse.feeAccountShares - b_.before.feeAccountShares,
                "only the fee shares were minted"
            );
        }
        _assertFuseEvents(s_, b_);
    }

    /// @dev vault event ManagementFeeRealized(fee, shares) once, and the fuse event; both emitted in the vault context
    function _assertFuseEvents(Setup memory s_, Branches memory b_) private view {
        uint256 minted = b_.fuse.feeAccountShares - b_.before.feeAccountShares;

        assertEq(_countLogs(b_.fuseLogs, s_.vault, ManagementFeeRealized.selector), 1, "ManagementFeeRealized count");
        (uint256 feeInEvent, uint256 sharesInEvent) = abi.decode(
            _singleLogData(b_.fuseLogs, s_.vault, ManagementFeeRealized.selector),
            (uint256, uint256)
        );
        assertEq(feeInEvent, b_.unrealizedFeeBefore, "ManagementFeeRealized fee");
        assertEq(sharesInEvent, minted, "ManagementFeeRealized shares");

        assertEq(
            _countLogs(b_.fuseLogs, s_.vault, RealizeManagementFeeFuseEnter.selector),
            1,
            "RealizeManagementFeeFuseEnter count"
        );
        (address version, uint256 sharesInFuseEvent) = abi.decode(
            _singleLogData(b_.fuseLogs, s_.vault, RealizeManagementFeeFuseEnter.selector),
            (address, uint256)
        );
        assertEq(sharesInFuseEvent, minted, "RealizeManagementFeeFuseEnter shares");
        assertTrue(version != address(0), "RealizeManagementFeeFuseEnter version");
    }

    /// @notice Outside `execute` an old vault has no `realizeManagementFeeInternal()` entry
    /// @dev The fallback of old vaults delegates the unknown selector to PlasmaVaultBase, which fails with
    ///      `FailedInnerCall()`; the new entry would answer `WrongCaller` instead.
    function _assertEntryAbsentOutsideExecute(address vault_) internal {
        vm.expectRevert(abi.encodeWithSelector(Address.FailedInnerCall.selector));
        IForkNewEntry(vault_).realizeManagementFeeInternal();
    }
}
