// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CurveStableSwapNGPriceFeed} from "../../../contracts/price_oracle/price_feed/CurveStableSwapNGPriceFeed.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract CurveStableSwapNGPriceFeedTest is Test {
    using SafeCast for int256;

    address public constant PRICE_ORACLE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;
    address public constant PRICE_ORACLE_OWNER = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
    address public oneDollarPriceFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22894761);
        oneDollarPriceFeed = address(new USDPriceFeed());
    }

    function testShouldReturnPriceForCurveStableSwapNGUsdcUsdf() external {
        //given
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address usdf = 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2;

        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;

        address[] memory assets = new address[](2);
        assets[0] = usdc;
        assets[1] = usdf;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = oneDollarPriceFeed;
        priceFeeds[1] = oneDollarPriceFeed;

        vm.startPrank(PRICE_ORACLE_OWNER);
        /// @dev set the price feeds for the assets, for simplicity we use the same price feed for all the assets
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        //when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, PRICE_ORACLE_MIDDLEWARE);

        //then
        (, int256 price, , , ) = priceFeed.latestRoundData();

        /// @dev Both coins priced at exactly $1 (oneDollarPriceFeed), so min_j(price) = 1e18 and the
        /// expected value is exactly `get_virtual_price()` at the pinned block, confirmed by
        /// `cast call 0x72310DAAed61321b02B08A547150c07522c6a976 "get_virtual_price()(uint256)"
        /// --rpc-url $ETHEREUM_PROVIDER_URL --block 22894761` -> 1003161675661446983.
        assertEq(price.toUint256(), 1003161675661446983, "price should equal get_virtual_price() (both coins at $1)");
    }

    function testShouldReturnPriceForCurveStableSwapNGUsdcUsdt() external {
        //given
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address usdt = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;

        address curvePool = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;

        address[] memory assets = new address[](2);
        assets[0] = usdc;
        assets[1] = usdt;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = oneDollarPriceFeed;
        priceFeeds[1] = oneDollarPriceFeed;

        vm.startPrank(PRICE_ORACLE_OWNER);
        /// @dev set the price feeds for the assets, for simplicity we use the same price feed for all the assets
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        //when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, PRICE_ORACLE_MIDDLEWARE);

        //then
        (, int256 price, , , ) = priceFeed.latestRoundData();

        /// @dev Both coins priced at exactly $1 (oneDollarPriceFeed), so min_j(price) = 1e18 and the
        /// expected value is exactly `get_virtual_price()` at the pinned block, confirmed by
        /// `cast call 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85 "get_virtual_price()(uint256)"
        /// --rpc-url $ETHEREUM_PROVIDER_URL --block 22894761` -> 1008868820212044711.
        assertEq(price.toUint256(), 1008868820212044711, "price should equal get_virtual_price() (both coins at $1)");
    }

    // Constructor tests
    function testShouldDeploySuccessfullyWithValidParameters() external {
        // given
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;
        address priceOracleMiddleware = PRICE_ORACLE_MIDDLEWARE;

        // when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);

        // then
        assertEq(priceFeed.CURVE_STABLE_SWAP_NG(), curvePool, "CURVE_STABLE_SWAP_NG should be set correctly");
        assertEq(
            priceFeed.PRICE_ORACLE_MIDDLEWARE(),
            priceOracleMiddleware,
            "PRICE_ORACLE_MIDDLEWARE should be set correctly"
        );
        assertEq(priceFeed.N_COINS(), 2, "N_COINS should be 2 for this pool");
        assertEq(priceFeed.DECIMALS_LP(), 18, "DECIMALS_LP should be 18");
        assertEq(priceFeed.coins(0), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "First coin should be USDC");
        assertEq(priceFeed.coins(1), 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2, "Second coin should be USDF");
    }

    function testShouldRevertWhenCurveStableSwapNGIsZeroAddress() external {
        // given
        address curvePool = address(0);
        address priceOracleMiddleware = PRICE_ORACLE_MIDDLEWARE;

        // when & then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);
    }

    function testShouldRevertWhenPriceOracleMiddlewareIsZeroAddress() external {
        // given
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;
        address priceOracleMiddleware = address(0);

        // when & then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);
    }

    function testShouldRevertWhenBothParametersAreZeroAddress() external {
        // given
        address curvePool = address(0);
        address priceOracleMiddleware = address(0);

        // when & then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);
    }

    function testShouldInitializeCoinsArrayCorrectly() external {
        // given
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;
        address priceOracleMiddleware = PRICE_ORACLE_MIDDLEWARE;

        // when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);

        // then
        assertEq(priceFeed.coins(0), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "First coin should be USDC");
        assertEq(priceFeed.coins(1), 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2, "Second coin should be USDF");
    }

    function testShouldSetImmutableVariablesCorrectly() external {
        // given
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;
        address priceOracleMiddleware = PRICE_ORACLE_MIDDLEWARE;

        // when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);

        // then
        assertEq(priceFeed.CURVE_STABLE_SWAP_NG(), curvePool, "CURVE_STABLE_SWAP_NG immutable should be set");
        assertEq(
            priceFeed.PRICE_ORACLE_MIDDLEWARE(),
            priceOracleMiddleware,
            "PRICE_ORACLE_MIDDLEWARE immutable should be set"
        );
        assertEq(priceFeed.N_COINS(), 2, "N_COINS immutable should be set to 2");
        assertEq(priceFeed.DECIMALS_LP(), 18, "DECIMALS_LP immutable should be set to 18");
    }

    /// IL-7950 cycle-2 REGRESSION TEST (sibling of CurveChildLiquidityGaugeBalanceFuse)
    /// CurveStableSwapNGPriceFeed valued the same StableSwap-NG LP token as
    /// CurveChildLiquidityGaugeBalanceFuse (oracle-priced pro-rata of the pool's coin balances, pre
    /// cycle-2), so it carried the identical residual: cycle-1-verification.md's finding that
    /// pro-rata is manipulable by a same-transaction round-trip swap (swaps conserve `D`, so the
    /// outbound leg's slippage is refunded on the return leg) applies here too. Fixed with the same
    /// `get_virtual_price()`-based formula in the same change. Unlike the gauge/single-side fuse
    /// tests, this price feed is stateless (no cache to refresh) - the manipulated read is simply
    /// the next `latestRoundData()` call after the swap.
    function testShouldNotInflatePriceWhenPoolPushedLongOneCoinByRoundTripSwap() external {
        // given
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address usdf = 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2;
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;

        address[] memory assets = new address[](2);
        assets[0] = usdc;
        assets[1] = usdf;
        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = oneDollarPriceFeed;
        priceFeeds[1] = oneDollarPriceFeed;
        vm.startPrank(PRICE_ORACLE_OWNER);
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, PRICE_ORACLE_MIDDLEWARE);
        (, int256 priceBefore, , , ) = priceFeed.latestRoundData();

        // when - attacker pushes the (very deep, ~$5.5M/$9.7M) pool long USDF via a large USDC
        // round-trip swap.
        // NOTE on magnitude: this pool is far deeper (~$5.5M USDC / ~$9.7M USDF at the pinned
        // block) and has a higher effective suppression at moderate imbalance than the gauge
        // fuse's USDM/USDC fixture, so a much larger swap (relative to the smaller side's reserve)
        // is needed to demonstrate separation. Measured on this exact fixture: the deleted spot
        // pro-rata formula moves +14.9% for this swap; the fixed get_virtual_price()-based formula
        // moves only +1.42% (both measured independently via console logging during test authoring,
        // confirmed by the re-injection proof in cycle-2-implementation.md).
        address attacker = address(0x9997);
        uint256 usdcAmount = 12_000_000 * 10 ** ERC20(usdc).decimals();
        deal(usdc, attacker, usdcAmount);
        vm.startPrank(attacker);
        ERC20(usdc).approve(curvePool, usdcAmount);
        ICurveStableswapNGExchange(curvePool).exchange(0, 1, usdcAmount, 0);
        vm.stopPrank();

        (, int256 priceAfter, , , ) = priceFeed.latestRoundData();

        // then - the fixed (get_virtual_price()-based) price stays within 5% of the pre-swap price;
        // swaps conserve `D`, so the residual move is bounded by the fee.
        assertApproxEqRel(
            uint256(priceAfter),
            uint256(priceBefore),
            0.05e18, // 5%
            "fixed (cycle-2) price should stay within 5% of the pre-swap price despite the push"
        );
    }

    // ============================================================
    // IL-7950 follow-up: rate-bearing coins must be priced in BASE units
    // ============================================================

    /// @notice `get_virtual_price()` is `D / totalSupply`, and `D` is built from
    ///         `balances[j] * stored_rates()[j] / 1e18`. For a coin with an external rate
    ///         (`asset_type` 1 or 3) that multiplier carries the rate, so `D` is denominated in the
    ///         coin's BASE asset - multiplying it by the coin's own USD price over-values the LP by
    ///         that rate. This pins the conversion end to end against a real rate-bearing pool.
    ///
    ///         Pool: sUSD/sUSDe on Ethereum. At the pinned block
    ///         `stored_rates() == [1e18, 1181045021292653918]` and
    ///         `get_virtual_price() == 1002790356400854289` (verified with `cast call ... --block
    ///         22894761`). sUSD is priced high on purpose so the minimum lands on the rate-bearing
    ///         coin: on the untouched pool the minimum falls on sUSD (rate 1), which is exactly why
    ///         the defect was latent rather than live.
    function testShouldPriceRateBearingCurvePoolInBaseUnits() external {
        //given
        address sUsd = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
        address sUsde = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
        address curvePool = 0x4b5E827F4C0a1042272a11857a355dA1F4Ceebae;

        uint256 sUsdeStoredRate = 1181045021292653918;

        vm.mockCall(
            PRICE_ORACLE_MIDDLEWARE,
            abi.encodeWithSignature("getAssetPrice(address)", sUsd),
            abi.encode(uint256(2e18), uint256(18))
        );
        /// @dev sUSDe priced at exactly its redemption value, so one USDe of base is worth $1.
        vm.mockCall(
            PRICE_ORACLE_MIDDLEWARE,
            abi.encodeWithSignature("getAssetPrice(address)", sUsde),
            abi.encode(sUsdeStoredRate, uint256(18))
        );

        //when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, PRICE_ORACLE_MIDDLEWARE);
        (, int256 price, , , ) = priceFeed.latestRoundData();

        //then - base prices are $2 (sUSD) and $1 (sUSDe), so the minimum is $1 and the LP is worth
        // exactly `get_virtual_price()`.
        assertEq(price.toUint256(), 1002790356400854289, "LP must be valued at vp x min base price");

        /// @dev The pre-fix formula compared the RAW prices, so its minimum was sUSDe's $1.181 and
        /// the LP came out 18.1045% too high. Pinned here so the size of the correction is part of
        /// the record and a regression cannot pass unnoticed.
        uint256 preFixPrice = (1002790356400854289 * sUsdeStoredRate) / 1e18;
        assertEq(preFixPrice, 1184340557827514964, "pre-fix reference value");
        assertGt(preFixPrice, price.toUint256(), "the old formula over-valued this LP");
    }
}

/// @notice Minimal Curve StableswapNG swap interface, used only by the IL-7950 round-trip
/// regression test above to drive a swap against the pool. Not part of the fuses' production
/// interface and intentionally kept local to this test file.
interface ICurveStableswapNGExchange {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}
