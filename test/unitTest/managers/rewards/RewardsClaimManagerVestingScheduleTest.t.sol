// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IporFusionAccessManager} from "../../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {RewardsClaimManagersStorageLib} from "../../../../contracts/managers/rewards/RewardsClaimManagersStorageLib.sol";
import {VestingData} from "../../../../contracts/interfaces/IRewardsClaimManager.sol";
import {Roles} from "../../../../contracts/libraries/Roles.sol";

import {MockPlasmaVault} from "../../../managers/MockPlasmaVault.sol";
import {MockToken} from "../../../managers/MockToken.sol";

/// @title RewardsClaimManagerVestingScheduleTest
/// @notice Unit tests for the IL-7485 vesting schedule fix: saturating balanceOf(), unsafe-input
/// rejection in setupVestingTime, the new rescheduleVesting primitive, and the vestedAt helper.
contract RewardsClaimManagerVestingScheduleTest is Test {
    uint64 private constant _REWARD_MANAGER_ROLE = 1001;

    /// @dev VestingData storage slot — same constant as RewardsClaimManagersStorageLib.
    /// Used by helpers to materialise contrived storage states (incident replay).
    bytes32 private constant _VESTING_DATA_SLOT = 0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc00;

    address private _atomist;
    address private _operator;
    address private _outsider;
    MockToken private _underlying;
    MockPlasmaVault private _plasmaVault;
    IporFusionAccessManager private _accessManager;
    RewardsClaimManager private _rcm;

    function setUp() public {
        _atomist = address(0x1111);
        _operator = address(0x2222);
        _outsider = address(0x3333);

        _underlying = new MockToken("Underlying Token", "UT");
        _plasmaVault = new MockPlasmaVault(address(_underlying));
        _accessManager = new IporFusionAccessManager(_atomist, 0);
        _rcm = new RewardsClaimManager(address(_accessManager), address(_plasmaVault));

        vm.prank(_atomist);
        _accessManager.grantRole(_REWARD_MANAGER_ROLE, _operator, 0);

        bytes4[] memory sig = new bytes4[](8);
        sig[0] = RewardsClaimManager.transfer.selector;
        sig[1] = RewardsClaimManager.addRewardFuses.selector;
        sig[2] = RewardsClaimManager.removeRewardFuses.selector;
        sig[3] = RewardsClaimManager.claimRewards.selector;
        sig[4] = RewardsClaimManager.setupVestingTime.selector;
        sig[5] = RewardsClaimManager.transferVestedTokensToVault.selector;
        sig[6] = RewardsClaimManager.updateBalance.selector;
        sig[7] = RewardsClaimManager.rescheduleVesting.selector;

        vm.prank(_atomist);
        _accessManager.setTargetFunctionRole(address(_rcm), sig, _REWARD_MANAGER_ROLE);
    }

    /// @dev Force the VestingData slot to a contrived value (e.g. to replay the mainnet incident).
    /// This bypasses RewardsClaimManager's own writers — required for tests that need to observe
    /// behaviour of balanceOf() in a state the writers would now refuse to create.
    /// @dev VestingData layout is 32+32+128+128 = 320 bits, so it occupies TWO storage slots:
    /// slot 0: vestingTime (LSB) | updateBalanceTimestamp | transferredTokens (MSB) — 192 bits;
    /// slot 1: lastUpdateBalance — 128 bits.
    function _writeVestingData(
        uint32 vestingTime,
        uint32 updateBalanceTimestamp,
        uint128 transferredTokens,
        uint128 lastUpdateBalance
    ) internal {
        uint256 slot0;
        slot0 |= uint256(vestingTime);
        slot0 |= uint256(updateBalanceTimestamp) << 32;
        slot0 |= uint256(transferredTokens) << 64;
        vm.store(address(_rcm), _VESTING_DATA_SLOT, bytes32(slot0));
        vm.store(address(_rcm), bytes32(uint256(_VESTING_DATA_SLOT) + 1), bytes32(uint256(lastUpdateBalance)));
    }

    /// @dev Read packed VestingData straight off the slot for assertions.
    function _readVestingData() internal view returns (VestingData memory data) {
        data = _rcm.getVestingData();
    }

    // -----------------------------------------------------------------------------------
    // balanceOf() saturation
    // -----------------------------------------------------------------------------------

    /// @notice Replays the mainnet incident storage tuple and asserts balanceOf() returns 0
    /// instead of reverting on the underflow.
    function testBalanceOf_returnsZero_whenVestedBelowTransferred_replayIncident() public {
        // Block 25178505 state from feature-IL-7102/temp/rewards-manager-revert-analysis.md.
        vm.warp(1_779_786_611);
        _writeVestingData({
            vestingTime: 1_814_400,
            updateBalanceTimestamp: 1_779_785_915,
            transferredTokens: 2_200_009_874_193_100,
            lastUpdateBalance: 2_016_009_048_351_496_489
        });

        // With the old contract this call would revert with panic 0x11 (arithmetic underflow).
        uint256 balance = _rcm.balanceOf();

        assertEq(balance, 0, "balanceOf must clamp to zero during the underflow window");
    }

    /// @notice Once enough wall-clock time passes, the vested portion catches up and balanceOf
    /// resumes returning the linearly-increasing claimable amount.
    function testBalanceOf_recoversNaturally_afterClampWindow() public {
        vm.warp(1_779_786_611);
        _writeVestingData({
            vestingTime: 1_814_400,
            updateBalanceTimestamp: 1_779_785_915,
            transferredTokens: 2_200_009_874_193_100,
            lastUpdateBalance: 2_016_009_048_351_496_489
        });

        // From the analysis: elapsed_needed = 1980 s ⇒ timestamp_safe = 1_779_787_895.
        vm.warp(1_779_787_895);
        uint256 balanceAtBoundary = _rcm.balanceOf();
        assertEq(balanceAtBoundary, 0, "boundary block: vested == transferred, clamp returns 0");

        vm.warp(1_779_787_896);
        uint256 balanceAfterBoundary = _rcm.balanceOf();
        assertGt(balanceAfterBoundary, 0, "one block past boundary: positive monotone amount");
    }

    /// @notice When the vesting curve has fully matured, balanceOf returns the standard
    /// `lastUpdateBalance - transferredTokens` quantity (regression for the saturating branch).
    function testBalanceOf_returnsLastMinusTransferred_whenFullyMatured() public {
        vm.warp(1_000_000);
        _writeVestingData({
            vestingTime: 1 days,
            updateBalanceTimestamp: 100,
            transferredTokens: 400e18,
            lastUpdateBalance: 1_000e18
        });

        uint256 balance = _rcm.balanceOf();

        assertEq(balance, 600e18, "fully-matured curve returns last - transferred");
    }

    /// @notice Fuzz: balanceOf must never revert on any storage tuple.
    function testFuzz_balanceOf_neverReverts(
        uint128 lastUpdateBalance,
        uint128 transferredTokens,
        uint32 vestingTime,
        uint32 updateBalanceTimestamp,
        uint64 nowTs
    ) public {
        vm.warp(uint256(nowTs));
        _writeVestingData(vestingTime, updateBalanceTimestamp, transferredTokens, lastUpdateBalance);

        uint256 balance = _rcm.balanceOf();

        assertLe(balance, uint256(lastUpdateBalance), "clamp can only undercount, never overcount");
    }

    // -----------------------------------------------------------------------------------
    // setupVestingTime validation
    // -----------------------------------------------------------------------------------

    /// @notice The exact mainnet incident call (setupVestingTime(21 days) into a 7-day
    /// mid-flight state) now reverts with UnsafeVestingTime(requested, maxSafe).
    function testSetupVestingTime_revertsWithUnsafeVestingTime_replayIncident() public {
        vm.warp(1_779_786_611);
        _writeVestingData({
            vestingTime: 604_800,
            updateBalanceTimestamp: 1_779_785_915,
            transferredTokens: 2_200_009_874_193_100,
            lastUpdateBalance: 2_016_009_048_351_496_489
        });

        // elapsed = 696, maxSafe = 696 * 2_016_009_048_351_496_489 / 2_200_009_874_193_100 = 637.
        uint256 expectedMaxSafe = (uint256(696) * uint256(2_016_009_048_351_496_489)) / uint256(2_200_009_874_193_100);

        vm.prank(_operator);
        vm.expectRevert(
            abi.encodeWithSelector(RewardsClaimManager.UnsafeVestingTime.selector, uint256(1_814_400), expectedMaxSafe)
        );
        _rcm.setupVestingTime(1_814_400);
    }

    /// @notice Shortening vestingTime mid-flight is always safe (smaller vt ⇒ larger vested).
    function testSetupVestingTime_succeedsWhenShorteningMidFlight() public {
        vm.warp(1_000_000);
        _writeVestingData({
            vestingTime: 21 days,
            updateBalanceTimestamp: uint32(1_000_000 - 1 days),
            transferredTokens: 1e18,
            lastUpdateBalance: 100e18
        });

        vm.prank(_operator);
        _rcm.setupVestingTime(7 days);

        VestingData memory data = _readVestingData();
        assertEq(uint256(data.vestingTime), 7 days, "shorter vt persisted");
    }

    /// @notice After updateBalance() drains the manager, any new vestingTime passes.
    function testSetupVestingTime_succeedsAfterUpdateBalance() public {
        vm.warp(1_000_000);
        vm.prank(_operator);
        _rcm.setupVestingTime(1 days);

        // Seed the manager with rewards and let them fully vest, then transfer to the vault.
        deal(address(_underlying), address(_rcm), 1_000e18);
        vm.prank(_operator);
        _rcm.updateBalance();
        vm.warp(1_000_000 + 2 days);
        vm.prank(_operator);
        _rcm.transferVestedTokensToVault();

        // Drain & reset: transferredTokens back to 0, lastUpdateBalance reflects new state.
        vm.prank(_operator);
        _rcm.updateBalance();

        // Now any new value is safe.
        vm.prank(_operator);
        _rcm.setupVestingTime(21 days);

        assertEq(uint256(_readVestingData().vestingTime), 21 days, "post-reset vt persisted");
    }

    /// @notice First-time setup (transferredTokens == 0 because no vest has run yet) accepts
    /// any value, including a very long one.
    function testSetupVestingTime_succeedsForFirstTimeSetup() public {
        vm.warp(1_000_000);

        vm.prank(_operator);
        _rcm.setupVestingTime(365 days);

        assertEq(uint256(_readVestingData().vestingTime), 365 days, "first-time vt persisted");
    }

    /// @notice Boundary: maxSafe passes, maxSafe + 1 reverts.
    function testSetupVestingTime_succeedsAtBoundary_revertsOneAbove() public {
        // Construct a mid-flight state with a tidy maxSafe.
        // last = 1000, transferred = 100, elapsed = 100 ⇒ maxSafe = 100 * 1000 / 100 = 1000.
        vm.warp(1_000_000);
        _writeVestingData({
            vestingTime: 500,
            updateBalanceTimestamp: uint32(1_000_000 - 100),
            transferredTokens: 100,
            lastUpdateBalance: 1_000
        });

        vm.prank(_operator);
        _rcm.setupVestingTime(1_000);
        assertEq(uint256(_readVestingData().vestingTime), 1_000, "boundary value passes");

        // Re-seed: setupVestingTime succeeded, so vestingTime is now 1000 but other fields
        // unchanged; the maxSafe formula is independent of stored vestingTime, so maxSafe
        // is still 1000 — passing 1001 must revert.
        vm.prank(_operator);
        vm.expectRevert(
            abi.encodeWithSelector(RewardsClaimManager.UnsafeVestingTime.selector, uint256(1_001), uint256(1_000))
        );
        _rcm.setupVestingTime(1_001);
    }

    /// @notice Non-atomist (no role) cannot call setupVestingTime.
    function testSetupVestingTime_revertsForNonAtomist() public {
        vm.prank(_outsider);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", _outsider));
        _rcm.setupVestingTime(1 days);
    }

    /// @notice IL-8363: when transferredTokens > lastUpdateBalance no duration can make vestedAt()
    /// cover transferredTokens (vestedAt caps at lastUpdateBalance). The closed-form bound
    /// elapsed * last / transferred = 10 days * 1000 / 6000 ≈ 1.67 days used to admit 1 day.
    function testSetupVestingTime_revertsWhenTransferredExceedsLastUpdateBalance() public {
        vm.warp(1_000_000);
        _writeVestingData({
            vestingTime: 7 days,
            updateBalanceTimestamp: uint32(1_000_000 - 10 days),
            transferredTokens: 6_000e18,
            lastUpdateBalance: 1_000e18
        });

        vm.prank(_operator);
        vm.expectRevert(abi.encodeWithSelector(RewardsClaimManager.UnsafeVestingTime.selector, 1 days, 0));
        _rcm.setupVestingTime(1 days);

        vm.prank(_operator);
        vm.expectRevert(abi.encodeWithSelector(RewardsClaimManager.UnsafeVestingTime.selector, 1, 0));
        _rcm.setupVestingTime(1);
    }

    /// @notice IL-8352: while vestingTime == 0 the public transferVestedTokensToVault pushes
    /// transferredTokens above the stale lastUpdateBalance. Re-enabling vesting must re-anchor the
    /// schedule and move the live balance to the vault instead of dropping it out of totalAssets().
    function testSetupVestingTime_reanchorsWhenReEnablingVestingAfterLiveMode() public {
        vm.warp(1_000_000);
        vm.prank(_operator);
        _rcm.setupVestingTime(1 days);
        deal(address(_underlying), address(_rcm), 1_000e18);
        vm.prank(_operator);
        _rcm.updateBalance();

        vm.warp(1_000_000 + 2 days);
        vm.prank(_operator);
        _rcm.setupVestingTime(0);

        // live mode: every transfer (PUBLIC_ROLE in production) adds to transferredTokens, lastUpdateBalance stays 1000
        vm.prank(_operator);
        _rcm.transferVestedTokensToVault();
        deal(address(_underlying), address(_rcm), 500e18);
        vm.prank(_operator);
        _rcm.transferVestedTokensToVault();
        assertEq(uint256(_readVestingData().transferredTokens), 1_500e18, "transferred above last");
        assertEq(uint256(_readVestingData().lastUpdateBalance), 1_000e18, "stale last");

        deal(address(_underlying), address(_rcm), 2_000e18);
        uint256 navBefore = _underlying.balanceOf(address(_plasmaVault)) + _rcm.balanceOf();
        assertEq(_rcm.balanceOf(), 2_000e18, "live balance counted while vestingTime == 0");

        vm.prank(_operator);
        _rcm.setupVestingTime(1 days);

        VestingData memory data = _readVestingData();
        assertEq(uint256(data.vestingTime), 1 days, "vesting re-enabled");
        assertEq(uint256(data.transferredTokens), 0, "transferredTokens reset");
        assertEq(uint256(data.lastUpdateBalance), 0, "anchored on the drained balance");
        assertEq(uint256(data.updateBalanceTimestamp), block.timestamp, "anchored now");
        assertEq(_underlying.balanceOf(address(_rcm)), 0, "live balance moved to the vault");
        assertEq(
            _underlying.balanceOf(address(_plasmaVault)) + _rcm.balanceOf(),
            navBefore,
            "rewards stay in totalAssets"
        );

        // new rewards vest normally on the re-anchored schedule
        deal(address(_underlying), address(_rcm), 300e18);
        vm.prank(_operator);
        _rcm.updateBalance();
        vm.warp(block.timestamp + 1 days);
        assertEq(_rcm.balanceOf(), 300e18, "new rewards fully vested");
    }

    /// @notice IL-8352: same stranding when the schedule was never anchored (lastUpdateBalance == 0
    /// skipped the old guard entirely).
    function testSetupVestingTime_reanchorsWhenReEnablingVestingNeverAnchored() public {
        vm.warp(1_000_000);
        deal(address(_underlying), address(_rcm), 1_000e18);
        vm.prank(_operator);
        _rcm.transferVestedTokensToVault();
        deal(address(_underlying), address(_rcm), 300e18);
        assertEq(uint256(_readVestingData().transferredTokens), 1_000e18, "transferred without anchor");

        vm.prank(_operator);
        _rcm.setupVestingTime(7 days);

        VestingData memory data = _readVestingData();
        assertEq(uint256(data.transferredTokens), 0, "transferredTokens reset");
        assertEq(uint256(data.lastUpdateBalance), 0, "anchored on the drained balance");
        assertEq(_underlying.balanceOf(address(_plasmaVault)), 1_300e18, "all rewards reached the vault");
        assertEq(_underlying.balanceOf(address(_rcm)), 0, "nothing stranded in the manager");
    }

    /// @notice Disabling vesting mid-flight is always accepted: balanceOf() switches to the live balance.
    function testSetupVestingTime_acceptsZeroMidFlight() public {
        vm.warp(1_000_000);
        _writeVestingData({
            vestingTime: 7 days,
            updateBalanceTimestamp: uint32(1_000_000 - 1 days),
            transferredTokens: 100e18,
            lastUpdateBalance: 1_000e18
        });
        deal(address(_underlying), address(_rcm), 900e18);

        vm.prank(_operator);
        _rcm.setupVestingTime(0);

        assertEq(uint256(_readVestingData().vestingTime), 0, "vesting disabled");
        assertEq(uint256(_readVestingData().transferredTokens), 100e18, "no re-anchor when disabling");
        assertEq(_rcm.balanceOf(), 900e18, "live balance");
    }

    // -----------------------------------------------------------------------------------
    // rescheduleVesting
    // -----------------------------------------------------------------------------------

    /// @notice Path B from the runbook: replay the incident with rescheduleVesting instead.
    /// The vested-but-not-transferred amount P is pushed to the vault first, so totalAssets() stays
    /// continuous; the anchor therefore has to cover transferredTokens' = transferredTokens + P.
    function testRescheduleVesting_pathB_replaysIncident() public {
        vm.warp(1_779_786_611);
        _writeVestingData({
            vestingTime: 604_800,
            updateBalanceTimestamp: 1_779_785_915,
            transferredTokens: 2_200_009_874_193_100,
            lastUpdateBalance: 2_016_009_048_351_496_489
        });
        deal(address(_underlying), address(_rcm), 2_016_009_048_351_496_489 - 2_200_009_874_193_100);

        uint256 pending = _rcm.balanceOf();
        assertGt(pending, 0, "vested-but-not-transferred amount exists before the reschedule");
        uint256 navBefore = _nav();
        uint256 vaultBalanceBefore = _underlying.balanceOf(address(_plasmaVault));
        uint256 newTransferred = 2_200_009_874_193_100 + pending;
        assertEq(newTransferred, 2_320_010_412_785_450, "transferredTokens after the push");

        // The old anchor (now - 1980) only covers the OLD transferredTokens, the push raised it.
        uint256 vestedAtOldAnchor = RewardsClaimManagersStorageLib.vestedAt(
            2_016_009_048_351_496_489,
            1_814_400,
            1_779_784_631,
            block.timestamp
        );
        vm.prank(_operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardsClaimManager.UnsafeReschedule.selector,
                uint256(1_814_400),
                uint256(1_779_784_631),
                vestedAtOldAnchor,
                newTransferred
            )
        );
        _rcm.rescheduleVesting(1_814_400, 1_779_784_631);

        // t0' = block.timestamp - ceil(newTransferred * vt' / L) = now - 2088.
        vm.prank(_operator);
        _rcm.rescheduleVesting(1_814_400, 1_779_784_523);

        VestingData memory data = _readVestingData();
        assertEq(uint256(data.vestingTime), 1_814_400, "new vt persisted");
        assertEq(uint256(data.updateBalanceTimestamp), 1_779_784_523, "anchor shifted into the past");
        assertEq(uint256(data.transferredTokens), newTransferred, "transferredTokens includes the push");
        assertEq(uint256(data.lastUpdateBalance), 2_016_009_048_351_496_489, "lastUpdateBalance unchanged");

        assertEq(
            _underlying.balanceOf(address(_plasmaVault)),
            vaultBalanceBefore + pending,
            "vested amount pushed to the vault"
        );
        assertEq(_nav(), navBefore, "totalAssets continuous");

        // At the current block balanceOf is 0 (boundary), one block later it must be positive.
        assertEq(_rcm.balanceOf(), 0, "boundary block: vested == transferred");
        vm.warp(1_779_786_612);
        assertGt(_rcm.balanceOf(), 0, "one block past boundary: positive amount");
    }

    /// @notice Reschedule with newUpdateBalanceTimestamp == now is only safe once the manager
    /// has been drained — equivalent to a clean restart of the curve from the current block.
    function testRescheduleVesting_revertsWhenRebasingFromNowWithTransferredOutstanding() public {
        vm.warp(1_000_000);
        _writeVestingData({
            vestingTime: 1 days,
            updateBalanceTimestamp: uint32(1_000_000 - 12 hours),
            transferredTokens: 100,
            lastUpdateBalance: 1_000
        });
        // vested now = 500, so 400 is pushed to the vault first and transferredTokens becomes 500.
        deal(address(_underlying), address(_rcm), 900);

        // elapsed = 0 ⇒ vestedAfter = 0 < 500 ⇒ revert.
        vm.prank(_operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardsClaimManager.UnsafeReschedule.selector,
                uint256(1 days),
                uint256(1_000_000),
                uint256(0),
                uint256(500)
            )
        );
        _rcm.rescheduleVesting(1 days, uint32(1_000_000));
    }

    /// @notice Reschedule with newVestingTime == 0 reverts with InvalidVestingTime.
    function testRescheduleVesting_revertsOnZeroVestingTime() public {
        vm.prank(_operator);
        vm.expectRevert(RewardsClaimManager.InvalidVestingTime.selector);
        _rcm.rescheduleVesting(0, uint32(block.timestamp));
    }

    /// @notice Reschedule with a future timestamp reverts with InvalidTimestamp.
    function testRescheduleVesting_revertsOnFutureTimestamp() public {
        vm.warp(1_000_000);
        vm.prank(_operator);
        vm.expectRevert(RewardsClaimManager.InvalidTimestamp.selector);
        _rcm.rescheduleVesting(1 days, uint32(1_000_001));
    }

    /// @notice Reschedule with newUpdateBalanceTimestamp == 0 reverts with InvalidTimestamp.
    /// @dev Zero is reserved as the "uninitialized" sentinel for balanceOf(): without this guard
    /// the call would persist anchor=0 (the UnsafeReschedule invariant guard passes because
    /// vestedAt with elapsed >> vestingTime returns the full lastUpdateBalance), and balanceOf()
    /// would then silently collapse to 0 via the `updateBalanceTimestamp == 0` short-circuit —
    /// a direct totalAssets() / share-price drop for PlasmaVault until updateBalance() resets it.
    function testRescheduleVesting_revertsOnZeroTimestamp() public {
        vm.warp(1_000_000);
        _writeVestingData({
            vestingTime: 1 days,
            updateBalanceTimestamp: uint32(1_000_000 - 12 hours),
            transferredTokens: 100,
            lastUpdateBalance: 1_000
        });

        vm.prank(_operator);
        vm.expectRevert(RewardsClaimManager.InvalidTimestamp.selector);
        _rcm.rescheduleVesting(1 days, 0);
    }

    /// @notice PoC documenting the bug class the anchor=0 guard prevents.
    /// We materialise the post-attack storage tuple directly via vm.store (bypassing the writer
    /// that now refuses to produce it) and observe balanceOf() collapse to 0 — even though the
    /// linear curve at this block would put the contract well above transferredTokens. This is
    /// the silent share-price drop that the new guard closes off.
    function testRescheduleVesting_poc_anchorZeroSilentlyZerosBalanceOf() public {
        vm.warp(1_000_000);

        // What the attacker/typo would have persisted: anchor=0, schedule otherwise sane.
        // lastUpdateBalance = 1000, transferredTokens = 100. Linear curve from t=0 with vt=1 day
        // is fully matured at block 1_000_000, so vestedAt = 1000 >> 100 transferredTokens —
        // i.e. the UnsafeReschedule invariant is "satisfied" yet balanceOf() returns 0.
        _writeVestingData({
            vestingTime: 1 days,
            updateBalanceTimestamp: 0,
            transferredTokens: 100,
            lastUpdateBalance: 1_000
        });

        // Sanity check: the linear curve (ignoring the sentinel) WOULD put us at full maturation.
        uint256 vestedOnCurve = RewardsClaimManagersStorageLib.vestedAt(1_000, 1 days, 0, block.timestamp);
        assertEq(vestedOnCurve, 1_000, "linear curve is fully matured at block.timestamp");
        // ...so claimable per the curve should be 1000 - 100 = 900.

        // But balanceOf() hits the `updateBalanceTimestamp == 0` sentinel and returns 0.
        assertEq(_rcm.balanceOf(), 0, "PoC: sentinel collapses balanceOf despite a fully matured curve");

        // Equivalently: a fresh rescheduleVesting(_, 0) call is now refused at the guard,
        // so this storage shape is unreachable through the public API.
        vm.prank(_operator);
        vm.expectRevert(RewardsClaimManager.InvalidTimestamp.selector);
        _rcm.rescheduleVesting(1 days, 0);
    }

    /// @notice Non-atomist cannot call rescheduleVesting.
    function testRescheduleVesting_revertsForNonAtomist() public {
        vm.prank(_outsider);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", _outsider));
        _rcm.rescheduleVesting(1 days, uint32(block.timestamp));
    }

    /// @notice Fully vested but not yet transferred (transferredTokens == 0, P == L): the reschedule pushes P to
    /// the vault first, so restarting the curve from block.timestamp is refused while an anchor that keeps
    /// the pushed amount vested is accepted with continuous totalAssets().
    function testRescheduleVesting_fullyVestedPendingAmount_requiresAnchorCoveringPush() public {
        vm.warp(1_000_000);
        // Drained state: transferredTokens == 0, lastUpdateBalance arbitrary.
        _writeVestingData({
            vestingTime: 1 days,
            updateBalanceTimestamp: uint32(1_000_000 - 1 days),
            transferredTokens: 0,
            lastUpdateBalance: 500
        });
        // fully vested (500) but not yet transferred: the reschedule pushes it to the vault first.
        deal(address(_underlying), address(_rcm), 500);
        uint256 navBefore = _nav();

        // Restarting the curve from now would drop the pushed 500 out of totalAssets(): refused.
        vm.prank(_operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardsClaimManager.UnsafeReschedule.selector,
                uint256(7 days),
                uint256(1_000_000),
                uint256(0),
                uint256(500)
            )
        );
        _rcm.rescheduleVesting(7 days, uint32(1_000_000));

        // An anchor that keeps the pushed amount vested is accepted and totalAssets() is unchanged.
        vm.prank(_operator);
        _rcm.rescheduleVesting(7 days, uint32(1_000_000 - 7 days));

        VestingData memory data = _readVestingData();
        assertEq(uint256(data.vestingTime), 7 days);
        assertEq(uint256(data.updateBalanceTimestamp), 1_000_000 - 7 days);
        assertEq(uint256(data.transferredTokens), 500);
        assertEq(_nav(), navBefore, "totalAssets continuous");
    }

    /// @notice Truly drained manager (transferredTokens == 0, nothing vested-but-not-transferred):
    /// there is nothing to push, so any anchor in the past, including block.timestamp, is accepted.
    function testRescheduleVesting_succeedsWhenTrulyDrained() public {
        vm.warp(1_000_000);
        _writeVestingData({
            vestingTime: 1 days,
            updateBalanceTimestamp: uint32(1_000_000),
            transferredTokens: 0,
            lastUpdateBalance: 500
        });
        assertEq(_rcm.balanceOf(), 0, "nothing pending");
        uint256 navBefore = _nav();

        vm.prank(_operator);
        _rcm.rescheduleVesting(7 days, uint32(1_000_000));

        VestingData memory data = _readVestingData();
        assertEq(uint256(data.vestingTime), 7 days);
        assertEq(uint256(data.updateBalanceTimestamp), 1_000_000);
        assertEq(_nav(), navBefore, "totalAssets continuous");
    }

    // -----------------------------------------------------------------------------------
    // rescheduleVesting settles the vested amount before writing the new schedule (IL-8793, IL-8750)
    // -----------------------------------------------------------------------------------

    function _nav() internal view returns (uint256) {
        return _underlying.balanceOf(address(_plasmaVault)) + _rcm.balanceOf();
    }

    /// @dev Real flow: vt = 10 d, L = 1000e18, 3 d vested and transferred (T = 300e18), 2 d later
    /// P = 200e18 is vested but not transferred.
    function _setupPendingVested() internal {
        vm.warp(100_000_000);
        vm.prank(_operator);
        _rcm.setupVestingTime(10 days);
        deal(address(_underlying), address(_rcm), 1_000e18);
        vm.prank(_operator);
        _rcm.updateBalance();

        vm.warp(block.timestamp + 3 days);
        vm.prank(_operator);
        _rcm.transferVestedTokensToVault();
        vm.warp(block.timestamp + 2 days);

        assertEq(uint256(_readVestingData().transferredTokens), 300e18, "T");
        assertEq(_rcm.balanceOf(), 200e18, "P");
    }

    /// @notice IL-8750: re-enabling vesting through rescheduleVesting from live mode (vestingTime == 0,
    /// never anchored) must re-anchor like setupVestingTime instead of zeroing the live balance.
    function testRescheduleVesting_reanchorsWhenReEnablingFromLiveMode() public {
        vm.warp(1_000_000);
        deal(address(_underlying), address(_rcm), 300e18);
        assertEq(_rcm.balanceOf(), 300e18, "live balance counted while vestingTime == 0");
        uint256 navBefore = _nav();

        vm.prank(_operator);
        _rcm.rescheduleVesting(7 days, uint32(block.timestamp));

        assertEq(_nav(), navBefore, "totalAssets continuous");
        assertEq(_underlying.balanceOf(address(_rcm)), 0, "manager emptied");
        assertEq(_underlying.balanceOf(address(_plasmaVault)), 300e18, "live balance moved to the vault");
        VestingData memory data = _readVestingData();
        assertEq(uint256(data.transferredTokens), 0, "T reset");
        assertEq(uint256(data.lastUpdateBalance), 0, "L re-anchored");
        assertEq(uint256(data.vestingTime), 7 days);

        vm.warp(block.timestamp + 30 days);
        assertEq(_nav(), navBefore, "still continuous after the schedule matured");
    }

    /// @notice IL-8750 with the IL-8352 state (transferredTokens above a stale lastUpdateBalance):
    /// the call used to revert with UnsafeReschedule, now the re-anchor makes it succeed.
    function testRescheduleVesting_reanchorsFromLiveModeWithStaleTransferred() public {
        vm.warp(1_000_000);
        vm.prank(_operator);
        _rcm.setupVestingTime(1 days);
        deal(address(_underlying), address(_rcm), 1_000e18);
        vm.prank(_operator);
        _rcm.updateBalance();

        vm.warp(1_000_000 + 2 days);
        vm.prank(_operator);
        _rcm.setupVestingTime(0);

        vm.prank(_operator);
        _rcm.transferVestedTokensToVault();
        deal(address(_underlying), address(_rcm), 500e18);
        vm.prank(_operator);
        _rcm.transferVestedTokensToVault();
        assertEq(uint256(_readVestingData().transferredTokens), 1_500e18, "transferred above last");
        assertEq(uint256(_readVestingData().lastUpdateBalance), 1_000e18, "stale last");

        deal(address(_underlying), address(_rcm), 2_000e18);
        uint256 navBefore = _nav();

        vm.prank(_operator);
        _rcm.rescheduleVesting(7 days, uint32(block.timestamp));

        assertEq(_nav(), navBefore, "totalAssets continuous");
        assertEq(_underlying.balanceOf(address(_rcm)), 0, "live balance moved to the vault");
        assertEq(uint256(_readVestingData().transferredTokens), 0, "T reset");
        assertEq(uint256(_readVestingData().lastUpdateBalance), 0, "L re-anchored");
    }

    /// @notice IL-8793: the anchor formula that ignored the pending vested amount P is refused,
    /// because after the push transferredTokens = 500e18 but the anchor only vests 300e18.
    function testRescheduleVesting_natSpecAnchorWithPendingVested_reverts() public {
        _setupPendingVested();

        vm.prank(_operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardsClaimManager.UnsafeReschedule.selector,
                uint256(20 days),
                uint256(block.timestamp - 6 days),
                uint256(300e18),
                uint256(500e18)
            )
        );
        _rcm.rescheduleVesting(20 days, uint32(block.timestamp - 6 days));
    }

    /// @notice IL-8793: the corrected anchor t0' = now - ceil((T + P) * vt' / L) keeps totalAssets()
    /// continuous; P is pushed to the vault and the curve continues from the new anchor.
    function testRescheduleVesting_correctedAnchorKeepsNavContinuous() public {
        _setupPendingVested();
        uint256 navBefore = _nav();
        uint256 vaultBefore = _underlying.balanceOf(address(_plasmaVault));

        vm.expectEmit(address(_rcm));
        emit RewardsClaimManager.AmountWithdrawn(200e18);
        vm.expectEmit(address(_rcm));
        emit RewardsClaimManager.VestingRescheduled(20 days, block.timestamp - 10 days, 500e18, 1_000e18);
        vm.prank(_operator);
        _rcm.rescheduleVesting(20 days, uint32(block.timestamp - 10 days));

        assertEq(_nav(), navBefore, "totalAssets continuous");
        assertEq(_underlying.balanceOf(address(_plasmaVault)), vaultBefore + 200e18, "P pushed to the vault");
        assertEq(uint256(_readVestingData().transferredTokens), 500e18, "T = T + P");
        assertEq(_rcm.balanceOf(), 0, "nothing pending right after the reschedule");

        vm.warp(block.timestamp + 1 days);
        assertEq(_rcm.balanceOf(), 50e18, "1000e18 * 1 / 20 vests per day");
    }

    /// @notice Documents that the push is part of the call: with a pending amount and a failing asset
    /// transfer the whole reschedule reverts and the schedule is left untouched.
    function testRescheduleVesting_revertsWhenPushTransferFails() public {
        _setupPendingVested();
        VestingData memory before = _readVestingData();

        vm.mockCallRevert(
            address(_underlying),
            abi.encodeWithSelector(ERC20.transfer.selector),
            abi.encodeWithSignature("Error(string)", "paused")
        );
        vm.prank(_operator);
        vm.expectRevert(bytes("paused"));
        _rcm.rescheduleVesting(20 days, uint32(block.timestamp - 10 days));
        vm.clearMockedCalls();

        VestingData memory afterCall = _readVestingData();
        assertEq(uint256(afterCall.vestingTime), uint256(before.vestingTime), "vt unchanged");
        assertEq(uint256(afterCall.updateBalanceTimestamp), uint256(before.updateBalanceTimestamp), "t0 unchanged");
        assertEq(uint256(afterCall.transferredTokens), uint256(before.transferredTokens), "T unchanged");
        assertEq(_rcm.balanceOf(), 200e18, "pending amount untouched");
    }

    /// @notice Clamp window of the IL-7485 incident (P == 0): the push is a no-op, behaviour as before.
    function testRescheduleVesting_clampWindow_movesNothing() public {
        vm.warp(1_779_786_611);
        _writeVestingData({
            vestingTime: 1_814_400,
            updateBalanceTimestamp: 1_779_785_915,
            transferredTokens: 2_200_009_874_193_100,
            lastUpdateBalance: 2_016_009_048_351_496_489
        });
        assertEq(_rcm.balanceOf(), 0, "clamp window");
        uint256 vaultBefore = _underlying.balanceOf(address(_plasmaVault));

        vm.recordLogs();
        vm.prank(_operator);
        _rcm.rescheduleVesting(1_814_400, 1_779_784_631);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_underlying.balanceOf(address(_plasmaVault)), vaultBefore, "nothing moved");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != RewardsClaimManager.AmountWithdrawn.selector,
                "no AmountWithdrawn in the clamp window"
            );
        }
        assertEq(uint256(_readVestingData().transferredTokens), 2_200_009_874_193_100, "T unchanged");
    }

    /// @notice No (vt', t0') tuple can lower totalAssets(), and no token is created or lost.
    function testFuzz_rescheduleVesting_neverLowersNav(uint32 vt_, uint32 t0Seed_) public {
        _setupPendingVested();
        uint32 newVt = uint32(bound(vt_, 1, 365 days));
        uint32 newT0 = uint32(bound(t0Seed_, block.timestamp - 2 * uint256(newVt), block.timestamp));

        uint256 navBefore = _nav();
        uint256 sumBefore = _underlying.balanceOf(address(_plasmaVault)) + _underlying.balanceOf(address(_rcm));

        vm.prank(_operator);
        try _rcm.rescheduleVesting(newVt, newT0) {
            assertGe(_nav(), navBefore, "totalAssets must not drop");
            assertEq(
                _underlying.balanceOf(address(_plasmaVault)) + _underlying.balanceOf(address(_rcm)),
                sumBefore,
                "tokens conserved"
            );
            VestingData memory data = _readVestingData();
            assertLe(uint256(data.transferredTokens), uint256(data.lastUpdateBalance), "T <= L");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), RewardsClaimManager.UnsafeReschedule.selector, "only the guard may refuse");
        }
    }

    // -----------------------------------------------------------------------------------
    // Cross-layer / regression
    // -----------------------------------------------------------------------------------

    /// @notice transferVestedTokensToVault must short-circuit (no transfer, no revert) when
    /// the clamp window is active.
    function testTransferVestedTokensToVault_noOps_duringClampWindow() public {
        vm.warp(1_779_786_611);
        _writeVestingData({
            vestingTime: 1_814_400,
            updateBalanceTimestamp: 1_779_785_915,
            transferredTokens: 2_200_009_874_193_100,
            lastUpdateBalance: 2_016_009_048_351_496_489
        });

        uint256 vaultBalanceBefore = _underlying.balanceOf(address(_plasmaVault));

        vm.prank(_operator);
        _rcm.transferVestedTokensToVault();

        assertEq(_underlying.balanceOf(address(_plasmaVault)), vaultBalanceBefore, "no transfer during clamp window");
    }

    /// @notice updateBalance() must rescue the contract from the clamp window: post-call the
    /// state is fully reset (transferredTokens=0, lastUpdateBalance from live balance).
    function testUpdateBalance_unsticks_afterClampWindow() public {
        vm.warp(1_779_786_611);
        _writeVestingData({
            vestingTime: 1_814_400,
            updateBalanceTimestamp: 1_779_785_915,
            transferredTokens: 2_200_009_874_193_100,
            lastUpdateBalance: 2_016_009_048_351_496_489
        });

        // Seed the manager with the underlying balance the storage tuple advertises.
        deal(address(_underlying), address(_rcm), 2_016_009_048_351_496_489);

        vm.prank(_operator);
        _rcm.updateBalance();

        VestingData memory data = _readVestingData();
        assertEq(uint256(data.transferredTokens), 0, "transferredTokens reset to zero");
        assertEq(uint256(data.updateBalanceTimestamp), uint32(block.timestamp), "timestamp rebased to now");
        // lastUpdateBalance must equal the IERC20 balance of the manager AFTER any drain in
        // updateBalance — during the clamp window balanceOf() returns 0, so no drain happens
        // and the live IERC20 balance is the full seed.
        assertEq(
            uint256(data.lastUpdateBalance),
            2_016_009_048_351_496_489,
            "lastUpdateBalance reflects live token balance"
        );
    }

    // -----------------------------------------------------------------------------------
    // vestedAt helper (single source of truth)
    // -----------------------------------------------------------------------------------

    /// @notice vestedAt must be in [0, lastUpdateBalance] for any input.
    function testFuzz_vestedAt_bounds(
        uint128 lastUpdateBalance,
        uint32 vestingTime,
        uint32 updateBalanceTimestamp,
        uint64 nowTs
    ) public pure {
        uint256 v = RewardsClaimManagersStorageLib.vestedAt(
            uint256(lastUpdateBalance),
            vestingTime,
            updateBalanceTimestamp,
            uint256(nowTs)
        );

        assertLe(v, uint256(lastUpdateBalance), "vestedAt cannot exceed lastUpdateBalance");
    }

    /// @notice vestedAt must be monotone non-decreasing in nowTs_.
    function testFuzz_vestedAt_monotone(
        uint128 lastUpdateBalance,
        uint32 vestingTime,
        uint32 updateBalanceTimestamp,
        uint64 nowA,
        uint64 nowB
    ) public pure {
        if (nowA > nowB) (nowA, nowB) = (nowB, nowA);

        uint256 va = RewardsClaimManagersStorageLib.vestedAt(
            uint256(lastUpdateBalance),
            vestingTime,
            updateBalanceTimestamp,
            uint256(nowA)
        );
        uint256 vb = RewardsClaimManagersStorageLib.vestedAt(
            uint256(lastUpdateBalance),
            vestingTime,
            updateBalanceTimestamp,
            uint256(nowB)
        );

        assertLe(va, vb, "vestedAt must be monotone non-decreasing in nowTs");
    }

    /// @notice vestedAt returns 0 when vestingTime == 0 (matches "vest disabled" semantics).
    function testVestedAt_returnsZero_whenVestingTimeIsZero() public pure {
        uint256 v = RewardsClaimManagersStorageLib.vestedAt({
            lastUpdateBalance_: 1_000e18,
            vestingTime_: 0,
            updateBalanceTimestamp_: 100,
            nowTs_: 200
        });
        assertEq(v, 0);
    }

    /// @notice vestedAt clamps to lastUpdateBalance once elapsed >= vestingTime.
    function testVestedAt_clampsToLastUpdateBalance_whenFullyMatured() public pure {
        uint256 v = RewardsClaimManagersStorageLib.vestedAt({
            lastUpdateBalance_: 1_000e18,
            vestingTime_: 100,
            updateBalanceTimestamp_: 1_000,
            nowTs_: 5_000
        });
        assertEq(v, 1_000e18);
    }

    /// @notice vestedAt computes the linear formula on the open interval (t0, t0+vt).
    function testVestedAt_linearProgressionOnOpenInterval() public pure {
        // 50% of the curve elapsed ⇒ 50% vested.
        uint256 v = RewardsClaimManagersStorageLib.vestedAt({
            lastUpdateBalance_: 1_000e18,
            vestingTime_: 200,
            updateBalanceTimestamp_: 1_000,
            nowTs_: 1_100
        });
        assertApproxEqAbs(v, 500e18, 1, "50% elapsed => ~50% vested");
    }
}
