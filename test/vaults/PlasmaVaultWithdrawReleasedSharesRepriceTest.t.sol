// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title PlasmaVaultWithdrawReleasedSharesRepriceTest
/// @notice IL-9436 (BugPoCer F-36): while released shares are pending, `withdraw` pulls the released-shares reserve from
///         the markets, and the refresh of the touched markets books their unrecorded yield and raises the share price.
///         The reserve is priced again after every pull (bounded loop, as in `_redeem`), so the check of the
///         WithdrawManager at the refreshed price still passes.
/// @dev Runs on the locally built vault of PlasmaVaultMockMarketsTestBase. Unbooked yield is minted straight to a market.
contract PlasmaVaultWithdrawReleasedSharesRepriceTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant USER_DEPOSIT = 1_000e6;
    uint256 internal constant OTHER_DEPOSIT = 9_000e6;
    uint256 internal constant WITHDRAW_AMOUNT = 100e6;
    /// @dev mirrors PlasmaVault.WITHDRAW_FROM_MARKETS_OFFSET
    uint256 internal constant OFFSET = 10;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev Like `_requestAndRelease` of the base, but the release is strictly later than the request and a withdraw
    ///      window is set, so the requester can still `redeemFromRequest` the released shares
    function _requestAndReleaseInWindow(address user_, uint256 shares_) internal {
        withdrawManager.updateWithdrawWindow(1 days);
        vm.prank(user_);
        withdrawManager.requestShares(shares_);
        vm.warp(block.timestamp + 2);
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, shares_);
    }

    /// @dev User A and the requester B deposit, the whole vault sits in market B, B requests and the role releases
    ///      `releasedBps_` of the supply
    function _prepareSingleMarket(uint256 releasedBps_) internal returns (uint256 released) {
        _deposit(user, USER_DEPOSIT);
        _deposit(other, OTHER_DEPOSIT);
        _allocate(address(marketB), USER_DEPOSIT + OTHER_DEPOSIT);
        released = (plasmaVault.totalSupply() * releasedBps_) / 10_000;
        _requestAndReleaseInWindow(other, released);
    }

    function testShouldWithdrawWhileReleasedSharesPendingAfterUnbookedYield() public {
        _prepareSingleMarket(3_000);
        _accrue(address(marketB), 50);

        uint256 idleBefore = asset.balanceOf(address(plasmaVault));
        assertEq(idleBefore, 0, "premise: no idle cash, the withdraw must pull from the market");

        vm.prank(user);
        plasmaVault.withdraw(WITHDRAW_AMOUNT, user, user);

        assertEq(asset.balanceOf(user), 10_000_000e6 - USER_DEPOSIT + WITHDRAW_AMOUNT, "user received the assets");
        assertApproxEqAbs(
            plasmaVault.totalAssetsInMarket(MARKET_B),
            asset.balanceOf(address(marketB)),
            2,
            "market B booked its yield by the refresh"
        );
    }

    function testShouldKeepReleasedSharesRedeemableAfterWithdraw() public {
        uint256 released = _prepareSingleMarket(3_000);
        _accrue(address(marketB), 50);

        vm.prank(user);
        plasmaVault.withdraw(WITHDRAW_AMOUNT, user, user);

        uint256 before = asset.balanceOf(other);
        vm.prank(other);
        uint256 assets = plasmaVault.redeemFromRequest(released, other, other);

        assertGt(assets, 0, "released shares redeemed");
        assertEq(asset.balanceOf(other) - before, assets, "requester received the assets");
    }

    function testShouldWithdrawWhileReleasedSharesPendingWithoutYield() public {
        _prepareSingleMarket(3_000);

        vm.prank(user);
        plasmaVault.withdraw(WITHDRAW_AMOUNT, user, user);

        assertEq(asset.balanceOf(user), 10_000_000e6 - USER_DEPOSIT + WITHDRAW_AMOUNT, "user received the assets");
    }

    /// @dev Both markets on the instant-withdraw list [A, B] and both hold unbooked yield. Market A holds just enough
    ///      for the first pull, so the first refresh (A only) raises the reserve by a little, the second pull empties A
    ///      and reaches B for the first time, and B's refresh raises the reserve again: a fixed second pull fails.
    function testShouldWithdrawWhenALaterPullReachesAnotherMarketWithUnbookedYield() public {
        _deposit(user, USER_DEPOSIT);
        _deposit(other, OTHER_DEPOSIT);
        _allocate(address(marketA), 100e6);
        _allocate(address(marketB), USER_DEPOSIT + OTHER_DEPOSIT - 100e6);
        uint256 released = (plasmaVault.totalSupply() * 100) / 10_000;
        _requestAndReleaseInWindow(other, released);

        _accrue(address(marketA), 500);
        _accrue(address(marketB), 50);

        // first pull target at the cached price; top market A up so it covers exactly that target (plus dust)
        uint256 firstTarget = WITHDRAW_AMOUNT / 20 + OFFSET + (plasmaVault.convertToAssets(released) * 10001) / 10000;
        uint256 marketAAssets = asset.balanceOf(address(marketA));
        assertLt(marketAAssets, firstTarget + 1_000, "premise: market A needs a top-up");
        asset.mint(address(marketA), firstTarget + 1_000 - marketAAssets);

        uint256 marketBCachedBefore = plasmaVault.totalAssetsInMarket(MARKET_B);
        assertLt(marketBCachedBefore, asset.balanceOf(address(marketB)), "premise: market B holds unbooked yield");
        assertEq(asset.balanceOf(address(plasmaVault)), 0, "premise: no idle cash");

        vm.prank(user);
        plasmaVault.withdraw(WITHDRAW_AMOUNT / 20, user, user);

        assertEq(asset.balanceOf(user), 10_000_000e6 - USER_DEPOSIT + WITHDRAW_AMOUNT / 20, "user received the assets");
        assertApproxEqAbs(
            plasmaVault.totalAssetsInMarket(MARKET_B),
            asset.balanceOf(address(marketB)),
            2,
            "market B reached by a later pull and booked"
        );
        assertApproxEqAbs(
            plasmaVault.totalAssetsInMarket(MARKET_A),
            asset.balanceOf(address(marketA)),
            2,
            "market A booked"
        );
    }

    /// @dev Idle cash covers `assets_` plus the released-shares reserve but not the 0.01% buffer, and the markets hold
    ///      nothing: a pull brings no cash, so the loop must stop after the first round instead of repeating it
    ///      REDEEM_ATTEMPTS times (every round would refresh the markets and emit MarketBalancesUpdated)
    function testShouldStopPullingWhenMarketsCannotSupply() public {
        _deposit(user, 8_000e6);
        _deposit(other, 2_000e6);
        uint256 released = plasmaVault.balanceOf(other);
        _requestAndReleaseInWindow(other, released);

        uint256 idle = asset.balanceOf(address(plasmaVault));
        uint256 reserve = plasmaVault.convertToAssets(released);
        uint256 amount = idle - reserve - 5;
        assertLe(amount, plasmaVault.convertToAssets(plasmaVault.balanceOf(user)), "premise: user owns the amount");
        assertLt(idle, amount + OFFSET + (reserve * 10001) / 10000, "premise: idle is short of the buffered target");
        assertEq(asset.balanceOf(address(marketA)) + asset.balanceOf(address(marketB)), 0, "premise: markets empty");

        vm.recordLogs();
        vm.prank(user);
        plasmaVault.withdraw(amount, user, user);
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

        assertEq(asset.balanceOf(user), 10_000_000e6 - 8_000e6 + amount, "user received the assets");
        assertLe(refreshes, 2, "the pull loop stopped after a round that added no idle assets");
    }
}
