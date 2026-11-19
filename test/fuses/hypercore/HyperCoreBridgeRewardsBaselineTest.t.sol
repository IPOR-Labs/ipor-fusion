// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HyperCoreEffectSettlementBase, MockEffectSettlementChainlinkFeed} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {NavJumpFloorFixture} from "./HyperCoreNavJumpFloorFixture.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";
import {PrecompileLib} from "./simulation/src/PrecompileLib.sol";

/// @dev Stand-in for a replacement rewards manager set on the vault while a bridge is pending: NAV counts its live
///      underlying balance (`PlasmaVault._getGrossTotalAssets` reads `balanceOf()`), and `push()` moves that balance
///      into the vault like a `transferVestedTokensToVault` would.
contract HyperCoreBridgeRewardsReplacementManager {
    using SafeERC20 for IERC20;

    IERC20 private immutable _asset;
    address private immutable _vault;

    constructor(address asset_, address vault_) {
        _asset = IERC20(asset_);
        _vault = vault_;
    }

    function balanceOf() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function push() external {
        _asset.safeTransfer(_vault, _asset.balanceOf(address(this)));
    }
}

/// @dev 8-decimal ERC20 standing in for a Core-linked token that is NOT the vault's underlying.
contract HyperCoreBridgeRewardsNonUnderlyingToken is ERC20 {
    constructor() ERC20("Non Underlying", "NUT") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

/// @title HyperCoreBridgeRewardsBaselineTest
/// @notice IL-9529 (3sigma #2, CR fix B1/A5) regression suite on a FusionFactory vault + offline Core simulator. A
///         Core -> EVM bridge of the vault's underlying, on a vault with a RewardsClaimManager, must stay pending until
///         the EVM credit lands. Nothing that moves underlying from or into the manager may stand in for the credit:
///         a push of vested underlying (PUBLIC_ROLE `transferVestedTokensToVault` or the keeper's `updateBalance`),
///         vesting accrual, an unvested donation to the manager, a keeper inflow into the manager, or a combination.
///         A re-anchor of the vesting schedule or a change of the rewards manager inside the window waits for
///         `timeoutAt`.
/// @dev The harmful window is "Core debit visible, EVM credit not executed yet". The simulator debits Core only when
///      it processes the queued CoreWriter action, so the window is reproduced explicitly: the spot-balance precompile
///      (0x801) is mocked to return the balance minus the bridged amount, and `CoreSimulatorLib.nextBlock()` (which
///      would execute the send and credit the EVM side) is withheld. The NAV reference `navRef` is measured right
///      before the bridge (market 55 refreshed live), not hard-coded; `_fairNav` adds the vesting accrued since then.
///      Base proof (IL-9527 D-A3): on the audited code (870f0a3b) the EVM-balance effect is a plain threshold
///      `balanceOf(vault) >= expectedBalance`, so every case in which the vault balance grows by A before the credit
///      fails there. On the two-sum fix (HEAD 63f58256, D-004) the cases that compose accrual, an unvested donation
///      or a keeper inflow with a push (Codex B1, A5 (b)), the manager change (A5 (a)) and the re-anchor wait fail;
///      they pass with the push counter (D-034). The accrual-only case passes everywhere and guards only against a
///      mutant that replaces the vault-balance threshold by the vested sum. The credit-only, no-manager and
///      non-underlying cases document behaviour that must not change.
///      This file uses only symbols that exist on 870f0a3b (binding fields are read from raw storage slots), so it
///      also compiles there.
contract HyperCoreBridgeRewardsBaselineTest is HyperCoreEffectSettlementBase {
    address internal constant SPOT_BALANCE_PRECOMPILE = address(0x801);

    /// @dev Underlying held by the rewards manager (V), fully vested before the bridge unless the case says otherwise.
    uint256 internal constant REWARDS = 200_000e6;
    /// @dev Bridged amount A: Core wei (USDC `weiDecimals` = 8) and EVM units (6 decimals).
    uint64 internal constant BRIDGE_WEI = 50_000e8;
    uint256 internal constant BRIDGE = 50_000e6;
    uint256 internal constant CORE_DEPOSIT = 100_000e6;
    uint256 internal constant ATTACK = 200_000e6;
    /// @dev A deposit larger than the vault NAV: with a self-paid donation the attack only pays when D > NAV.
    uint256 internal constant WHALE_ATTACK = 3_000_000e6;
    /// @dev Short vesting so that accrual can exceed A well inside the default 600 s transfer timeout.
    uint256 internal constant VESTING_SECONDS = 1_000;
    /// @dev Tolerance for the 1 USDC Core activation fee and simulator rounding.
    uint256 internal constant NAV_TOLERANCE = 2e6;
    /// @dev `PendingAction` slot offsets: 7 = `timeoutAt`, 9 = `lastOrderL1Block` (uint64 @ byte 0) followed by the
    ///      rewards binding, 10 and 11 = the two sums, 12 = the counter snapshot (absent before IL-9529).
    uint256 internal constant SLOT_TIMEOUT_AT = 7;
    uint256 internal constant SLOT_ORDER_AND_MANAGER = 9;
    uint256 internal constant SLOT_RAW_SUM = 10;
    uint256 internal constant SLOT_VESTED_SUM = 11;
    uint256 internal constant SLOT_COUNTER = 12;

    /// @dev Non-underlying Core token for the unbound case (8 decimals, priced at $2).
    uint64 internal constant NUT_TOKEN = 9;
    uint64 internal constant NUT_CORE_WEI = 100e8;
    uint64 internal constant NUT_BRIDGE_WEI = 20e8;

    address internal _attacker = makeAddr("ATTACKER");
    address internal _keeper = makeAddr("REWARDS_KEEPER");
    address internal _donor = makeAddr("DONOR");

    RewardsClaimManager internal _rewards;
    HyperCorePendingReader internal _pendingReader;
    /// @dev NAV measured right before the bridge (`_bridgeWithCoreDebitVisible`).
    uint256 internal _navRef;
    /// @dev Total vested amount of the manager (`balanceOf()` + `transferredTokens`) when `_navRef` was measured.
    uint256 internal _vestedAtRef;

    function setUp() public override {
        super.setUp();
        _pendingReader = new HyperCorePendingReader();
        // The factory creates the rewards manager and sets it on the vault
        // (FusionFactoryLogicLib: setRewardsClaimManagerAddress).
        _rewards = RewardsClaimManager(PlasmaVaultGovernance(address(_vault)).getRewardsClaimManagerAddress());
        assertTrue(address(_rewards) != address(0), "factory vault has a rewards manager");

        vm.startPrank(_atomist);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _attacker, 0);
        _accessManager.grantRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, _keeper, 0);
        _rewards.setupVestingTime(VESTING_SECONDS);
        vm.stopPrank();

        _usdc.mint(_attacker, ATTACK);
        vm.prank(_attacker);
        _usdc.approve(address(_vault), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // (1) PUBLIC push of vested underlying while the credit is missing
    // ------------------------------------------------------------------

    /// @dev Fails on 870f0a3b: the push meets `expectedBalance`, the deposit mints at `navRef - A`.
    function testRewardsPushDoesNotOpenBridgeGateBeforeEvmCredit() public {
        _fundRewards(true);
        (uint256 navRef, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();
        uint256 navPending = _vault.totalAssets();

        vm.prank(_attacker);
        _rewards.transferVestedTokensToVault();
        assertEq(_rewards.balanceOf(), 0, "vested underlying pushed");
        assertEq(_vault.totalAssets(), navPending, "the push is NAV-neutral");

        _assertAttackerDepositBlocked(navRef, pendingUntil);
        assertTrue(_isPendingLive(), "a rewards push must not settle the bridge");
    }

    // ------------------------------------------------------------------
    // (2) keeper updateBalance while the credit is missing
    // ------------------------------------------------------------------

    /// @dev Fails on 870f0a3b: `updateBalance` pushes `balanceOf()` into the vault, like the PUBLIC push.
    function testRewardsKeeperUpdateBalanceDoesNotOpenBridgeGateBeforeEvmCredit() public {
        _fundRewards(true);
        (uint256 navRef, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();
        uint256 navPending = _vault.totalAssets();

        vm.prank(_keeper);
        _rewards.updateBalance();
        assertEq(_rewards.balanceOf(), 0, "vested underlying pushed by the keeper");
        assertEq(_vault.totalAssets(), navPending, "the keeper push is NAV-neutral");

        _assertAttackerDepositBlocked(navRef, pendingUntil);
        assertTrue(_isPendingLive(), "a keeper push must not settle the bridge");
    }

    /// @dev D-034 liveness cost, pinned: `updateBalance` re-anchors the vesting schedule (new `updateBalanceTimestamp`,
    ///      `transferredTokens` reset), so the push counter cannot be compared any more and the record waits for
    ///      `timeoutAt` even after the credit. Fails on 870f0a3b (the push opens the gate) and on the two-sum fix (the
    ///      credit opens it: both sums and the vault balance reach their thresholds).
    function testRewardsKeeperReanchorWhilePendingWaitsForTimeoutAfterEvmCredit() public {
        _fundRewards(true);
        (uint256 navRef, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();

        vm.prank(_keeper);
        _rewards.updateBalance();
        assertTrue(_isPendingLive(), "re-anchor alone keeps the gate closed");

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertTrue(_isPendingLive(), "after a re-anchor even the credit waits for timeoutAt");
        (bool minted, , bytes memory reason) = _tryDeposit(ATTACK);
        assertFalse(minted, "deposit blocked until timeoutAt");
        assertEq(reason, abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));

        _assertPendingUntilTimeout();
        assertApproxEqAbs(_refreshAndTotalAssets(), navRef, NAV_TOLERANCE, "NAV whole at the timeout");
        _assertAttackerRoundTripNeutral();
    }

    // ------------------------------------------------------------------
    // (3) vesting accrual while the credit is missing
    // ------------------------------------------------------------------

    /// @dev Passes on 870f0a3b and on every fix (the vault balance does not move). It guards only against a mutant
    ///      that replaces the vault-balance threshold by the vested sum (`vault + RewardsClaimManager.balanceOf()`):
    ///      accrual alone grows that sum by more than A.
    function testVestingAccrualDoesNotOpenBridgeGateBeforeEvmCredit() public {
        _fundRewards(false);
        vm.warp(block.timestamp + 100);
        (, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();
        uint256 vestedAtSend = _rewards.balanceOf();

        _accrueVesting();
        assertGe(_rewards.balanceOf(), vestedAtSend + BRIDGE, "accrual grew the vested sum by at least A");
        assertTrue(_isPendingLive(), "accrual must not settle the bridge");

        vm.prank(_attacker);
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));
        _vault.deposit(ATTACK, _attacker);

        // The credit still opens the gate while vesting runs.
        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "credit landed, gate open");
    }

    /// @dev Fails on 870f0a3b. Accrual then a push: the vault balance grows by the vested amount (>= A) and the vested
    ///      sum grows by the accrual (>= A); the raw sum (vault + manager token balance) stays flat. This is the case that
    ///      defeats a single vested-sum threshold (3sigma's critique of that fix).
    function testVestingAccrualThenPushDoesNotOpenBridgeGateBeforeEvmCredit() public {
        _fundRewards(false);
        vm.warp(block.timestamp + 100);
        (, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();
        uint256 evmAtSend = _usdc.balanceOf(address(_vault));

        _accrueVesting();
        vm.prank(_attacker);
        _rewards.transferVestedTokensToVault();
        assertGe(
            _usdc.balanceOf(address(_vault)),
            evmAtSend + BRIDGE,
            "the push alone meets the vault-balance threshold"
        );

        (bool minted, , bytes memory reason) = _tryDeposit(ATTACK);
        assertFalse(minted, "accrual plus push must not open the bridge gate before the EVM credit");
        assertEq(reason, abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));
        assertTrue(_isPendingLive(), "still pending");

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "credit landed, gate open");
    }

    // ------------------------------------------------------------------
    // (4) Codex B1: accrual + unvested donation (or keeper inflow) to the manager + PUBLIC push
    // ------------------------------------------------------------------

    /// @dev Codex B1, exact. Fails on 870f0a3b and on the two-sum fix (HEAD 63f58256): accrual a >= A, a donation
    ///      d = A of underlying to the manager (unvested, so `balanceOf()` does not see it) and a PUBLIC push of the
    ///      vested B + a meet all three thresholds (vault: B + a >= A, raw: d >= A, vested: a >= A). The deposit is
    ///      priced at fair - A; with D > NAV the depositor ends with more than D + d once the credit lands and the
    ///      donation vests to all holders. With the push counter the push is subtracted and the gate stays pending.
    function testAccrualDonationAndPushDoNotOpenBridgeGateBeforeEvmCredit() public {
        _usdc.mint(_attacker, WHALE_ATTACK + BRIDGE);
        _runAccrualInflowAndPush(false, WHALE_ATTACK);
    }

    /// @dev Keeper-inflow variant of B1. Fails on 870f0a3b and on the two-sum fix: a keeper claim of A underlying that
    ///      lands in the manager inside the window takes the place of the donation, so the attacker pays nothing and
    ///      profits for any deposit size.
    function testAccrualKeeperInflowAndPushDoNotOpenBridgeGateBeforeEvmCredit() public {
        _runAccrualInflowAndPush(true, ATTACK);
    }

    /// @dev A5 (b): `vestingTime == 0`, so `balanceOf()` is the manager's live balance and a keeper claim of A into
    ///      the manager is counted in NAV at once. A PUBLIC push of it meets all three thresholds on the two-sum fix
    ///      (vault +A, raw +A, vested +A) without anyone paying: the deposit is priced at fair - A. Fails on 870f0a3b
    ///      and on HEAD 63f58256; with the push counter (`transferredTokens` grows by the pushed A) it stays pending.
    function testZeroVestingKeeperInflowAndPushDoNotOpenBridgeGateBeforeEvmCredit() public {
        vm.prank(_atomist);
        _rewards.setupVestingTime(0);
        (uint256 navRef, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();

        // As a keeper reward claim would: underlying lands in the manager inside the window.
        _usdc.mint(address(_rewards), BRIDGE);
        assertEq(_rewards.balanceOf(), BRIDGE, "vestingTime == 0: NAV counts the inflow at once");
        uint256 fair = navRef + BRIDGE;

        vm.prank(_attacker);
        _rewards.transferVestedTokensToVault();
        assertEq(_rewards.balanceOf(), 0, "the inflow was pushed into the vault");

        (bool minted, uint256 navAtMint, bytes memory reason) = _tryDeposit(ATTACK);
        if (minted) {
            assertApproxEqAbs(navAtMint, fair - BRIDGE, NAV_TOLERANCE, "deposit priced at fair - A");
            _assertAttackerProfit(ATTACK, false);
        }
        assertFalse(minted, "keeper inflow plus push opened the bridge gate before the EVM credit");
        assertEq(reason, abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "the credit after the counted push opens the gate");
        assertApproxEqAbs(_refreshAndTotalAssets(), fair, NAV_TOLERANCE, "NAV whole after the credit");
        _assertAttackerRoundTripNeutral();
    }

    /// @dev A gap 4: an unvested donation of A to the manager plus a PUBLIC push of the vested balance, no accrual.
    ///      Fails on 870f0a3b (the push opens the plain threshold). On the two-sum fix the vested sum stays short by A;
    ///      with the counter the push is subtracted. Kills a raw-sum-only mutant end to end.
    function testUnvestedDonationAndPushDoNotOpenBridgeGateBeforeEvmCredit() public {
        _fundRewards(true);
        (uint256 navRef, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();

        _usdc.mint(_attacker, BRIDGE);
        vm.prank(_attacker);
        _usdc.transfer(address(_rewards), BRIDGE);
        assertEq(_rewards.balanceOf(), REWARDS, "the donation is unvested");
        vm.prank(_attacker);
        _rewards.transferVestedTokensToVault();

        _assertAttackerDepositBlocked(navRef, pendingUntil);
        assertTrue(_isPendingLive(), "donation plus push must not settle the bridge");

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "credit landed, gate open");
        assertApproxEqAbs(_refreshAndTotalAssets(), navRef, NAV_TOLERANCE, "NAV whole after the credit");
    }

    // ------------------------------------------------------------------
    // (5) credit without a push, (6) credit and a push
    // ------------------------------------------------------------------

    function testEvmCreditWithoutPushOpensBridgeGateAtFullNav() public {
        _fundRewards(true);
        (uint256 navRef, ) = _bridgeWithCoreDebitVisible();
        uint256 evmAtSend = _usdc.balanceOf(address(_vault));

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertEq(_usdc.balanceOf(address(_vault)), evmAtSend + BRIDGE, "EVM credit landed");
        assertEq(_rewards.balanceOf(), REWARDS, "rewards untouched");
        assertFalse(_isPendingLive(), "credit alone opens the gate");

        assertApproxEqAbs(_refreshAndTotalAssets(), navRef, NAV_TOLERANCE, "NAV whole after the credit");
        _assertAttackerRoundTripNeutral();
    }

    /// @dev A push before the credit must not leave the vault stuck until the timeout: once the credit lands, the vault
    ///      balance has grown by A plus the counted push and both sums by exactly A (equality is enough).
    function testRewardsPushThenEvmCreditOpensBridgeGateAtFullNav() public {
        _fundRewards(true);
        (uint256 navRef, ) = _bridgeWithCoreDebitVisible();

        vm.prank(_attacker);
        _rewards.transferVestedTokensToVault();
        assertTrue(_isPendingLive(), "push alone keeps the gate closed");

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "credit after the push opens the gate");

        assertApproxEqAbs(_refreshAndTotalAssets(), navRef, NAV_TOLERANCE, "NAV whole after push and credit");
        _assertAttackerRoundTripNeutral();
    }

    // ------------------------------------------------------------------
    // (7) rewards manager changed while the bridge is pending (A5 (a))
    // ------------------------------------------------------------------

    /// @dev A5 (a). Fails on 870f0a3b and on HEAD 63f58256: the record is bound to the old manager, so a push from the
    ///      replacement manager (value NAV counts once it is set) meets the vault threshold and leaves the old
    ///      manager's sums untouched. With D-034 a manager change inside the window waits for `timeoutAt`, also after
    ///      the credit.
    function testRewardsManagerReplacedWhilePendingWaitsForTimeout() public {
        (uint256 navRef, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();
        _replaceRewardsManagerAndPush();

        _assertAttackerDepositBlockedAt(navRef + BRIDGE, pendingUntil);
        assertTrue(_isPendingLive(), "a push from a replacement manager must not settle the bridge");

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertTrue(_isPendingLive(), "after a manager change even the credit waits for timeoutAt");
        _assertPendingUntilTimeout();
    }

    /// @dev A5 (a), the record that had no manager to bind: fails on 870f0a3b and on HEAD 63f58256 (the plain threshold
    ///      opens on the replacement manager's push). With D-034 a rewards manager set inside the window on a bridge of
    ///      the underlying waits for `timeoutAt`.
    function testRewardsManagerSetWhilePendingOnUnboundBridgeWaitsForTimeout() public {
        vm.prank(address(_rewards));
        PlasmaVaultGovernance(address(_vault)).setRewardsClaimManagerAddress(address(0));
        (uint256 navRef, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();
        assertEq(_slot(SLOT_ORDER_AND_MANAGER) >> 64, 0, "sent without a manager: the record is not bound");
        _replaceRewardsManagerAndPush();

        _assertAttackerDepositBlockedAt(navRef + BRIDGE, pendingUntil);
        assertTrue(_isPendingLive(), "a push from a manager set inside the window must not settle the bridge");

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertTrue(_isPendingLive(), "after a manager change even the credit waits for timeoutAt");
        _assertPendingUntilTimeout();
    }

    // ------------------------------------------------------------------
    // (8) no rewards manager / another token: the plain vault-balance threshold, as before
    // ------------------------------------------------------------------

    /// @dev Protection boundary: without a rewards manager the record is not bound to one and the effect stays the
    ///      plain `balanceOf(vault) >= expectedBalance` threshold. Any inflow that NAV did not count opens it, here a
    ///      funded donation of A; the donor pays for it, so the NAV read after the gate opens is whole.
    function testWithoutRewardsManagerFundedInflowOpensBridgeGateAsBefore() public {
        vm.prank(address(_rewards));
        PlasmaVaultGovernance(address(_vault)).setRewardsClaimManagerAddress(address(0));
        (uint256 navRef, ) = _bridgeWithCoreDebitVisible();

        _usdc.mint(_donor, BRIDGE);
        vm.prank(_donor);
        _usdc.transfer(address(_vault), BRIDGE);
        assertFalse(_isPendingLive(), "plain threshold: a funded inflow of A opens the gate");

        assertApproxEqAbs(_refreshAndTotalAssets(), navRef, NAV_TOLERANCE, "NAV whole: the donor paid A");
        vm.clearMockedCalls();
    }

    /// @dev A gap 2: a bridge of a granted token that is not the underlying, on a vault with a rewards manager, is not
    ///      bound (manager pushes move only the underlying): every binding field is zero and the credit alone settles.
    function testNonUnderlyingBridgeWithRewardsManagerIsUnboundAndSettlesOnCredit() public {
        _fundRewards(true);
        HyperCoreBridgeRewardsNonUnderlyingToken token = _grantNonUnderlyingToken();
        CoreSimulatorLib.forceSpotBalance(address(_vault), NUT_TOKEN, NUT_CORE_WEI);
        _refreshAndTotalAssets();

        _sendAssetToEvm(NUT_TOKEN, NUT_BRIDGE_WEI);
        assertTrue(_isPendingLive(), "bridge enqueued");
        assertEq(_slot(SLOT_ORDER_AND_MANAGER) >> 64, 0, "no manager and no anchor bound");
        assertEq(_slot(SLOT_RAW_SUM), 0, "no raw sum");
        assertEq(_slot(SLOT_VESTED_SUM), 0, "no vested sum");
        assertEq(_slot(SLOT_COUNTER), 0, "no counter snapshot");

        _settle(2);
        assertEq(token.balanceOf(address(_vault)), NUT_BRIDGE_WEI, "credit landed");
        assertFalse(_isPendingLive(), "the credit alone settles an unbound bridge");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev Codex B1 body. Vesting has just started (`_fundRewards(false)`), the bridge is sent 100 s later and 300 s
    ///      of accrual (60k > A) pass inside the window; then A of underlying reaches the manager (the attacker's
    ///      donation, or a keeper inflow when `keeperInflow_`), the attacker pushes and deposits `deposit_`.
    function _runAccrualInflowAndPush(bool keeperInflow_, uint256 deposit_) internal {
        _fundRewards(false);
        vm.warp(block.timestamp + 100);
        (, uint64 pendingUntil) = _bridgeWithCoreDebitVisible();
        uint256 vestedAtSend = _rewards.balanceOf();

        _accrueVesting();
        assertGe(_rewards.balanceOf(), vestedAtSend + BRIDGE, "accrual of at least A");
        if (keeperInflow_) {
            _usdc.mint(address(_rewards), BRIDGE);
        } else {
            vm.prank(_attacker);
            _usdc.transfer(address(_rewards), BRIDGE);
        }
        uint256 fair = _fairNav();

        vm.prank(_attacker);
        _rewards.transferVestedTokensToVault();
        assertEq(_rewards.balanceOf(), 0, "vested balance pushed");
        assertApproxEqAbs(_fairNav(), fair, 1, "the push moves no value");

        (bool minted, uint256 navAtMint, bytes memory reason) = _tryDeposit(deposit_);
        if (minted) {
            assertApproxEqAbs(navAtMint, fair - BRIDGE, NAV_TOLERANCE, "deposit priced at fair - A");
            _assertAttackerProfit(keeperInflow_ ? deposit_ : deposit_ + BRIDGE, true);
        }
        assertFalse(minted, "accrual + inflow + push opened the bridge gate before the EVM credit");
        assertEq(reason, abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));
        assertTrue(_isPendingLive(), "still pending");

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "the credit opens the gate");
        assertApproxEqAbs(_refreshAndTotalAssets(), _fairNav(), NAV_TOLERANCE, "NAV whole after the credit");
        _assertAttackerRoundTripNeutral();
    }

    /// @dev Sets a replacement rewards manager holding A of underlying (counted in NAV from now on) and pushes it.
    function _replaceRewardsManagerAndPush() internal {
        HyperCoreBridgeRewardsReplacementManager replacement = new HyperCoreBridgeRewardsReplacementManager(
            address(_usdc),
            address(_vault)
        );
        _usdc.mint(address(replacement), BRIDGE);
        vm.prank(address(_rewards));
        PlasmaVaultGovernance(address(_vault)).setRewardsClaimManagerAddress(address(replacement));

        uint256 evmBefore = _usdc.balanceOf(address(_vault));
        replacement.push();
        assertEq(_usdc.balanceOf(address(_vault)), evmBefore + BRIDGE, "the push alone meets the vault threshold");
    }

    /// @dev Funds the rewards manager with V = `REWARDS` of underlying. `settled_` warps past the vesting period so
    ///      `balanceOf()` stays V for the rest of the test; otherwise vesting has just started.
    function _fundRewards(bool settled_) internal {
        _usdc.mint(address(_rewards), REWARDS);
        vm.prank(_keeper);
        _rewards.updateBalance();
        if (settled_) {
            vm.warp(block.timestamp + VESTING_SECONDS + 1);
            assertEq(_rewards.balanceOf(), REWARDS, "vesting settled");
        }
    }

    /// @dev Core deposit, refresh (navRef), Core -> EVM bridge of A, then the window and L1-block gates pass while the
    ///      Core debit is visible (0x801 mocked to `total - A`) and the EVM credit is withheld.
    function _bridgeWithCoreDebitVisible() internal returns (uint256 navRef_, uint64 pendingUntil_) {
        _coreDeposit(CORE_DEPOSIT);
        _settle(2);
        navRef_ = _refreshAndTotalAssets();
        _navRef = navRef_;
        _vestedAtRef = _vestedTotal();

        uint256 evmAtSend = _usdc.balanceOf(address(_vault));
        HyperCoreLib.SpotBalance memory spot = HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN);
        _sendAssetToEvm(USDC_TOKEN, BRIDGE_WEI);
        assertTrue(_isPendingLive(), "bridge enqueued");
        pendingUntil_ = _pendingUntil();

        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        vm.mockCall(
            SPOT_BALANCE_PRECOMPILE,
            abi.encode(address(_vault), USDC_TOKEN),
            abi.encode(spot.total - BRIDGE_WEI, spot.hold, spot.entryNtl)
        );
        assertEq(_usdc.balanceOf(address(_vault)), evmAtSend, "EVM credit withheld");
        assertTrue(_isPendingLive(), "gate closed while the EVM credit is missing");
    }

    /// @dev Warps 300 s (vesting of 200k over 1000 s accrues 60k > A) and one L1 block, inside the 600 s timeout.
    function _accrueVesting() internal {
        vm.warp(block.timestamp + 300);
        vm.roll(block.number + 1);
    }

    /// @dev Everything the manager has vested since its anchor: still claimable plus already pushed.
    function _vestedTotal() internal view returns (uint256) {
        return _rewards.balanceOf() + uint256(_rewards.getVestingData().transferredTokens);
    }

    /// @dev Fair NAV with the credit A still owed to the vault: `navRef` plus the vesting accrued since it was measured.
    ///      Valid while the schedule is not re-anchored.
    function _fairNav() internal view returns (uint256) {
        return _navRef + _vestedTotal() - _vestedAtRef;
    }

    /// @dev Attempts a deposit by the attacker without expecting an outcome; on success reports the NAV it was priced at.
    function _tryDeposit(uint256 amount_) internal returns (bool minted_, uint256 navAtMint_, bytes memory reason_) {
        vm.prank(_attacker);
        try _vault.deposit(amount_, _attacker) returns (uint256) {
            minted_ = true;
            navAtMint_ = _vault.totalAssets() - amount_;
        } catch (bytes memory err_) {
            reason_ = err_;
        }
    }

    /// @dev Expects the deposit to revert with `HyperCoreActionPending(pendingUntil)`. If it mints instead, first proves
    ///      the harm: the attacker was priced at a NAV short by the bridged amount.
    function _assertAttackerDepositBlocked(uint256 navRef_, uint64 pendingUntil_) internal {
        _assertAttackerDepositBlockedAt(navRef_, pendingUntil_);
    }

    /// @dev As `_assertAttackerDepositBlocked`, with the fair NAV given explicitly.
    function _assertAttackerDepositBlockedAt(uint256 fair_, uint64 pendingUntil_) internal {
        (bool minted, uint256 navAtMint, bytes memory reason) = _tryDeposit(ATTACK);
        if (minted) {
            assertApproxEqAbs(navAtMint, fair_ - BRIDGE, NAV_TOLERANCE, "deposit priced at fair - A");
        }
        assertFalse(minted, "the bridge gate opened before the EVM credit: attacker minted at fair - A");
        assertEq(reason, abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil_));
    }

    /// @dev Only reached where the gate opened early (audited code / two-sum fix): lets the credit land, optionally lets
    ///      the manager's balance vest to all holders (next keeper re-anchor + one vesting period), then redeems every
    ///      attacker share and proves the attacker got back more than it paid.
    function _assertAttackerProfit(uint256 paid_, bool vestManagerBalance_) internal {
        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        if (vestManagerBalance_) {
            vm.prank(_keeper);
            _rewards.updateBalance();
            vm.warp(block.timestamp + VESTING_SECONDS + 1);
            vm.roll(block.number + 1);
        }
        uint256 shares = _vault.balanceOf(_attacker);
        vm.prank(_attacker);
        uint256 got = _vault.redeem(shares, _attacker, _attacker);
        assertGt(got, paid_, "depositor profit, paid by the existing holders");
    }

    /// @dev The record stays pending one second before `timeoutAt` and settles at `timeoutAt`.
    function _assertPendingUntilTimeout() internal {
        uint64 timeoutAt = uint64(_slot(SLOT_TIMEOUT_AT));
        assertGt(timeoutAt, block.timestamp + 1, "still inside the window");
        vm.warp(timeoutAt - 1);
        vm.roll(block.number + 1);
        assertTrue(_isPendingLive(), "pending until timeoutAt");
        vm.warp(timeoutAt);
        assertFalse(_isPendingLive(), "timeoutAt opens the gate");
    }

    /// @dev Once the gate is open at a whole NAV, depositing and redeeming at once returns what was deposited.
    function _assertAttackerRoundTripNeutral() internal {
        vm.prank(_attacker);
        uint256 shares = _vault.deposit(ATTACK, _attacker);
        vm.prank(_attacker);
        uint256 got = _vault.redeem(shares, _attacker, _attacker);
        assertApproxEqRel(got, ATTACK, 0.0001e18, "no free value for the depositor");
    }

    /// @dev Registers `NUT_TOKEN` on the simulator, prices it at $2 and grants it in market 55 next to the base set.
    function _grantNonUnderlyingToken() internal returns (HyperCoreBridgeRewardsNonUnderlyingToken token_) {
        token_ = new HyperCoreBridgeRewardsNonUnderlyingToken();
        _hyperCore.registerTokenInfo(
            NUT_TOKEN,
            PrecompileLib.TokenInfo({
                name: "NUT",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(token_),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: 0
            })
        );

        MockEffectSettlementChainlinkFeed feed = new MockEffectSettlementChainlinkFeed(2e8, 8);
        address[] memory assets = new address[](1);
        assets[0] = address(token_);
        address[] memory sources = new address[](1);
        sources[0] = address(feed);
        vm.prank(_atomist);
        _priceManager.setAssetsPriceSources(assets, sources);

        // Full market 55 substrate list (grantMarketSubstrates replaces it): base set + the token.
        bytes32[] memory substrates = new bytes32[](11);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        substrates[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        substrates[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        substrates[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        substrates[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        substrates[6] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        substrates[7] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6,
            1_000_000e6
        );
        substrates[8] = HyperCoreSubstrateLib.encodeSpotToken(NUT_TOKEN, address(token_));
        substrates[9] = HyperCoreSubstrateLib.encodeSendCap(NUT_TOKEN, type(uint128).max);
        substrates[10] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(NUT_TOKEN));
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(
            MARKET_ID,
            NavJumpFloorFixture.withFloor(substrates)
        );
    }

    function _isPendingLive() internal view returns (bool) {
        ReadResult memory r = _vault.read(
            address(_pendingReader),
            abi.encodeCall(HyperCorePendingReader.isActionPending, ())
        );
        return abi.decode(r.data, (bool));
    }

    function _pendingUntil() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(_vault), PENDING_SLOT)));
    }

    function _slot(uint256 offset_) internal view returns (uint256) {
        return uint256(vm.load(address(_vault), bytes32(uint256(PENDING_SLOT) + offset_)));
    }

    function _coreDeposit(uint256 amount_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: amount_})
            )
        );
        _vault.execute(actions);
    }

    function _sendAssetToEvm(uint64 tokenIndex_, uint64 amountWei_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_sendFuse),
            abi.encodeWithSelector(
                HyperCoreSendFuse.enterSendAsset.selector,
                HyperCoreSendFuseSendAssetData({
                    destination: HyperCoreLib.systemAddress(tokenIndex_),
                    sourceDex: HyperCoreLib.SPOT_DEX,
                    destinationDex: HyperCoreLib.SPOT_DEX,
                    tokenIndex: tokenIndex_,
                    amountWei: amountWei_
                })
            )
        );
        _vault.execute(actions);
    }
}
