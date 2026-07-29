// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title ChainlinkGuardedPriceFeed
/// @notice Wrapper over a Chainlink aggregator that adds two guards on every read:
/// staleness (the answer must be fresher than `MAX_STALE_PERIOD`) and deviation
/// (the latest answer may not differ from the arithmetic mean of the previous
/// `ROUNDS_TO_CHECK` rounds by more than `MAX_DEVIATION`).
/// @dev Passes the aggregator's round data and decimals through unchanged.
/// Note: every read performs up to `ROUNDS_TO_CHECK` additional `getRoundData`
/// calls, so `ROUNDS_TO_CHECK` directly scales read gas.
///
/// Limitation: the reference window is counted in rounds, not in time. Chainlink
/// publishes rounds on heartbeat or deviation threshold, so `ROUNDS_TO_CHECK`
/// rounds cover a short period in volatile markets and a much longer one in quiet
/// markets - the effective protection window varies with feed update frequency.
/// Size `ROUNDS_TO_CHECK` per feed with its heartbeat in mind.
contract ChainlinkGuardedPriceFeed is IPriceFeed {
    /// @notice Hard upper bound on `MAX_STALE_PERIOD`; rules out misconfig
    /// (e.g. `type(uint32).max`) effectively disabling staleness checks.
    uint32 public constant MAX_STALE_PERIOD_LIMIT = 7 days;

    /// @notice Hard upper bound on `ROUNDS_TO_CHECK`.
    uint256 public constant MAX_ROUNDS_TO_CHECK = 10;

    /// @notice Deviation scale: 1e18 == 100%.
    uint256 public constant WAD = 1e18;

    error ZeroAddress();
    error ZeroStalePeriod();
    error MaxStalePeriodTooLong();
    error ZeroMaxDeviation();
    error MaxDeviationTooHigh();
    error InvalidRoundsToCheck();
    error InvalidMinValidRounds();
    error InvalidPrice();
    error StalePrice();
    error FuturePrice();
    error DeviationTooHigh(uint256 deviation, uint256 maxDeviation);
    error InsufficientValidRounds(uint256 validRounds, uint256 minValidRounds);

    /// @notice Emitted once at deployment with the full feed configuration.
    /// @param aggregator Wrapped Chainlink aggregator (proxy) address.
    /// @param maxStalePeriod Maximum allowed answer age, in seconds.
    /// @param maxDeviation Maximum allowed deviation, WAD-scaled (1e18 == 100%).
    /// @param roundsToCheck Number of previous rounds averaged for the deviation check.
    /// @param minValidRounds Minimum number of usable previous rounds required.
    /// @param decimals Aggregator decimals cached by the feed.
    event PriceFeedInitialized(
        address aggregator,
        uint32 maxStalePeriod,
        uint256 maxDeviation,
        uint256 roundsToCheck,
        uint256 minValidRounds,
        uint8 decimals
    );

    /// @notice Chainlink aggregator (proxy) address this feed wraps.
    address public immutable AGGREGATOR;

    /// @notice Maximum allowed age of the latest answer, in seconds.
    uint32 public immutable MAX_STALE_PERIOD;

    /// @notice Maximum allowed relative deviation of the latest answer from the
    /// mean of the previous rounds, WAD-scaled (1e18 == 100%, e.g. 5e16 == 5%).
    uint256 public immutable MAX_DEVIATION;

    /// @notice Number of previous rounds (excluding the latest) averaged for the
    /// deviation check, in [1, `MAX_ROUNDS_TO_CHECK`]. This is the maximum window
    /// size; rounds that revert or carry no valid data are skipped.
    uint256 public immutable ROUNDS_TO_CHECK;

    /// @notice Minimum number of usable previous rounds required for the deviation
    /// check to run, in [1, `ROUNDS_TO_CHECK`]. Fewer usable rounds fail the read
    /// closed instead of silently averaging over a degraded window.
    uint256 public immutable MIN_VALID_ROUNDS;

    /// @notice Decimals of the wrapped aggregator, cached at deployment.
    /// Chainlink aggregator proxies are not expected to change decimals.
    uint8 public immutable PRICE_FEED_DECIMALS;

    /// @param aggregator_ Chainlink aggregator (proxy) address to wrap.
    /// @param maxStalePeriod_ Maximum allowed answer age, in seconds, in (0, 7 days].
    /// @param maxDeviation_ Maximum allowed deviation, WAD-scaled, in (0, 1e18].
    /// @param roundsToCheck_ Maximum reference window size, in [1, `MAX_ROUNDS_TO_CHECK`].
    /// @param minValidRounds_ Minimum usable previous rounds, in [1, `roundsToCheck_`].
    ///        Setting it equal to `roundsToCheck_` makes the full window mandatory,
    ///        which also fails reads on the first rounds of a new aggregator phase.
    constructor(
        address aggregator_,
        uint32 maxStalePeriod_,
        uint256 maxDeviation_,
        uint256 roundsToCheck_,
        uint256 minValidRounds_
    ) {
        if (aggregator_ == address(0)) revert ZeroAddress();
        if (maxStalePeriod_ == 0) revert ZeroStalePeriod();
        if (maxStalePeriod_ > MAX_STALE_PERIOD_LIMIT) revert MaxStalePeriodTooLong();
        if (maxDeviation_ == 0) revert ZeroMaxDeviation();
        if (maxDeviation_ > WAD) revert MaxDeviationTooHigh();
        if (roundsToCheck_ == 0 || roundsToCheck_ > MAX_ROUNDS_TO_CHECK) revert InvalidRoundsToCheck();
        if (minValidRounds_ == 0 || minValidRounds_ > roundsToCheck_) revert InvalidMinValidRounds();

        AGGREGATOR = aggregator_;
        MAX_STALE_PERIOD = maxStalePeriod_;
        MAX_DEVIATION = maxDeviation_;
        ROUNDS_TO_CHECK = roundsToCheck_;
        MIN_VALID_ROUNDS = minValidRounds_;
        /// @dev also rejects addresses without aggregator code at deploy time
        PRICE_FEED_DECIMALS = AggregatorV3Interface(aggregator_).decimals();

        emit PriceFeedInitialized(
            aggregator_,
            maxStalePeriod_,
            maxDeviation_,
            roundsToCheck_,
            minValidRounds_,
            PRICE_FEED_DECIMALS
        );
    }

    /// @inheritdoc IPriceFeed
    function decimals() external view override returns (uint8) {
        return PRICE_FEED_DECIMALS;
    }

    /// @inheritdoc IPriceFeed
    /// @dev Returns the aggregator's round data unchanged after both guards pass.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        int256 answer;
        uint256 updatedAt;
        (roundId, answer, startedAt, updatedAt, answeredInRound) = AggregatorV3Interface(AGGREGATOR).latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert StalePrice();
        if (updatedAt > block.timestamp) revert FuturePrice();
        if (block.timestamp > updatedAt + MAX_STALE_PERIOD) revert StalePrice();

        _checkDeviation(roundId, uint256(answer));

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    /// @dev Reverts unless `latestPrice_` is within `MAX_DEVIATION` of the arithmetic
    /// mean of the previous `ROUNDS_TO_CHECK` rounds.
    ///
    /// Chainlink round ids are `(phaseId << 64) | aggregatorRoundId` with aggregator
    /// round ids starting at 1 within each phase, so the loop bound `i < aggregatorRoundId`
    /// both prevents underflow and keeps the walk inside the current phase. The walk
    /// starts at `i = 1` so the latest round is never part of its own reference mean.
    /// Rounds that revert or carry no valid data (answer <= 0 or updatedAt == 0) shrink
    /// the window; fewer than `MIN_VALID_ROUNDS` usable rounds fail the read closed.
    function _checkDeviation(uint80 latestRoundId_, uint256 latestPrice_) internal view {
        uint64 aggregatorRoundId = uint64(latestRoundId_);

        uint256 sum;
        uint256 count;

        for (uint256 i = 1; i <= ROUNDS_TO_CHECK && i < aggregatorRoundId; ++i) {
            try AggregatorV3Interface(AGGREGATOR).getRoundData(latestRoundId_ - uint80(i)) returns (
                uint80,
                int256 prevAnswer,
                uint256,
                uint256 prevUpdatedAt,
                uint80
            ) {
                if (prevAnswer > 0 && prevUpdatedAt > 0) {
                    sum += uint256(prevAnswer);
                    ++count;
                }
            } catch {
                // unavailable round - shrink the window
            }
        }

        if (count < MIN_VALID_ROUNDS) revert InsufficientValidRounds(count, MIN_VALID_ROUNDS);

        uint256 mean = sum / count;
        uint256 diff = latestPrice_ > mean ? latestPrice_ - mean : mean - latestPrice_;
        uint256 deviation = Math.mulDiv(diff, WAD, mean);

        if (deviation > MAX_DEVIATION) revert DeviationTooHigh(deviation, MAX_DEVIATION);
    }
}
