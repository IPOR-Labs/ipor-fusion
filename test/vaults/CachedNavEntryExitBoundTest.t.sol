// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title CachedNavEntryExitBoundTest
/// @notice IL-9608 (M18): `totalAssets` is the idle balance plus the cached market balances. A deposit does not
///         refresh the markets, and a withdraw or redeem that fits into the idle balance does not either, so an entry
///         is priced on a stale (lower) NAV after an unbooked gain and an exit from idle on a stale (higher) NAV after an
///         unbooked loss. The value that changes hands is bounded by the participant's share of the unbooked delta;
///         wiring `UpdateBalancesPreHook` on the user selector removes it.
/// @dev Pinning test of documented behaviour (contracts/vaults/README.md, "Cached NAV: what deposits and idle exits are
///      priced on"): it passes on the base commit, nothing in the contracts changes. The performance fee is 0 so that the
///      hook case measures the pricing only.
contract CachedNavEntryExitBoundTest is PlasmaVaultMockMarketsTestBase {
    uint256 public constant AMOUNT = 1_000_000e6;
    /// @dev Absolute dust allowed on a fair price (virtual offset and rounding of the vault), 0.01 asset unit
    uint256 public constant DUST = 1e4;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        _deposit(user, AMOUNT);
        _allocate(address(marketA), AMOUNT);
    }

    // ------------------------------------------------------------------ entry after an unbooked gain

    function testShouldPriceDepositOnStaleNavAndBoundTheValueTransferByShareOfUnbookedGain() public {
        uint256 gain = _unbookedGain(1000);

        _deposit(other, AMOUNT);
        uint256 otherShares = plasmaVault.balanceOf(other);
        uint256 supply = plasmaVault.totalSupply();

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_ids());

        uint256 value = plasmaVault.convertToAssets(otherShares);
        assertGt(value, AMOUNT, "premise: the depositor entered below the real NAV and gains value");
        uint256 profit = value - AMOUNT;
        uint256 bound = Math.mulDiv(gain, otherShares, supply);
        assertLe(profit, bound + DUST, "profit is at most the depositor's share of the unbooked gain");
        assertApproxEqAbs(profit, bound, DUST, "and it is that share (nothing else leaks)");
        assertLt(profit, gain, "the depositor cannot take the whole gain");
    }

    function testShouldNotTransferValueToDepositorWhenPreHookRefreshesBeforeDeposit() public {
        _wireUpdateBalancesPreHook(PlasmaVault.deposit.selector);
        _unbookedGain(1000);

        _deposit(other, AMOUNT);

        uint256 value = plasmaVault.convertToAssets(plasmaVault.balanceOf(other));
        assertApproxEqAbs(value, AMOUNT, DUST, "priced on the refreshed NAV: no value transfer");
    }

    // ------------------------------------------------------------------ exit from idle after an unbooked loss

    function testShouldPayRedeemFromIdleOnStaleNavAndBoundTheOverpaymentByShareOfUnbookedLoss() public {
        _deposit(other, AMOUNT);
        /// @dev setUp allocated everything of the first deposit; the second deposit stays idle and covers the redeem
        assertEq(asset.balanceOf(address(plasmaVault)), AMOUNT, "setup: idle covers the exit");
        uint256 loss = _unbookedLoss(5000);
        uint256 supply = plasmaVault.totalSupply();
        uint256 navBefore = plasmaVault.totalAssets();
        uint256 sharesOut = plasmaVault.balanceOf(other) / 2;

        vm.prank(other);
        uint256 paid = plasmaVault.redeem(sharesOut, other, other);

        uint256 fair = Math.mulDiv(sharesOut, navBefore - loss, supply);
        assertGt(paid, fair, "premise: the exit from idle was priced on the stale, higher NAV");
        uint256 overpaid = paid - fair;
        uint256 bound = Math.mulDiv(loss, sharesOut, supply);
        assertLe(overpaid, bound + DUST, "overpayment is at most the leaver's share of the unbooked loss");
        assertApproxEqAbs(overpaid, bound, DUST, "and it is that share");
    }

    function testShouldPayRedeemFromIdleAtFairPriceWhenPreHookRefreshesBeforeRedeem() public {
        _deposit(other, AMOUNT);
        _wireUpdateBalancesPreHook(PlasmaVault.redeem.selector);
        uint256 loss = _unbookedLoss(5000);
        uint256 supply = plasmaVault.totalSupply();
        uint256 navBefore = plasmaVault.totalAssets();
        uint256 sharesOut = plasmaVault.balanceOf(other) / 2;

        vm.prank(other);
        uint256 paid = plasmaVault.redeem(sharesOut, other, other);

        uint256 fair = Math.mulDiv(sharesOut, navBefore - loss, supply);
        assertApproxEqAbs(paid, fair, DUST, "priced on the refreshed NAV: no overpayment");
    }

    // ------------------------------------------------------------------ helpers

    function _unbookedGain(uint256 bps_) internal returns (uint256 gain) {
        gain = (asset.balanceOf(address(marketA)) * bps_) / 10_000;
        _accrue(address(marketA), bps_);
        assertEq(plasmaVault.totalAssets(), AMOUNT + _idleAssets(), "premise: the gain is not in the cached NAV");
    }

    function _unbookedLoss(uint256 bps_) internal returns (uint256 loss) {
        loss = (asset.balanceOf(address(marketA)) * bps_) / 10_000;
        _loss(address(marketA), bps_);
    }

    function _idleAssets() internal view returns (uint256) {
        return asset.balanceOf(address(plasmaVault));
    }

    function _ids() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = MARKET_A;
    }
}
