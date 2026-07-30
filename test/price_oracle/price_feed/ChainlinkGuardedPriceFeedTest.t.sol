// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ChainlinkGuardedPriceFeed} from "../../../contracts/price_oracle/price_feed/ChainlinkGuardedPriceFeed.sol";
import {AggregatorV3Interface} from "../../../contracts/price_oracle/ext/AggregatorV3Interface.sol";

contract ChainlinkGuardedPriceFeedTest is Test {
    address public constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint32 public constant MAX_STALE = 1 days + 1 hours;
    uint256 public constant MAX_DEV = 5e16; // 5%
    uint256 public constant ROUNDS = 5;
    uint256 public constant MIN_ROUNDS = 1;

    /// @dev Synthetic phase far above the real one so no mocked round id can
    /// collide with real aggregator data forwarded by the fork.
    uint80 public constant SYNTH_PHASE = uint80(99) << 64;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22773442);
    }

    function _deploy() internal returns (ChainlinkGuardedPriceFeed) {
        return new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);
    }

    // ------------------------------------------------------------------
    // constructor
    // ------------------------------------------------------------------

    function test_constructor_StoresImmutables_AndCachesDecimals() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        assertEq(feed.AGGREGATOR(), CHAINLINK_ETH_USD, "AGGREGATOR mismatch");
        assertEq(feed.MAX_STALE_PERIOD(), MAX_STALE, "MAX_STALE_PERIOD mismatch");
        assertEq(feed.MAX_DEVIATION(), MAX_DEV, "MAX_DEVIATION mismatch");
        assertEq(feed.ROUNDS_TO_CHECK(), ROUNDS, "ROUNDS_TO_CHECK mismatch");
        assertEq(feed.MIN_VALID_ROUNDS(), MIN_ROUNDS, "MIN_VALID_ROUNDS mismatch");
        assertEq(feed.PRICE_FEED_DECIMALS(), 8, "decimals should be cached from ETH/USD aggregator");
        assertEq(feed.decimals(), 8, "decimals() should return cached value");
    }

    function test_constructor_RevertsOnZeroAggregator() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.ZeroAddress.selector);
        new ChainlinkGuardedPriceFeed(address(0), MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);
    }

    function test_constructor_RevertsOnZeroStalePeriod() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.ZeroStalePeriod.selector);
        new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, 0, MAX_DEV, ROUNDS, MIN_ROUNDS);
    }

    function test_constructor_RevertsOnMaxStalePeriodTooLong() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.MaxStalePeriodTooLong.selector);
        new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, uint32(7 days) + 1, MAX_DEV, ROUNDS, MIN_ROUNDS);
    }

    function test_constructor_AcceptsMaxStalePeriodAtLimit() public {
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(
            CHAINLINK_ETH_USD,
            uint32(7 days),
            MAX_DEV,
            ROUNDS,
            MIN_ROUNDS
        );
        assertEq(feed.MAX_STALE_PERIOD(), 7 days, "should accept 7 days exactly");
    }

    function test_constructor_RevertsOnZeroMaxDeviation() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.ZeroMaxDeviation.selector);
        new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, 0, ROUNDS, MIN_ROUNDS);
    }

    function test_constructor_RevertsOnMaxDeviationAboveWad() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.MaxDeviationTooHigh.selector);
        new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, 1e18 + 1, ROUNDS, MIN_ROUNDS);
    }

    function test_constructor_AcceptsMaxDeviationAtWad() public {
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, 1e18, ROUNDS, MIN_ROUNDS);
        assertEq(feed.MAX_DEVIATION(), 1e18, "should accept 1e18 exactly");
    }

    function test_constructor_RevertsOnZeroRounds() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidRoundsToCheck.selector);
        new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, 0, MIN_ROUNDS);
    }

    function test_constructor_RevertsOnRoundsAboveLimit() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidRoundsToCheck.selector);
        new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, 11, MIN_ROUNDS);
    }

    function test_constructor_AcceptsRoundsBounds() public {
        assertEq(
            new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, 1, MIN_ROUNDS).ROUNDS_TO_CHECK(),
            1,
            "should accept 1 round"
        );
        assertEq(
            new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, 10, MIN_ROUNDS).ROUNDS_TO_CHECK(),
            10,
            "should accept 10 rounds"
        );
    }

    function test_constructor_RevertsOnZeroMinValidRounds() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidMinValidRounds.selector);
        new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, 0);
    }

    function test_constructor_RevertsWhenMinValidRoundsAboveRoundsToCheck() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidMinValidRounds.selector);
        new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, ROUNDS + 1);
    }

    function test_constructor_AcceptsMinValidRoundsEqualToRoundsToCheck() public {
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(
            CHAINLINK_ETH_USD,
            MAX_STALE,
            MAX_DEV,
            ROUNDS,
            ROUNDS
        );
        assertEq(feed.MIN_VALID_ROUNDS(), ROUNDS, "should accept the full window as the minimum");
    }

    // ------------------------------------------------------------------
    // latestRoundData - happy paths on real fork data
    // ------------------------------------------------------------------

    function test_latestRoundData_RealAggregator_HappyPath() public {
        (
            uint80 realRoundId,
            int256 realAnswer,
            uint256 realStartedAt,
            uint256 realUpdatedAt,
            uint80 realAnsweredInRound
        ) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        require(realAnswer > 0 && realUpdatedAt > 0, "pinned block produced empty Chainlink reading");
        vm.warp(realUpdatedAt + 1);

        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, 5e17, ROUNDS, MIN_ROUNDS);

        (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = feed
            .latestRoundData();

        assertEq(roundId, realRoundId, "roundId passthrough mismatch");
        assertEq(price, realAnswer, "price passthrough mismatch");
        assertEq(startedAt, realStartedAt, "startedAt passthrough mismatch");
        assertEq(time, realUpdatedAt, "time passthrough mismatch");
        assertEq(answeredInRound, realAnsweredInRound, "answeredInRound passthrough mismatch");
    }

    function test_latestRoundData_RoundsToCheck1_And10_RealData() public {
        (, , , uint256 realUpdatedAt, ) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
        vm.warp(realUpdatedAt + 1);

        ChainlinkGuardedPriceFeed feed1 = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, 5e17, 1, MIN_ROUNDS);
        (, int256 price1, , , ) = feed1.latestRoundData();
        assertGt(price1, 0, "rounds=1 should return positive price");

        ChainlinkGuardedPriceFeed feed10 = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, 5e17, 10, MIN_ROUNDS);
        (, int256 price10, , , ) = feed10.latestRoundData();
        assertGt(price10, 0, "rounds=10 should return positive price");
    }

    // ------------------------------------------------------------------
    // latestRoundData - guard reverts (mocked, hit before deviation check)
    // ------------------------------------------------------------------

    function test_latestRoundData_RevertsWhenAnswerZero() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        _mockLatest(SYNTH_PHASE | 20, 0, block.timestamp);
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidPrice.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_RevertsWhenAnswerNegative() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        _mockLatest(SYNTH_PHASE | 20, -1, block.timestamp);
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidPrice.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_RevertsWhenUpdatedAtZero() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        _mockLatest(SYNTH_PHASE | 20, 1000e8, 0);
        vm.expectRevert(ChainlinkGuardedPriceFeed.StalePrice.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_RevertsWhenStale() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        _mockLatest(SYNTH_PHASE | 20, 1000e8, block.timestamp - uint256(MAX_STALE) - 1);
        vm.expectRevert(ChainlinkGuardedPriceFeed.StalePrice.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_DoesNotRevertAtStalenessBoundary() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        uint80 latestRoundId = SYNTH_PHASE | 20;
        uint256 boundaryTs = block.timestamp - uint256(MAX_STALE);
        _mockLatest(latestRoundId, 1000e8, boundaryTs);
        _mockPreviousRounds(latestRoundId, ROUNDS, 1000e8, boundaryTs);

        (, int256 price, , uint256 time, ) = feed.latestRoundData();

        assertEq(price, 1000e8, "price at boundary mismatch");
        assertEq(time, boundaryTs, "time at boundary mismatch");
    }

    function test_latestRoundData_RevertsOnFuturePrice() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        _mockLatest(SYNTH_PHASE | 20, 1000e8, block.timestamp + 1);
        vm.expectRevert(ChainlinkGuardedPriceFeed.FuturePrice.selector);
        feed.latestRoundData();
    }

    // ------------------------------------------------------------------
    // deviation check (synthetic round ids, all consulted rounds mocked)
    // ------------------------------------------------------------------

    function test_latestRoundData_RevertsWhenDeviationAboveMax() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        uint80 latestRoundId = SYNTH_PHASE | 20;
        // previous mean = 1000e8, latest = 1051e8 -> deviation 5.1% > 5%
        _mockLatest(latestRoundId, 1051e8, block.timestamp);
        _mockPreviousRounds(latestRoundId, ROUNDS, 1000e8, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.DeviationTooHigh.selector, 51e15, MAX_DEV));
        feed.latestRoundData();
    }

    function test_latestRoundData_PassesAtExactMaxDeviation() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        uint80 latestRoundId = SYNTH_PHASE | 20;
        // previous mean = 1000e8, latest = 1050e8 -> deviation exactly 5% (`>` not `>=`)
        _mockLatest(latestRoundId, 1050e8, block.timestamp);
        _mockPreviousRounds(latestRoundId, ROUNDS, 1000e8, block.timestamp);

        (, int256 price, , , ) = feed.latestRoundData();

        assertEq(price, 1050e8, "price at exact max deviation should pass");
    }

    /// @dev `getRoundData(latestRoundId)` is mocked explicitly here (a real Chainlink
    /// proxy answers it), so the window walk must skip it rather than rely on a revert.
    function test_latestRoundData_MeanExcludesLatestRound() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        uint80 latestRoundId = SYNTH_PHASE | 20;
        // If the latest round were included in the mean, the mean would be
        // (1051 + 5 * 1000) / 6 = 1008.5e8 and the deviation ~4.2% -> pass.
        // With the latest excluded the mean is 1000e8 and the deviation 5.1% -> revert.
        _mockLatest(latestRoundId, 1051e8, block.timestamp);
        _mockRound(latestRoundId, 1051e8, block.timestamp);
        _mockPreviousRounds(latestRoundId, ROUNDS, 1000e8, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.DeviationTooHigh.selector, 51e15, MAX_DEV));
        feed.latestRoundData();
    }

    /// @dev Extreme variant of the above: a manipulated latest answer must not be able
    /// to drag its own reference mean toward itself.
    function test_latestRoundData_ExtremeLatestRoundDoesNotEnterOwnMean() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        uint80 latestRoundId = SYNTH_PHASE | 20;
        // mean over the 5 previous rounds = 1000e8; a 10_000e8 latest answer deviates
        // by 900%. If it entered its own mean the mean would be 2500e8 and the
        // reported deviation 300% - the exact error argument pins this down.
        _mockLatest(latestRoundId, 10_000e8, block.timestamp);
        _mockRound(latestRoundId, 10_000e8, block.timestamp);
        _mockPreviousRounds(latestRoundId, ROUNDS, 1000e8, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.DeviationTooHigh.selector, 9e18, MAX_DEV));
        feed.latestRoundData();
    }

    /// @dev The window must span exactly `ROUNDS_TO_CHECK` *previous* rounds. Four of
    /// them are usable and the latest round is answerable by `getRoundData` - if the
    /// latest were counted the window would look full and the read would pass.
    function test_latestRoundData_LatestRoundDoesNotFillTheWindow() public {
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(
            CHAINLINK_ETH_USD,
            MAX_STALE,
            MAX_DEV,
            ROUNDS,
            ROUNDS
        );
        uint80 latestRoundId = SYNTH_PHASE | 20;
        _mockLatest(latestRoundId, 1000e8, block.timestamp);
        _mockRound(latestRoundId, 1000e8, block.timestamp);
        _mockPreviousRounds(latestRoundId, ROUNDS, 1000e8, block.timestamp);
        _mockRound(latestRoundId - uint80(ROUNDS), 0, block.timestamp); // oldest one unusable

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, ROUNDS - 1, ROUNDS)
        );
        feed.latestRoundData();
    }

    function test_latestRoundData_FullWindowSatisfied() public {
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(
            CHAINLINK_ETH_USD,
            MAX_STALE,
            MAX_DEV,
            ROUNDS,
            ROUNDS
        );
        uint80 latestRoundId = SYNTH_PHASE | 20;
        _mockLatest(latestRoundId, 1000e8, block.timestamp);
        _mockPreviousRounds(latestRoundId, ROUNDS, 1000e8, block.timestamp);

        (, int256 price, , , ) = feed.latestRoundData();
        assertEq(price, 1000e8, "full window of usable previous rounds should pass");
    }

    function test_latestRoundData_SkipsInvalidRounds_InWindow() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        uint80 latestRoundId = SYNTH_PHASE | 20;
        _mockLatest(latestRoundId, 2000e8, block.timestamp);
        _mockRound(latestRoundId - 1, 1000e8, block.timestamp); // valid
        _mockRound(latestRoundId - 2, 0, block.timestamp); // invalid: zero answer
        _mockRoundRevert(latestRoundId - 3); // unavailable
        _mockRound(latestRoundId - 4, 1500e8, 0); // invalid: zero updatedAt
        _mockRound(latestRoundId - 5, 3000e8, block.timestamp); // valid

        // mean over valid rounds only = (1000 + 3000) / 2 = 2000e8 -> deviation 0 -> pass
        (, int256 price, , , ) = feed.latestRoundData();
        assertEq(price, 2000e8, "mean should be computed from valid rounds only");

        // and 2101e8 vs the same mean -> 5.05% -> revert, proving the mean is 2000e8
        _mockLatest(latestRoundId, 2101e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.DeviationTooHigh.selector, 505e14, MAX_DEV));
        feed.latestRoundData();
    }

    // ------------------------------------------------------------------
    // phase boundary / window shrink
    // ------------------------------------------------------------------

    function test_latestRoundData_PhaseBoundary_ShrinksWindow() public {
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, 10, MIN_ROUNDS);
        uint80 latestRoundId = SYNTH_PHASE | 3;
        // only aggregator rounds 2 and 1 exist before the latest; the loop must
        // not walk below round 1 (previous phase). Only these two are mocked -
        // any call outside them would hit the real aggregator and revert.
        _mockLatest(latestRoundId, 1500e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 2, 1000e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 1, 2000e8, block.timestamp);

        // mean = (1000 + 2000) / 2 = 1500e8 -> deviation 0 -> pass
        (, int256 price, , , ) = feed.latestRoundData();
        assertEq(price, 1500e8, "window should shrink to the two available rounds");
    }

    function test_latestRoundData_RevertsWhenNoPreviousRounds() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        // first round of a phase - zero previous rounds in this phase. The latest round
        // itself is answerable, and must not stand in for the missing history.
        _mockLatest(SYNTH_PHASE | 1, 1000e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 1, 1000e8, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, 0, MIN_ROUNDS)
        );
        feed.latestRoundData();
    }

    function test_latestRoundData_RevertsWhenAllPreviousRoundsUnavailable() public {
        ChainlinkGuardedPriceFeed feed = _deploy();
        uint80 latestRoundId = SYNTH_PHASE | 5;
        _mockLatest(latestRoundId, 1000e8, block.timestamp);
        for (uint80 i = 1; i < 5; ++i) {
            _mockRoundRevert(latestRoundId - i);
        }
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, 0, MIN_ROUNDS)
        );
        feed.latestRoundData();
    }

    // ------------------------------------------------------------------
    // MIN_VALID_ROUNDS - fail closed on a degraded window
    // ------------------------------------------------------------------

    function test_latestRoundData_RevertsWhenUsableRoundsBelowMinimum() public {
        // window of 5, at least 3 of them must be usable
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, 3);
        uint80 latestRoundId = SYNTH_PHASE | 20;
        _mockLatest(latestRoundId, 1000e8, block.timestamp);
        _mockRound(latestRoundId - 1, 1000e8, block.timestamp); // valid
        _mockRound(latestRoundId - 2, 1000e8, block.timestamp); // valid
        _mockRoundRevert(latestRoundId - 3);
        _mockRound(latestRoundId - 4, 0, block.timestamp); // invalid: zero answer
        _mockRound(latestRoundId - 5, 1000e8, 0); // invalid: zero updatedAt

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, 2, 3));
        feed.latestRoundData();
    }

    function test_latestRoundData_PassesWhenUsableRoundsAtMinimum() public {
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, 3);
        uint80 latestRoundId = SYNTH_PHASE | 20;
        _mockLatest(latestRoundId, 1000e8, block.timestamp);
        _mockRound(latestRoundId - 1, 1000e8, block.timestamp); // valid
        _mockRound(latestRoundId - 2, 1000e8, block.timestamp); // valid
        _mockRound(latestRoundId - 3, 1000e8, block.timestamp); // valid
        _mockRound(latestRoundId - 4, 0, block.timestamp); // invalid
        _mockRoundRevert(latestRoundId - 5);

        (, int256 price, , , ) = feed.latestRoundData();
        assertEq(price, 1000e8, "exactly MIN_VALID_ROUNDS usable rounds should pass");
    }

    /// @dev A short phase-start window is only accepted when it still reaches
    /// `MIN_VALID_ROUNDS`; a stricter minimum fails the read closed.
    function test_latestRoundData_PhaseStart_FailsClosedUnderStrictMinimum() public {
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, 3);
        uint80 latestRoundId = SYNTH_PHASE | 3;
        _mockLatest(latestRoundId, 1500e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 3, 1500e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 2, 1000e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 1, 2000e8, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, 2, 3));
        feed.latestRoundData();
    }

    // ------------------------------------------------------------------
    // deployment round as the oldest round in scope
    // ------------------------------------------------------------------

    function test_constructor_AnchorsWindowAtDeploymentRound() public {
        (uint80 realRoundId, , , , ) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();

        ChainlinkGuardedPriceFeed feed = _deploy();

        assertEq(feed.INITIAL_ROUND_ID(), realRoundId, "INITIAL_ROUND_ID should be the round current at deployment");
        assertEq(feed.INITIAL_PHASE_ID(), uint16(realRoundId >> 64), "phase should be split out of the round id");
        assertEq(
            feed.INITIAL_AGGREGATOR_ROUND_ID(),
            uint64(realRoundId),
            "in-phase round id should be split out of the round id"
        );
    }

    function test_constructor_RevertsWhenAggregatorHasNoUsableAnswer() public {
        _mockLatest(SYNTH_PHASE | 20, 0, block.timestamp);
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidPrice.selector);
        _deploy();

        _mockLatest(SYNTH_PHASE | 20, 1000e8, 0);
        vm.expectRevert(ChainlinkGuardedPriceFeed.StalePrice.selector);
        _deploy();
    }

    /// @dev A feed deployed against a brand new aggregator whose deployment round is its
    /// only round must serve that answer: the deployer read it and accepted it.
    function test_latestRoundData_DeploymentRoundIsServedWithoutAnyHistory() public {
        uint80 latestRoundId = SYNTH_PHASE | 1;
        _mockLatest(latestRoundId, 1000e8, block.timestamp);
        // no getRoundData mocks at all - the window must not be consulted
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(
            CHAINLINK_ETH_USD,
            MAX_STALE,
            MAX_DEV,
            ROUNDS,
            ROUNDS
        );

        (uint80 roundId, int256 price, , , ) = feed.latestRoundData();

        assertEq(roundId, latestRoundId, "deployment round should pass through");
        assertEq(price, 1000e8, "deployment round should be served with an empty window");
    }

    /// @dev The deployment round is exempt only from the window requirement - the
    /// staleness guard still applies to it.
    function test_latestRoundData_DeploymentRoundStillSubjectToStaleness() public {
        uint80 latestRoundId = SYNTH_PHASE | 1;
        _mockLatest(latestRoundId, 1000e8, block.timestamp);
        ChainlinkGuardedPriceFeed feed = _deploy();

        vm.warp(block.timestamp + uint256(MAX_STALE) + 1);
        vm.expectRevert(ChainlinkGuardedPriceFeed.StalePrice.selector);
        feed.latestRoundData();
    }

    /// @dev Warm-up: `MIN_VALID_ROUNDS` is capped by the rounds that exist above the
    /// deployment round, so the feed keeps working from the first new round onwards.
    function test_latestRoundData_WarmUp_MinValidRoundsCappedByReachableWindow() public {
        _mockLatest(SYNTH_PHASE | 10, 1000e8, block.timestamp);
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(
            CHAINLINK_ETH_USD,
            MAX_STALE,
            MAX_DEV,
            ROUNDS,
            ROUNDS
        );

        // one new round on top of the deployment round: window can only hold round 10
        _mockLatest(SYNTH_PHASE | 11, 1020e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 10, 1000e8, block.timestamp);

        (, int256 price, , , ) = feed.latestRoundData();
        assertEq(price, 1020e8, "a single reachable round should satisfy the capped minimum");

        // the check itself is not skipped - 1060e8 vs a mean of 1000e8 is 6% > 5%
        _mockLatest(SYNTH_PHASE | 11, 1060e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.DeviationTooHigh.selector, 6e16, MAX_DEV));
        feed.latestRoundData();
    }

    /// @dev Even during warm-up the capped minimum must be met: the only reachable round
    /// is unusable here, so the read fails closed.
    function test_latestRoundData_WarmUp_FailsClosedWhenReachableRoundUnusable() public {
        _mockLatest(SYNTH_PHASE | 10, 1000e8, block.timestamp);
        ChainlinkGuardedPriceFeed feed = _deploy();

        _mockLatest(SYNTH_PHASE | 11, 1000e8, block.timestamp);
        _mockRoundRevert(SYNTH_PHASE | 10);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, 0, 1));
        feed.latestRoundData();
    }

    /// @dev Rounds older than the deployment round are out of scope even when they exist
    /// and would otherwise fill the window.
    function test_latestRoundData_WindowNeverReachesBelowDeploymentRound() public {
        _mockLatest(SYNTH_PHASE | 10, 1000e8, block.timestamp);
        ChainlinkGuardedPriceFeed feed = _deploy();

        _mockLatest(SYNTH_PHASE | 11, 1000e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 10, 1000e8, block.timestamp);
        // pre-deployment history that would drag the mean down to 600e8 over 5 rounds
        for (uint80 i = 6; i < 10; ++i) {
            _mockRound(SYNTH_PHASE | i, 100e8, block.timestamp);
        }

        // mean must be 1000e8 (round 10 only) -> deviation 0 -> pass
        (, int256 price, , , ) = feed.latestRoundData();
        assertEq(price, 1000e8, "pre-deployment rounds must not enter the mean");
    }

    /// @dev Once `MIN_VALID_ROUNDS` rounds exist above the deployment round the cap is
    /// gone and a degraded window fails closed again.
    function test_latestRoundData_AfterWarmUp_MinValidRoundsEnforcedInFull() public {
        _mockLatest(SYNTH_PHASE | 10, 1000e8, block.timestamp);
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, 3);

        // rounds 10..13 exist (4 reachable, cap no longer binds), but only 2 are usable
        _mockLatest(SYNTH_PHASE | 14, 1000e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 13, 1000e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 12, 1000e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 11, 0, block.timestamp);
        _mockRoundRevert(SYNTH_PHASE | 10);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, 2, 3));
        feed.latestRoundData();
    }

    /// @dev A new aggregator phase gets no warm-up relaxation: nobody signed off on its
    /// first answers, so the full `MIN_VALID_ROUNDS` is required from round 1.
    function test_latestRoundData_NewPhase_NoWarmUpRelaxation() public {
        _mockLatest(SYNTH_PHASE | 10, 1000e8, block.timestamp);
        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, 3);

        uint80 nextPhase = uint80(100) << 64;
        _mockLatest(nextPhase | 2, 1000e8, block.timestamp);
        _mockRound(nextPhase | 1, 1000e8, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, 1, 3));
        feed.latestRoundData();
    }

    /// @dev An aggregator reporting a round id at or below the deployment round within the
    /// deployment phase is anomalous - it must fail closed, not skip the check.
    function test_latestRoundData_FailsClosedWhenRoundIdGoesBackwards() public {
        _mockLatest(SYNTH_PHASE | 10, 1000e8, block.timestamp);
        ChainlinkGuardedPriceFeed feed = _deploy();

        _mockLatest(SYNTH_PHASE | 9, 1000e8, block.timestamp);
        _mockRound(SYNTH_PHASE | 8, 1000e8, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkGuardedPriceFeed.InsufficientValidRounds.selector, 0, 1));
        feed.latestRoundData();
    }

    /// @dev Real fork data: the deviation check runs against the aggregator's genuine
    /// history once a round is published above the deployment round.
    function test_latestRoundData_RealHistory_UsedAfterDeploymentRound() public {
        (uint80 realRoundId, int256 realAnswer, , uint256 realUpdatedAt, ) = AggregatorV3Interface(CHAINLINK_ETH_USD)
            .latestRoundData();
        vm.warp(realUpdatedAt + 1);

        ChainlinkGuardedPriceFeed feed = new ChainlinkGuardedPriceFeed(
            CHAINLINK_ETH_USD,
            MAX_STALE,
            5e17,
            ROUNDS,
            MIN_ROUNDS
        );

        // a new round in the same phase, one above the deployment round: the window is
        // capped to the deployment round itself, whose data comes from the real aggregator
        _mockLatest(realRoundId + 1, realAnswer, block.timestamp);

        (, int256 price, , , ) = feed.latestRoundData();
        assertEq(price, realAnswer, "real deployment round should serve as the reference");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _mockLatest(uint80 roundId, int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            CHAINLINK_ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, updatedAt, updatedAt, roundId)
        );
    }

    function _mockRound(uint80 roundId, int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            CHAINLINK_ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.getRoundData.selector, roundId),
            abi.encode(roundId, answer, updatedAt, updatedAt, roundId)
        );
    }

    function _mockRoundRevert(uint80 roundId) internal {
        vm.mockCallRevert(
            CHAINLINK_ETH_USD,
            abi.encodeWithSelector(AggregatorV3Interface.getRoundData.selector, roundId),
            "No data present"
        );
    }

    function _mockPreviousRounds(uint80 latestRoundId, uint256 count, int256 answer, uint256 updatedAt) internal {
        for (uint256 i = 1; i <= count; ++i) {
            _mockRound(latestRoundId - uint80(i), answer, updatedAt);
        }
    }
}
