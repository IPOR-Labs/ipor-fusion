// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {AssetDistributionProtectionLib} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title PlasmaVaultRefreshAboveMarketLimitTest
/// @notice IL-9612 (Olympix 2026-11-06 M22): `updateMarketsBalances` stores the real balance of a market that is above
///         its market limit instead of reverting with `MarketLimitExceeded`, so the cached NAV is no longer stuck below
///         the real one (deposits at a stale price, IL-8819). The limit is still enforced where assets move: `execute`
///         and the market pulls of `withdraw` and `redeem` revert when a market they touch ends above its limit.
/// @dev Fixture: 1,000 USDC deposited, 490 in market A (limit 50% of the NAV), market B unused (limit 100%). An
///      unbooked gain of 20% on A (588 USDC against a NAV of 1,098) puts A above its limit (549) before every test.
///      Pre-hook tests wire `UpdateBalancesPreHook`, which refreshes through `updateMarketsBalances`.
contract PlasmaVaultRefreshAboveMarketLimitTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant ALLOCATION = 490e6;
    uint256 internal constant IDLE = DEPOSIT - ALLOCATION;
    uint256 internal constant GAIN_BPS = 2_000;
    uint256 internal constant SECOND_DEPOSIT = 100e6;
    uint256 internal constant LIMIT_50_PERCENT = 5e17;
    uint256 internal constant LIMIT_100_PERCENT = 1e18;
    uint256 internal constant ONE_HUNDRED_PERCENT = 1e18;

    /// @dev real value of the vault's position in market A after the unbooked gain
    uint256 internal valueInA;

    function setUp() public override {
        super.setUp();

        _deposit(user, DEPOSIT);
        _setLimits(LIMIT_50_PERCENT, LIMIT_100_PERCENT);
        _allocate(address(marketA), ALLOCATION);
        _accrue(address(marketA), GAIN_BPS);

        valueInA = marketA.convertToAssets(marketA.balanceOf(address(plasmaVault)));
    }

    // ------------------------------------------------------------------ precondition

    function testShouldHaveMarketAboveLimitOnlyInRealBalance() public view {
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), ALLOCATION, "cache holds the allocation");
        assertGt(valueInA, _limitOf(IDLE + valueInA), "real balance of market A is above its limit");
        assertLe(ALLOCATION, _limitOf(DEPOSIT), "cached balance of market A is within its limit");
    }

    // ------------------------------------------------------------------ refresh stores the balance (M22)

    /// @dev Regression of M22: on the vault before IL-9612 this refresh reverts with MarketLimitExceeded and the cache
    ///      keeps 490 USDC
    function testShouldStoreBalanceAboveMarketLimitOnRefresh() public {
        // given
        uint256 feeSharesBefore = plasmaVault.balanceOf(_feeAccount());

        // when
        vm.prank(updater);
        uint256 totalAssetsAfter = plasmaVault.updateMarketsBalances(_marketIds(MARKET_A));

        // then
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), valueInA, "cache = real balance above the limit");
        assertEq(totalAssetsAfter, IDLE + valueInA, "returned NAV includes the booked gain");
        assertEq(plasmaVault.totalAssets(), IDLE + valueInA, "NAV includes the booked gain");
        assertGt(valueInA, _limitOf(plasmaVault.totalAssets()), "market A stays above its limit after the refresh");
        assertGt(plasmaVault.balanceOf(_feeAccount()), feeSharesBefore, "performance fee crystallized on the gain");
    }

    /// @dev Economic effect of M22: after the refresh a deposit is priced on the NAV with the gain, so the depositor
    ///      gets fewer shares than at the stale cache and takes no part of the gain of the existing holders
    function testShouldPriceDepositOnRefreshedNavWhenMarketAboveLimit() public {
        // given
        uint256 sharesAtStaleNav = plasmaVault.previewDeposit(SECOND_DEPOSIT);
        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_marketIds(MARKET_A));

        // when
        uint256 shares = _depositAndReturnShares(other, SECOND_DEPOSIT);

        // then
        assertLt(shares, sharesAtStaleNav, "entry priced on the booked gain, not on the stale cache");
        assertApproxEqAbs(plasmaVault.convertToAssets(shares), SECOND_DEPOSIT, 1, "depositor holds its deposit");
        assertEq(plasmaVault.totalAssets(), IDLE + valueInA + SECOND_DEPOSIT, "NAV = refreshed NAV + deposit");
    }

    // ------------------------------------------------------------------ execute still enforces the limit

    /// @dev Unchanged by IL-9612: execute refreshes the market it touches and checks its limit
    function testShouldRevertExecuteSupplyingMarketAboveLimit() public {
        _assertExecuteSupplyRevertsOnMarketA();
    }

    /// @dev The stored over-limit balance does not open execute: supplying more to market A still reverts
    function testShouldRevertExecuteSupplyingMarketAboveLimitAfterRefresh() public {
        // given
        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_marketIds(MARKET_A));

        // when / then
        _assertExecuteSupplyRevertsOnMarketA();
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), valueInA, "refreshed cache kept");
    }

    // ------------------------------------------------------------------ withdrawals do not check the limit (D-003)

    /// @dev IL-9694 D-003 (was: reverts, IL-9612): a withdraw above the idle balance pulls from market A and succeeds
    ///      although market A ends above its limit
    function testShouldWithdrawPullingFromMarketAboveLimit() public {
        _assertWithdrawPullsFromMarketA(IDLE + 10e6);
    }

    function testShouldWithdrawPullingFromMarketAboveLimitAfterRefresh() public {
        // given
        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_marketIds(MARKET_A));

        // when / then
        _assertWithdrawPullsFromMarketA(IDLE + 10e6);
    }

    /// @dev IL-9694 D-003 (was: reverts, IL-9612): redeem pulls 2% more than the payout from market A and succeeds
    function testShouldRedeemPullingFromMarketAboveLimit() public {
        // given
        uint256 shares = plasmaVault.convertToShares(IDLE + 10e6);
        uint256 balanceBefore = asset.balanceOf(user);

        // when
        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);

        // then
        assertGe(assets, IDLE, "payout exceeds the idle balance, so market A was pulled");
        assertEq(asset.balanceOf(user), balanceBefore + assets, "user received the payout");
        assertLt(plasmaVault.totalAssetsInMarket(MARKET_A), valueInA, "assets pulled from market A");
    }

    // ------------------------------------------------------------------ pre-hook refresh on user flows

    /// @dev Regression of M22 on user flows: the pre-hook refresh of market A no longer reverts the deposit (before
    ///      IL-9612 every deposit reverted with MarketLimitExceeded while A was above its limit), and the deposit is
    ///      priced on the refreshed NAV
    function testShouldDepositWithUpdateBalancesPreHookWhenMarketAboveLimit() public {
        // given
        _wireUpdateBalancesPreHook(plasmaVault.deposit.selector);
        uint256 sharesAtStaleNav = plasmaVault.previewDeposit(SECOND_DEPOSIT);

        // when
        uint256 shares = _depositAndReturnShares(other, SECOND_DEPOSIT);

        // then
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), valueInA, "pre-hook stored the real balance of A");
        assertLt(shares, sharesAtStaleNav, "entry priced on the booked gain");
        assertApproxEqAbs(plasmaVault.convertToAssets(shares), SECOND_DEPOSIT, 1, "depositor holds its deposit");
    }

    /// @dev Regression of M22 on user flows: a withdraw paid from the idle balance pulls nothing from the markets, so
    ///      no limit applies; the pre-hook refresh above the limit no longer reverts it
    function testShouldWithdrawFromIdleWithUpdateBalancesPreHookWhenMarketAboveLimit() public {
        // given
        _wireUpdateBalancesPreHook(plasmaVault.withdraw.selector);
        uint256 balanceBefore = asset.balanceOf(user);

        // when
        vm.prank(user);
        plasmaVault.withdraw(SECOND_DEPOSIT, user, user);

        // then
        assertEq(asset.balanceOf(user), balanceBefore + SECOND_DEPOSIT, "withdraw paid from idle");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), valueInA, "pre-hook stored the real balance of A");
    }

    /// @dev IL-9694 D-003 (was: reverts, IL-9612): with the pre-hook the refresh passes and the market pull of the
    ///      withdraw no longer checks the limit
    function testShouldWithdrawWithUpdateBalancesPreHookPullingFromMarketAboveLimit() public {
        // given
        _wireUpdateBalancesPreHook(plasmaVault.withdraw.selector);

        // when / then
        _assertWithdrawPullsFromMarketA(IDLE + 10e6);
    }

    // ------------------------------------------------------------------ helpers

    function _assertExecuteSupplyRevertsOnMarketA() private {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(supplyFuseA),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(marketA), 1e6, 0)))
        );

        vm.prank(alpha);
        try plasmaVault.execute(calls) {
            fail("execute supplying market A must revert");
        } catch (bytes memory reason) {
            (uint256 marketId, uint256 balanceInMarket, uint256 limit) = _decodeMarketLimitExceeded(reason);
            assertEq(marketId, MARKET_A, "limit of market A");
            assertApproxEqAbs(balanceInMarket, valueInA + 1e6, 2, "checked balance = real balance + supply");
            assertApproxEqAbs(limit, _limitOf(IDLE + valueInA), 2, "limit against the gross NAV");
            assertGt(balanceInMarket, limit, "above the limit");
        }
    }

    function _assertWithdrawPullsFromMarketA(uint256 assets_) private {
        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        plasmaVault.withdraw(assets_, user, user);

        assertEq(asset.balanceOf(user), balanceBefore + assets_, "user paid in full");
        assertLt(plasmaVault.totalAssetsInMarket(MARKET_A), valueInA, "assets pulled from market A");
        assertGt(
            plasmaVault.totalAssetsInMarket(MARKET_A),
            _limitOf(plasmaVault.totalAssets()),
            "market A still above its limit after the pull"
        );
    }

    function _decodeMarketLimitExceeded(
        bytes memory reason_
    ) private pure returns (uint256 marketId, uint256 balanceInMarket, uint256 limit) {
        assertEq(reason_.length, 100, "MarketLimitExceeded carries three words");
        assertTrue(
            bytes4(reason_) == AssetDistributionProtectionLib.MarketLimitExceeded.selector,
            "reverts with MarketLimitExceeded"
        );
        assembly ("memory-safe") {
            marketId := mload(add(reason_, 36))
            balanceInMarket := mload(add(reason_, 68))
            limit := mload(add(reason_, 100))
        }
    }

    function _depositAndReturnShares(address user_, uint256 amount_) private returns (uint256 shares) {
        vm.prank(user_);
        shares = plasmaVault.deposit(amount_, user_);
    }

    function _limitOf(uint256 grossNav_) private pure returns (uint256) {
        return (grossNav_ * LIMIT_50_PERCENT) / ONE_HUNDRED_PERCENT;
    }

    function _marketIds(uint256 marketId_) private pure returns (uint256[] memory marketIds) {
        marketIds = new uint256[](1);
        marketIds[0] = marketId_;
    }
}
