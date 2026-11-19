// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {AssetDistributionProtectionLib} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title PlasmaVaultWithdrawAboveMarketLimitTest
/// @notice IL-9694 D-003 (3sigma audit v2 finding #15, IL-9700): the market pulls of `withdraw` and `redeem` no longer
///         check market limits, so a user can exit through a market that sits above its limit. `execute` keeps the
///         absolute limit check (executeInternal keeps it too, covered by PlasmaVaultCallbackMarketLimitTest).
/// @dev Fixture as in PlasmaVaultRefreshAboveMarketLimitTest: 1,000 USDC deposited, 490 in market A (limit 50% of the
///      NAV), an unbooked gain of 20% puts A (588 USDC) above its limit (549) before every test.
contract PlasmaVaultWithdrawAboveMarketLimitTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant ALLOCATION = 490e6;
    uint256 internal constant IDLE = DEPOSIT - ALLOCATION;
    uint256 internal constant GAIN_BPS = 2_000;
    uint256 internal constant EXTRA = 10e6;
    uint256 internal constant LIMIT_50_PERCENT = 5e17;
    uint256 internal constant LIMIT_100_PERCENT = 1e18;
    uint256 internal constant ONE_HUNDRED_PERCENT = 1e18;

    uint256 internal valueInA;

    function setUp() public override {
        super.setUp();

        _deposit(user, DEPOSIT);
        _setLimits(LIMIT_50_PERCENT, LIMIT_100_PERCENT);
        _allocate(address(marketA), ALLOCATION);
        _accrue(address(marketA), GAIN_BPS);

        valueInA = marketA.convertToAssets(marketA.balanceOf(address(plasmaVault)));
    }

    function testShouldHaveMarketAboveLimitAfterDrift() public view {
        assertGt(valueInA, _limitOf(IDLE + valueInA), "real balance of market A is above its limit");
    }

    /// @dev Regression of #15: on 603cff61 this withdraw reverts with MarketLimitExceeded in the pull from market A
    function testShouldWithdrawLargerThanIdlePullingFromMarketAboveLimit() public {
        // given
        uint256 balanceBefore = asset.balanceOf(user);
        uint256 assets = IDLE + EXTRA;

        // when
        vm.prank(user);
        plasmaVault.withdraw(assets, user, user);

        // then
        assertEq(asset.balanceOf(user), balanceBefore + assets, "user paid in full");
        assertLt(plasmaVault.totalAssetsInMarket(MARKET_A), valueInA, "assets pulled from market A");
        assertGt(
            plasmaVault.totalAssetsInMarket(MARKET_A),
            _limitOf(plasmaVault.totalAssets()),
            "market A still above its limit after the pull"
        );
    }

    /// @dev Regression of #15 for redeem: on 603cff61 the market pull reverts with MarketLimitExceeded
    function testShouldRedeemLargerThanIdlePullingFromMarketAboveLimit() public {
        // given
        uint256 balanceBefore = asset.balanceOf(user);
        uint256 shares = plasmaVault.convertToShares(IDLE + EXTRA);

        // when
        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);

        // then
        assertGe(assets, IDLE, "payout exceeds the idle balance, so market A was pulled");
        assertEq(asset.balanceOf(user), balanceBefore + assets, "user received the payout");
        assertLt(plasmaVault.totalAssetsInMarket(MARKET_A), valueInA, "assets pulled from market A");
    }

    /// @dev The decided change is limited to withdrawals: execute raising the market above its limit still reverts
    function testShouldRevertExecuteSupplyingMarketAboveLimit() public {
        // given
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(supplyFuseA),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(marketA), 1e6, 0)))
        );

        // when
        vm.prank(alpha);
        try plasmaVault.execute(calls) {
            fail("execute supplying market A must revert");
        } catch (bytes memory reason) {
            // then
            assertEq(reason.length, 100, "MarketLimitExceeded carries three words");
            assertTrue(
                bytes4(reason) == AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                "reverts with MarketLimitExceeded"
            );
            uint256 marketId;
            uint256 balanceInMarket;
            uint256 limit;
            assembly ("memory-safe") {
                marketId := mload(add(reason, 36))
                balanceInMarket := mload(add(reason, 68))
                limit := mload(add(reason, 100))
            }
            assertEq(marketId, MARKET_A, "limit of market A");
            assertApproxEqAbs(balanceInMarket, valueInA + 1e6, 2, "checked balance = real balance + supply");
            assertApproxEqAbs(limit, _limitOf(IDLE + valueInA), 2, "limit against the gross NAV");
            assertGt(balanceInMarket, limit, "above the limit");
        }
    }

    function _limitOf(uint256 grossNav_) private pure returns (uint256) {
        return (grossNav_ * LIMIT_50_PERCENT) / ONE_HUNDRED_PERCENT;
    }
}
