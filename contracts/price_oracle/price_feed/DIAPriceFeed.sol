// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDIAOracleV2} from "../ext/IDIAOracleV2.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title DIAPriceFeed
/// @notice Chainlink-style wrapper over a DIA Data oracle key (e.g. "OUSD/USD").
/// @dev Reads `getValue(key)` from the configured DIA oracle, validates the
/// publication is non-zero and fresh against `MAX_STALE_PERIOD`, then rescales
/// the DIA value from `DIA_DECIMALS` to `PRICE_FEED_DECIMALS` and returns it
/// through the `IPriceFeed` interface used by `PriceOracleMiddleware`.
contract DIAPriceFeed is IPriceFeed {
    using SafeCast for uint256;

    /// @notice Hard upper bound on `MAX_STALE_PERIOD`. DIA's heartbeat is 24h;
    /// 7 days is a generous operator buffer that still rules out misconfig
    /// (e.g. `type(uint32).max`) effectively disabling staleness checks.
    uint32 public constant MAX_STALE_PERIOD_LIMIT = 7 days;

    /// @notice Hard upper bound on `PRICE_FEED_DECIMALS - DIA_DECIMALS`. Above
    /// this, `uint128 * SCALE` can exceed `type(uint256).max`. With max DIA
    /// value `2^128 - 1 (~3.4e38)`, `10**38` keeps the product below `2^256`.
    uint8 public constant MAX_DECIMALS_DELTA = 38;

    error ZeroAddress();
    error EmptyKey();
    error ZeroStalePeriod();
    error MaxStalePeriodTooLong();
    error ZeroDiaDecimals();
    error PriceFeedDecimalsTooLow();
    error DecimalsDeltaTooLarge();
    error InvalidPrice();
    error StalePrice();
    error FuturePrice();

    event PriceFeedInitialized(
        address indexed diaOracle,
        string key,
        uint32 maxStalePeriod,
        uint8 diaDecimals,
        uint8 priceFeedDecimals
    );

    /// @notice DIA oracle contract address.
    address public immutable DIA_ORACLE;

    /// @notice Maximum allowed age of a DIA publication, in seconds.
    uint32 public immutable MAX_STALE_PERIOD;

    /// @notice Number of decimals used by the DIA oracle for this key.
    /// Standard across EVM chains is 8, but some deployments publish with 5
    /// (per DIA docs). Caller must configure this per the target chain/key.
    uint8 public immutable DIA_DECIMALS;

    /// @notice Number of decimals of the price returned by this feed.
    uint8 public immutable PRICE_FEED_DECIMALS;

    /// @notice Multiplier that scales a DIA value from `DIA_DECIMALS` up to
    /// `PRICE_FEED_DECIMALS`. Computed as `10 ** (PRICE_FEED_DECIMALS - DIA_DECIMALS)`.
    uint256 public immutable SCALE;

    /// @notice DIA oracle key, e.g. "OUSD/USD".
    /// @dev Stored as a string because Solidity does not support `immutable string`.
    /// Effectively immutable: assigned once in the constructor, no setter exists,
    /// and the contract uses no `delegatecall`.
    string public KEY;

    constructor(
        address diaOracle_,
        string memory key_,
        uint32 maxStalePeriod_,
        uint8 diaDecimals_,
        uint8 priceFeedDecimals_
    ) {
        if (diaOracle_ == address(0)) revert ZeroAddress();
        if (bytes(key_).length == 0) revert EmptyKey();
        if (maxStalePeriod_ == 0) revert ZeroStalePeriod();
        if (maxStalePeriod_ > MAX_STALE_PERIOD_LIMIT) revert MaxStalePeriodTooLong();
        if (diaDecimals_ == 0) revert ZeroDiaDecimals();
        if (priceFeedDecimals_ < diaDecimals_) revert PriceFeedDecimalsTooLow();
        if (priceFeedDecimals_ - diaDecimals_ > MAX_DECIMALS_DELTA) revert DecimalsDeltaTooLarge();

        DIA_ORACLE = diaOracle_;
        KEY = key_;
        MAX_STALE_PERIOD = maxStalePeriod_;
        DIA_DECIMALS = diaDecimals_;
        PRICE_FEED_DECIMALS = priceFeedDecimals_;
        SCALE = 10 ** uint256(priceFeedDecimals_ - diaDecimals_);

        emit PriceFeedInitialized(diaOracle_, key_, maxStalePeriod_, diaDecimals_, priceFeedDecimals_);
    }

    /// @inheritdoc IPriceFeed
    function decimals() external view override returns (uint8) {
        return PRICE_FEED_DECIMALS;
    }

    /// @inheritdoc IPriceFeed
    /// @dev Returns `(0, price, timestamp, timestamp, 0)` — DIA has no round
    /// concept so `roundId` and `answeredInRound` are zero. `price` is the DIA
    /// value rescaled from `DIA_DECIMALS` to `PRICE_FEED_DECIMALS`.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (uint128 value, uint128 timestamp) = IDIAOracleV2(DIA_ORACLE).getValue(KEY);

        if (value == 0) revert InvalidPrice();
        if (timestamp == 0) revert StalePrice();
        if (uint256(timestamp) > block.timestamp) revert FuturePrice();
        if (block.timestamp > uint256(timestamp) + MAX_STALE_PERIOD) revert StalePrice();

        price = (uint256(value) * SCALE).toInt256();
        time = uint256(timestamp);
        startedAt = time;

        return (0, price, startedAt, time, 0);
    }
}
