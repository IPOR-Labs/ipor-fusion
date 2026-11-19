// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title PlasmaVaultRedeemReleasedSharesRepriceTest
/// @notice IL-9437 (BugPoCer F-37): while released shares are pending, `redeem` pulls the redeemed amount plus the
///         released-shares reserve from the markets, and the refresh of the touched markets books their unrecorded
///         yield and raises the share price. The reserve is priced again in every attempt, so the check of the
///         WithdrawManager at the refreshed price still passes although the only slack is 2% of the redeemer's shares.
/// @dev Runs on the locally built vault of PlasmaVaultMockMarketsTestBase. Unbooked yield is minted straight to a market.
contract PlasmaVaultRedeemReleasedSharesRepriceTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant USER_DEPOSIT = 1_000e6;
    uint256 internal constant OTHER_DEPOSIT = 9_000e6;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev The release is strictly later than the request and a withdraw window is set, so the requester can still
    ///      `redeemFromRequest` the released shares
    function _requestAndReleaseInWindow(address user_, uint256 shares_) internal {
        withdrawManager.updateWithdrawWindow(1 days);
        vm.prank(user_);
        withdrawManager.requestShares(shares_);
        vm.warp(block.timestamp + 2);
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, shares_);
    }

    /// @dev User A and the requester B deposit, the whole vault sits in market B, B requests and the role releases
    ///      half of the supply
    function _prepareHalfReleased() internal returns (uint256 released) {
        _deposit(user, USER_DEPOSIT);
        _deposit(other, OTHER_DEPOSIT);
        _allocate(address(marketB), USER_DEPOSIT + OTHER_DEPOSIT);
        released = plasmaVault.totalSupply() / 2;
        _requestAndReleaseInWindow(other, released);
    }

    function testShouldRedeemSmallAmountWhileLargeReleasePendingAfterUnbookedYield() public {
        uint256 released = _prepareHalfReleased();
        _accrue(address(marketB), 50);

        uint256 shares = plasmaVault.totalSupply() / 1_000;
        assertEq(asset.balanceOf(address(plasmaVault)), 0, "premise: no idle cash, the redeem must pull from markets");
        assertLt(
            plasmaVault.totalAssetsInMarket(MARKET_B),
            asset.balanceOf(address(marketB)),
            "premise: market B holds unbooked yield"
        );
        // premise of the finding: the reserve moves by more than the 2% slack of the redeemer's own shares
        assertGt(
            (released * 50) / 10_000,
            (shares * 2) / 100,
            "premise: reserve increase exceeds the slack of the redeemer"
        );

        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);

        assertGt(assets, 0, "assets redeemed");
        assertEq(asset.balanceOf(user), 10_000_000e6 - USER_DEPOSIT + assets, "user received the assets");
        assertApproxEqAbs(
            plasmaVault.totalAssetsInMarket(MARKET_B),
            asset.balanceOf(address(marketB)),
            2,
            "market B booked its yield by the refresh"
        );
    }

    function testShouldKeepReleasedSharesRedeemableAfterRedeem() public {
        uint256 released = _prepareHalfReleased();
        _accrue(address(marketB), 50);

        uint256 shares = plasmaVault.totalSupply() / 1_000;
        vm.prank(user);
        plasmaVault.redeem(shares, user, user);

        uint256 before = asset.balanceOf(other);
        vm.prank(other);
        uint256 assets = plasmaVault.redeemFromRequest(released, other, other);

        assertGt(assets, 0, "released shares redeemed");
        assertEq(asset.balanceOf(other) - before, assets, "requester received the assets");
    }

    function testShouldRedeemWhileReleasedSharesPendingWithoutYield() public {
        _prepareHalfReleased();

        uint256 shares = plasmaVault.totalSupply() / 1_000;
        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);

        assertGt(assets, 0, "assets redeemed");
        assertEq(asset.balanceOf(user), 10_000_000e6 - USER_DEPOSIT + assets, "user received the assets");
    }

    function testShouldRedeemWithoutReleasedShares() public {
        _deposit(user, USER_DEPOSIT);
        _deposit(other, OTHER_DEPOSIT);
        _allocate(address(marketB), USER_DEPOSIT + OTHER_DEPOSIT);
        _accrue(address(marketB), 50);

        uint256 shares = plasmaVault.totalSupply() / 1_000;
        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);

        assertGt(assets, 0, "assets redeemed");
    }

    /// @dev IL-9719: idle cash covers the redeemed amount plus the released-shares reserve but not the buffered target,
    ///      and the markets hold nothing: a pull brings no cash, so the loop must stop after the first round instead of
    ///      repeating it REDEEM_ATTEMPTS times (every round would refresh the markets and emit MarketBalancesUpdated)
    function testShouldStopPullingWhenMarketsCannotSupplyOnRedeem() public {
        _deposit(user, 8_000e6);
        _deposit(other, 2_000e6);
        uint256 released = plasmaVault.balanceOf(other);
        _requestAndReleaseInWindow(other, released);

        uint256 shares = plasmaVault.balanceOf(user);
        uint256 redeemAssets = plasmaVault.convertToAssets(shares);
        uint256 reserve = plasmaVault.convertToAssets(released);
        uint256 idle = asset.balanceOf(address(plasmaVault));
        assertLe(redeemAssets + reserve, idle, "premise: idle covers the payout and the reserve");
        assertGt(
            redeemAssets + (redeemAssets * 2) / 100 + reserve,
            idle,
            "premise: the slippage-buffered target exceeds idle, so the redeem tries to pull"
        );
        assertEq(asset.balanceOf(address(marketA)) + asset.balanceOf(address(marketB)), 0, "premise: markets empty");

        vm.recordLogs();
        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 refreshes;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(plasmaVault) &&
                logs[i].topics[0] == keccak256("MarketBalancesUpdated(uint256[],int256)")
            ) {
                ++refreshes;
            }
        }

        assertGt(assets, 0, "assets redeemed");
        assertLe(refreshes, 1, "the pull loop stopped after a round that added no idle assets");
    }
}
