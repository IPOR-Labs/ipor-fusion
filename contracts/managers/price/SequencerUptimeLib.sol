// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "../../price_oracle/ext/AggregatorV3Interface.sol";

/// @title SequencerUptimeLib
/// @notice Library for L2 sequencer uptime validation using Chainlink Sequencer Uptime Feeds
/// @dev Supports both Arbitrum and OP Stack (Base/Optimism) with chain-specific logic
library SequencerUptimeLib {
    /// @dev Grace period after sequencer restart before allowing operations (1 hour)
    uint256 internal constant GRACE_PERIOD = 3600;

    /// @dev Maximum staleness for Arbitrum sequencer feed (7 days safety net)
    /// @dev On Arbitrum, the feed only updates on status change — can be legitimately old on healthy systems
    uint256 internal constant SEQ_FEED_MAX_AGE_ARBITRUM = 604800;

    /// @dev Maximum staleness for OP Stack sequencer feed (48 hours = 2x 24h heartbeat)
    /// @dev On Base/Optimism, the feed updates every 24h as a health check
    uint256 internal constant SEQ_FEED_MAX_AGE_OP_STACK = 172800;

    error SequencerDown();
    error GracePeriodNotElapsed(uint256 timeSinceRestart, uint256 gracePeriod);
    error SequencerFeedStale(uint256 updatedAt, uint256 maxAge);

    /// @notice Validates L2 sequencer uptime status
    /// @param sequencerFeed_ Address of the Chainlink Sequencer Uptime Feed (address(0) to skip)
    /// @param isOpStackFeed_ True for Base/Optimism, false for Arbitrum
    function checkSequencerUptime(address sequencerFeed_, bool isOpStackFeed_) internal view {
        if (sequencerFeed_ == address(0)) return;

        (, int256 answer, uint256 startedAt, uint256 updatedAt, ) = AggregatorV3Interface(sequencerFeed_)
            .latestRoundData();

        // Arbitrum: handle uninitialized feed (never received a status update)
        if (!isOpStackFeed_ && startedAt == 0 && updatedAt == 0) {
            return;
        }

        // Feed staleness check — safety net for genuine Chainlink node failure
        uint256 maxAge = isOpStackFeed_ ? SEQ_FEED_MAX_AGE_OP_STACK : SEQ_FEED_MAX_AGE_ARBITRUM;
        if (updatedAt > 0 && block.timestamp - updatedAt > maxAge) {
            revert SequencerFeedStale(updatedAt, maxAge);
        }

        // answer: 0 = sequencer UP, 1 = sequencer DOWN
        if (answer != 0) {
            revert SequencerDown();
        }

        // Grace period: wait after sequencer comes back up before allowing operations
        // startedAt = when status LAST CHANGED (when sequencer came back online)
        uint256 timeSinceRestart = block.timestamp - startedAt;
        if (timeSinceRestart < GRACE_PERIOD) {
            revert GracePeriodNotElapsed(timeSinceRestart, GRACE_PERIOD);
        }
    }
}
