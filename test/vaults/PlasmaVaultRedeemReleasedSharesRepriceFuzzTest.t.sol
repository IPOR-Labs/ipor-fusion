// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title PlasmaVaultRedeemReleasedSharesRepriceFuzzTest
/// @notice Olympix scan 2026-11-06, finding 5.2.42 (IL-9673, L42): while released withdrawal requests are unclaimed,
///         a `redeem` that has to pull from markets refreshes them, the share price rises and the reserve of released
///         shares was priced once at the stale price. IL-9437 prices the reserve again after the refresh; the example
///         tests are in PlasmaVaultRedeemReleasedSharesRepriceTest. This fuzz pins the invariant over the whole
///         input space: for any unbooked yield, released fraction and redeem size the redeem succeeds, the market
///         books its yield, and the released shares stay redeemable afterwards.
/// @dev Runs on the locally built vault of PlasmaVaultMockMarketsTestBase. Unbooked yield is minted straight to market B.
contract PlasmaVaultRedeemReleasedSharesRepriceFuzzTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant USER_DEPOSIT = 1_000e6;
    uint256 internal constant OTHER_DEPOSIT = 9_000e6;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    /// @param yieldBps_ unbooked yield of market B (0 to 5%)
    /// @param releasedPercent_ part of the supply released to the requester (10% to 60%)
    /// @param redeemPerTenThousand_ the redeemer's shares as a part of the supply (0.01% to 2%)
    function testFuzzShouldRedeemWhileReleasedSharesPending_afterUnbookedYield(
        uint256 yieldBps_,
        uint256 releasedPercent_,
        uint256 redeemPerTenThousand_
    ) public {
        yieldBps_ = bound(yieldBps_, 0, 500);
        releasedPercent_ = bound(releasedPercent_, 10, 60);
        redeemPerTenThousand_ = bound(redeemPerTenThousand_, 1, 200);

        _deposit(user, USER_DEPOSIT);
        _deposit(other, OTHER_DEPOSIT);
        _allocate(address(marketB), USER_DEPOSIT + OTHER_DEPOSIT);

        uint256 released = (plasmaVault.totalSupply() * releasedPercent_) / 100;
        withdrawManager.updateWithdrawWindow(1 days);
        vm.prank(other);
        withdrawManager.requestShares(released);
        vm.warp(block.timestamp + 2);
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, released);

        _accrue(address(marketB), yieldBps_);

        uint256 shares = (plasmaVault.totalSupply() * redeemPerTenThousand_) / 10_000;
        assertEq(asset.balanceOf(address(plasmaVault)), 0, "premise: no idle cash, the redeem must pull from markets");
        assertLe(shares, plasmaVault.balanceOf(user), "premise: the redeemer owns the shares");

        uint256 userBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);

        assertGt(assets, 0, "assets redeemed");
        assertEq(asset.balanceOf(user) - userBefore, assets, "user received the assets");
        assertApproxEqAbs(
            plasmaVault.totalAssetsInMarket(MARKET_B),
            asset.balanceOf(address(marketB)),
            2,
            "market B booked its yield by the refresh"
        );

        uint256 otherBefore = asset.balanceOf(other);
        vm.prank(other);
        uint256 requesterAssets = plasmaVault.redeemFromRequest(released, other, other);
        assertGt(requesterAssets, 0, "released shares stay redeemable");
        assertEq(asset.balanceOf(other) - otherBefore, requesterAssets, "requester received the assets");
    }
}
