// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title PlasmaVaultPerformanceFeeLossCallTest
/// @notice IL-9403 (F-03): the performance fee owed at the current share price is charged also in a call that
///         lowered the net assets (market exit cost, loss revealed by a refresh). Before the fix
///         `_addPerformanceFee` returned early when the net assets fell between the start of the call and the fee step,
///         so the leaver (or the depositor behind an UpdateBalancesPreHook) escaped the fee on the gap above the HWM.
/// @dev The fee gap exists BEFORE the call (a donation to the vault), not as an unbooked market gain: a gain booked by
///      the refresh of the same call would lift the net assets and the old guard would stay silent, so the test would
///      pass on the old code. Every test of a losing call asserts both premises explicitly: the net assets fall inside
///      the call and the rate at the fee step is still above the HWM.
contract PlasmaVaultPerformanceFeeLossCallTest is PlasmaVaultMockMarketsTestBase {
    uint256 public constant DEPOSIT = 1_000_000e6;
    uint256 public constant DONATION = 20_000e6;
    uint256 public constant EXIT_FEE_BPS = 10;
    /// @dev 1% relative tolerance for the closed-form fee estimate (virtual offset and rounding of the vault)
    uint256 public constant TOLERANCE = 1e16;

    struct Snapshot {
        uint256 assets;
        uint256 supply;
        uint256 rate;
        uint256 hwm;
        uint256 feeShares;
    }

    function _exitFeeBpsMarketA() internal pure override returns (uint256) {
        return EXIT_FEE_BPS;
    }

    // ------------------------------------------------------------------ tests

    function testShouldChargeOwedPerformanceFeeWhenWithdrawExitCostLowersNetAssets() public {
        _prepareGapAboveHwm();
        Snapshot memory s = _snapshot();
        uint256 assetsOut = 600_000e6;

        vm.prank(user);
        plasmaVault.withdraw(assetsOut, user, user);

        uint256 minted = _feeSharesMinted(s);
        uint256 lost = _assertLosingCall(s, assetsOut, 0);
        assertGt(minted, 0, "the owed performance fee was charged");
        assertApproxEqRel(minted, _expectedFeeShares(s, lost), TOLERANCE, "fee equals the share of the gap above HWM");
        assertGt(_hwm(), s.hwm, "the HWM moved to the post-fee rate");
    }

    function testShouldChargeOwedPerformanceFeeWhenRedeemExitCostLowersNetAssets() public {
        _prepareGapAboveHwm();
        Snapshot memory s = _snapshot();
        uint256 shares = plasmaVault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 assetsOut = plasmaVault.redeem(shares, user, user);

        uint256 minted = _feeSharesMinted(s);
        uint256 lost = _assertLosingCall(s, assetsOut, 0);
        assertGt(minted, 0, "the owed performance fee was charged");
        assertApproxEqRel(minted, _expectedFeeShares(s, lost), TOLERANCE, "fee equals the share of the gap above HWM");
        assertGt(_hwm(), s.hwm, "the HWM moved to the post-fee rate");
    }

    function testShouldChargeOwedPerformanceFeeWhenRefreshRevealsLossAboveHwm() public {
        _prepareGapAboveHwm();
        /// @dev the market lost 0.5% of its balance (10,000e6) without the vault knowing, below the donation
        _loss(address(marketA), 50);
        Snapshot memory s = _snapshot();

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_marketIds());

        uint256 minted = _feeSharesMinted(s);
        uint256 lost = _assertLosingCall(s, 0, 0);
        assertGt(minted, 0, "the owed performance fee was charged");
        assertApproxEqRel(minted, _expectedFeeShares(s, lost), TOLERANCE, "fee equals the share of the gap above HWM");
    }

    function testShouldCrystallizeFeeBeforeDepositWhenPreHookRefreshRevealsLoss() public {
        _prepareGapAboveHwm();
        _wireUpdateBalancesPreHook(PlasmaVault.deposit.selector);
        _loss(address(marketA), 50);
        Snapshot memory s = _snapshot();
        uint256 amount = 100_000e6;

        _deposit(other, amount);

        uint256 minted = _feeSharesMinted(s);
        /// @dev the deposit adds `amount` of assets; the refresh inside the pre-hook is what lowered the net assets
        uint256 lost = _assertLosingCall(s, 0, amount);
        assertGt(minted, 0, "the fee was crystallized before the depositor entered");
        assertApproxEqRel(minted, _expectedFeeShares(s, lost), TOLERANCE, "fee on the gap above HWM");
    }

    function testShouldLowerHwmInLosingCallAfterUpdateInterval() public {
        _allocateAll();
        _setHwmUpdateInterval(1 days);
        uint256 hwmBefore = _hwm();
        /// @dev the market lost 1% (20,000e6) that the vault has not booked; no donation, so the rate falls below HWM
        _loss(address(marketA), 100);
        vm.warp(block.timestamp + 2 days);
        uint256 assetsBefore = plasmaVault.totalAssets();

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_marketIds());

        assertLt(plasmaVault.totalAssets(), assetsBefore, "premise: net assets fell inside the call");
        assertLt(_hwm(), hwmBefore, "the HWM was lowered in the losing call (accepted effect of the interval)");
        assertApproxEqRel(_hwm(), _hwmUnitRate(), 1e14, "the HWM follows the current rate");
        assertEq(plasmaVault.balanceOf(_feeAccount()), 0, "no fee below the HWM");
    }

    function testShouldNotChargePerformanceFeeBelowHwmInLosingCall() public {
        _allocateAll();
        uint256 hwmBefore = _hwm();
        _loss(address(marketA), 100);
        uint256 assetsBefore = plasmaVault.totalAssets();

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_marketIds());

        assertLt(plasmaVault.totalAssets(), assetsBefore, "premise: net assets fell inside the call");
        assertLt(_hwmUnitRate(), hwmBefore, "premise: the rate is below the HWM");
        assertEq(plasmaVault.balanceOf(_feeAccount()), 0, "no performance fee below the HWM");
        assertEq(_hwm(), hwmBefore, "the HWM did not move (interval disabled)");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Two holders, everything allocated to market A (the first execute initializes the HWM at rate 1),
    ///      then a donation to the vault lifts the rate 1% above the HWM before any call under test
    function _prepareGapAboveHwm() internal {
        _allocateAll();
        _donate(DONATION);
        assertGt(_hwmUnitRate(), _hwm(), "setup: the fee gap exists before the call");
    }

    function _allocateAll() internal {
        _deposit(user, DEPOSIT);
        _deposit(other, DEPOSIT);
        _allocate(address(marketA), 2 * DEPOSIT);
        assertGt(_hwm(), 0, "setup: HWM initialized");
        assertEq(asset.balanceOf(address(plasmaVault)), 0, "setup: nothing idle");
    }

    function _marketIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = MARKET_A;
        ids[1] = MARKET_B;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s = Snapshot({
            assets: plasmaVault.totalAssets(),
            supply: plasmaVault.totalSupply(),
            rate: _hwmUnitRate(),
            hwm: _hwm(),
            feeShares: plasmaVault.balanceOf(_feeAccount())
        });
    }

    /// @dev Share rate in the unit of the stored HWM: assets per 10 ** decimals() shares times
    ///      FeeManager.HIGH_WATER_MARK_SCALE (IL-9601)
    function _hwmUnitRate() internal view returns (uint256) {
        return
            plasmaVault.convertToAssets(10 ** uint256(plasmaVault.decimals()) * _feeManager().HIGH_WATER_MARK_SCALE());
    }

    function _feeSharesMinted(Snapshot memory s_) internal view returns (uint256) {
        return plasmaVault.balanceOf(_feeAccount()) - s_.feeShares;
    }

    /// @dev Premise 1: net assets fell inside the call. The payout is not a loss, so it is added back (and a deposit subtracted); a fee mint does
    ///      not change total assets. Returns the assets lost inside the call. Premise 2 (rate above HWM at the fee
    ///      step) is the gap that survives the loss: the donation exceeds it and the fee is positive.
    function _assertLosingCall(
        Snapshot memory s_,
        uint256 paidOut_,
        uint256 deposited_
    ) internal view returns (uint256 lost) {
        uint256 assetsAfterPlusPayout = plasmaVault.totalAssets() + paidOut_ - deposited_;
        assertLt(assetsAfterPlusPayout, s_.assets, "premise: net assets fell inside the call");
        lost = s_.assets - assetsAfterPlusPayout;
        assertLt(lost, DONATION, "premise: the loss is smaller than the gap, the rate stays above the HWM");
        assertGt(s_.rate, s_.hwm, "premise: rate above HWM before the call");
    }

    /// @dev Fee shares owed at the rate that remains after `lost_` of assets left, sized on the price after their own
    ///      mint (IL-8870): S * f / (10000 * rate - f) with f = pf * (rate - hwm)
    function _expectedFeeShares(Snapshot memory s_, uint256 lost_) internal view returns (uint256) {
        uint256 rateAtFee = Math.mulDiv(s_.rate, s_.assets - lost_, s_.assets);
        assertGt(rateAtFee, s_.hwm, "premise: rate at the fee step above HWM");
        uint256 feeValue = (rateAtFee - s_.hwm) * _performanceFee();
        return Math.mulDiv(s_.supply, feeValue, rateAtFee * 10_000 - feeValue);
    }
}
