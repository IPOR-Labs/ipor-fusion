// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPriceFeed} from "./IPriceFeed.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {PendlePYOracleLib} from "@pendle/core-v2/contracts/oracles/PendlePYOracleLib.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPYLpOracle} from "@pendle/core-v2/contracts/interfaces/IPPYLpOracle.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Price feed for Pendle Principal Tokens (PT)
/// @notice Provides price data for PT tokens based on Pendle market rates
contract PtPriceFeed is IPriceFeed {
    using SafeCast for uint256;

    uint32 internal constant MIN_TWAP_WINDOW = 5 minutes;
    uint8 internal constant FEED_DECIMALS = 18;
    /// @notice The address of the Pendle market.
    address public immutable PENDLE_MARKET;
    /// @notice The desired length of the twap window.
    uint32 public immutable TWAP_WINDOW;
    /// @notice The address of the base asset, the PT address.
    address public immutable PRICE_MIDDLEWARE;

    address public immutable ASSET_ADDRESS;
    uint8 public immutable ASSET_DECIMALS;

    /// @notice The number of decimals used in price values
    // solhint-disable-next-line const-name-snakecase
    uint8 public constant override decimals = 8;

    error PriceOracle_InvalidConfiguration();

    constructor(address _pendleOracle, address _pendleMarket, uint32 _twapWindow, address _priceMiddleware) {
        // Verify that the TWAP window is sufficiently long.
        if (_twapWindow < MIN_TWAP_WINDOW) revert PriceOracle_InvalidConfiguration();

        // Verify that the observations buffer is adequately sized and populated.
        (bool increaseCardinalityRequired, , bool oldestObservationSatisfied) = IPPYLpOracle(_pendleOracle)
            .getOracleState(_pendleMarket, _twapWindow);
        if (increaseCardinalityRequired || !oldestObservationSatisfied) {
            revert PriceOracle_InvalidConfiguration();
        }

        (IStandardizedYield sy, , ) = IPMarket(_pendleMarket).readTokens();

        PENDLE_MARKET = _pendleMarket;
        TWAP_WINDOW = _twapWindow;
        PRICE_MIDDLEWARE = _priceMiddleware;
        (, ASSET_ADDRESS, ASSET_DECIMALS) = sy.assetInfo();
    }

    /// @inheritdoc IPriceFeed
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        // in 18 decimals
        uint256 unitPrice = PendlePYOracleLib.getPtToAssetRate(IPMarket(PENDLE_MARKET), TWAP_WINDOW);
        (uint256 assetPrice, uint256 decimals) = IPriceOracleMiddleware(PRICE_MIDDLEWARE).getAssetPrice(ASSET_ADDRESS);

        price = ((unitPrice * assetPrice) / 10 ** (FEED_DECIMALS + decimals - _decimals())).toInt256();
        time = block.timestamp;
    }

    function _decimals() internal view returns (uint8) {
        return 8;
    }
}
