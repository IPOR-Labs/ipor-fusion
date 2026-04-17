// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DIAPriceFeed} from "../../../contracts/price_oracle/price_feed/DIAPriceFeed.sol";
import {IDIAOracleV2} from "../../../contracts/price_oracle/ext/IDIAOracleV2.sol";

contract DIAPriceFeedTest is Test {
    address public constant DIA_ORACLE = 0xafA00E7Eff2EA6D216E432d99807c159d08C2b79;
    string public constant KEY = "OUSD/USD";
    uint32 public constant MAX_STALE = 1 days + 1 hours;
    uint8 public constant DIA_DEC_8 = 8;
    uint8 public constant DEC_18 = 18;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22773442);
    }

    function _deploy(uint8 diaDecimals, uint8 priceFeedDecimals) internal returns (DIAPriceFeed) {
        return new DIAPriceFeed(DIA_ORACLE, KEY, MAX_STALE, diaDecimals, priceFeedDecimals);
    }

    function test_decimals_ReturnsConfiguredValue_18() public {
        assertEq(_deploy(DIA_DEC_8, 18).decimals(), 18, "decimals should be 18");
    }

    function test_decimals_ReturnsConfiguredValue_8() public {
        assertEq(_deploy(DIA_DEC_8, 8).decimals(), 8, "decimals should be 8");
    }

    function test_decimals_ReturnsConfiguredValue_27() public {
        assertEq(_deploy(DIA_DEC_8, 27).decimals(), 27, "decimals should be 27");
    }

    function test_constructor_StoresImmutables() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, DEC_18);
        assertEq(feed.DIA_ORACLE(), DIA_ORACLE, "DIA_ORACLE mismatch");
        assertEq(feed.KEY(), KEY, "KEY mismatch");
        assertEq(feed.MAX_STALE_PERIOD(), MAX_STALE, "MAX_STALE_PERIOD mismatch");
        assertEq(feed.DIA_DECIMALS(), DIA_DEC_8, "DIA_DECIMALS mismatch");
        assertEq(feed.PRICE_FEED_DECIMALS(), DEC_18, "PRICE_FEED_DECIMALS mismatch");
        assertEq(feed.SCALE(), 1e10, "SCALE mismatch");
    }

    function test_constructor_Scale_IsOneWhenDecimalsEqual() public {
        assertEq(_deploy(DIA_DEC_8, 8).SCALE(), 1, "SCALE should be 1 when decimals equal");
        assertEq(_deploy(5, 5).SCALE(), 1, "SCALE should be 1 for DIA_DECIMALS=5 feed decimals=5");
    }

    function test_constructor_Scale_ComputedFromDecimals_27() public {
        assertEq(_deploy(DIA_DEC_8, 27).SCALE(), 10 ** 19, "SCALE should be 10**19 for 8 -> 27");
    }

    function test_constructor_Scale_DiaDecimals5_FeedDecimals18() public {
        assertEq(_deploy(5, 18).SCALE(), 10 ** 13, "SCALE should be 10**13 for 5 -> 18");
    }

    function test_constructor_RevertsOnZeroOracle() public {
        vm.expectRevert(DIAPriceFeed.ZeroAddress.selector);
        new DIAPriceFeed(address(0), KEY, MAX_STALE, DIA_DEC_8, DEC_18);
    }

    function test_constructor_RevertsOnEmptyKey() public {
        vm.expectRevert(DIAPriceFeed.EmptyKey.selector);
        new DIAPriceFeed(DIA_ORACLE, "", MAX_STALE, DIA_DEC_8, DEC_18);
    }

    function test_constructor_RevertsOnZeroStalePeriod() public {
        vm.expectRevert(DIAPriceFeed.ZeroStalePeriod.selector);
        new DIAPriceFeed(DIA_ORACLE, KEY, 0, DIA_DEC_8, DEC_18);
    }

    function test_constructor_RevertsOnMaxStalePeriodTooLong() public {
        vm.expectRevert(DIAPriceFeed.MaxStalePeriodTooLong.selector);
        new DIAPriceFeed(DIA_ORACLE, KEY, uint32(7 days) + 1, DIA_DEC_8, DEC_18);
    }

    function test_constructor_AcceptsMaxStalePeriodAtLimit() public {
        DIAPriceFeed feed = new DIAPriceFeed(DIA_ORACLE, KEY, uint32(7 days), DIA_DEC_8, DEC_18);
        assertEq(feed.MAX_STALE_PERIOD(), 7 days, "should accept 7 days exactly");
    }

    function test_constructor_RevertsOnZeroDiaDecimals() public {
        vm.expectRevert(DIAPriceFeed.ZeroDiaDecimals.selector);
        new DIAPriceFeed(DIA_ORACLE, KEY, MAX_STALE, 0, DEC_18);
    }

    function test_constructor_RevertsWhenPriceFeedDecimalsBelowDiaDecimals() public {
        vm.expectRevert(DIAPriceFeed.PriceFeedDecimalsTooLow.selector);
        new DIAPriceFeed(DIA_ORACLE, KEY, MAX_STALE, DIA_DEC_8, 7);
    }

    function test_constructor_RevertsWhenDecimalsDeltaTooLarge() public {
        // delta = 39 > MAX_DECIMALS_DELTA (38)
        vm.expectRevert(DIAPriceFeed.DecimalsDeltaTooLarge.selector);
        new DIAPriceFeed(DIA_ORACLE, KEY, MAX_STALE, 1, 40);
    }

    function test_constructor_AcceptsDecimalsDeltaAtLimit() public {
        DIAPriceFeed feed = new DIAPriceFeed(DIA_ORACLE, KEY, MAX_STALE, 1, 39);
        assertEq(feed.SCALE(), 10 ** 38, "SCALE should be 10**38 at delta limit");
    }

    function test_latestRoundData_OUSD_ReturnsDIAValueScaledTo18() public {
        (uint128 diaValue, uint128 diaTimestamp) = IDIAOracleV2(DIA_ORACLE).getValue(KEY);
        require(diaValue > 0 && diaTimestamp > 0, "pinned block produced empty DIA reading");
        vm.warp(uint256(diaTimestamp) + 1);

        DIAPriceFeed feed = _deploy(DIA_DEC_8, DEC_18);

        (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = feed.latestRoundData();

        assertEq(roundId, 0, "roundId should be 0");
        assertEq(answeredInRound, 0, "answeredInRound should be 0");
        assertEq(price, int256(uint256(diaValue) * 1e10), "price should be DIA value scaled by 1e10");
        assertEq(time, uint256(diaTimestamp), "time should match DIA timestamp");
        assertEq(startedAt, uint256(diaTimestamp), "startedAt should match DIA timestamp");
    }

    function test_latestRoundData_DiaDecimals8_FeedDecimals8_ReturnsRaw() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, 8);
        uint128 value = 1e8;
        uint128 ts = uint128(block.timestamp);
        _mockDIA(value, ts);

        (, int256 price, , , ) = feed.latestRoundData();

        assertEq(price, int256(uint256(value)), "price should equal DIA value (no scaling)");
    }

    function test_latestRoundData_DiaDecimals8_FeedDecimals27_ScalesBy1e19() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, 27);
        uint128 value = 1e8;
        uint128 ts = uint128(block.timestamp);
        _mockDIA(value, ts);

        (, int256 price, , , ) = feed.latestRoundData();

        assertEq(price, int256(uint256(value) * 10 ** 19), "price should equal DIA value scaled by 10**19");
    }

    function test_latestRoundData_DiaDecimals5_FeedDecimals18_ScalesBy1e13() public {
        DIAPriceFeed feed = _deploy(5, 18);
        // DIA value representing $1.00 with 5 decimals = 100000
        uint128 value = 100000;
        uint128 ts = uint128(block.timestamp);
        _mockDIA(value, ts);

        (, int256 price, , , ) = feed.latestRoundData();

        assertEq(price, int256(uint256(value) * 10 ** 13), "price should equal DIA value scaled by 10**13");
        assertEq(price, int256(1e18), "price should equal 1.0 in 18 decimals");
    }

    function test_latestRoundData_RevertsWhenPriceZero() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, DEC_18);
        _mockDIA(uint128(0), uint128(block.timestamp));
        vm.expectRevert(DIAPriceFeed.InvalidPrice.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_RevertsWhenTimestampZero() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, DEC_18);
        _mockDIA(uint128(1e8), uint128(0));
        vm.expectRevert(DIAPriceFeed.StalePrice.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_RevertsWhenStale() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, DEC_18);
        uint256 nowTs = block.timestamp;
        _mockDIA(uint128(1e8), uint128(nowTs - uint256(MAX_STALE) - 1));
        vm.expectRevert(DIAPriceFeed.StalePrice.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_DoesNotRevertAtStalenessBoundary() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, DEC_18);
        uint256 nowTs = block.timestamp;
        uint128 boundaryTs = uint128(nowTs - uint256(MAX_STALE));
        _mockDIA(uint128(1e8), boundaryTs);

        (, int256 price, , uint256 time, ) = feed.latestRoundData();

        assertEq(price, int256(1e8) * 1e10, "price at boundary mismatch");
        assertEq(time, uint256(boundaryTs), "time at boundary mismatch");
    }

    function test_latestRoundData_RevertsWhenTimestampInFuture() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, DEC_18);
        uint128 futureTs = uint128(block.timestamp + 1);
        _mockDIA(uint128(1e8), futureTs);
        vm.expectRevert(DIAPriceFeed.FuturePrice.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_DoesNotRevertWhenTimestampEqualsNow() public {
        DIAPriceFeed feed = _deploy(DIA_DEC_8, DEC_18);
        uint128 nowTs = uint128(block.timestamp);
        _mockDIA(uint128(1e8), nowTs);

        (, int256 price, , uint256 time, ) = feed.latestRoundData();

        assertEq(price, int256(1e8) * 1e10, "price at now mismatch");
        assertEq(time, uint256(nowTs), "time at now mismatch");
    }

    function test_latestRoundData_MaxDiaValueAtMaxDelta_FitsInInt256() public {
        // Sanity check on the `MAX_DECIMALS_DELTA = 38` cap: even with `uint128.max`
        // input the rescaled value still fits in `int256`, so the cap rules out
        // both `uint256` and `SafeCast.toInt256` overflows.
        DIAPriceFeed feed = new DIAPriceFeed(DIA_ORACLE, KEY, MAX_STALE, 1, 39);
        uint128 ts = uint128(block.timestamp);
        _mockDIA(type(uint128).max, ts);

        (, int256 price, , , ) = feed.latestRoundData();

        assertEq(price, int256(uint256(type(uint128).max) * 10 ** 38), "price should equal max DIA value scaled by 10**38");
    }

    function _mockDIA(uint128 value, uint128 timestamp) internal {
        vm.mockCall(
            DIA_ORACLE,
            abi.encodeWithSelector(IDIAOracleV2.getValue.selector, KEY),
            abi.encode(value, timestamp)
        );
    }
}
