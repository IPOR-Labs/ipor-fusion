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
/// @dev Important implementation notes:
/// - IPriceOracleMiddleware must support the asset obtained from SY using assetInfo()
/// - Pendle oracle must be active before deployment, if not it needs to be activated
/// - Recommended _twapWindow value by Pendle is 15 minutes
contract PtPriceFeed is IPriceFeed {
    using SafeCast for uint256;

    /// @notice Minimum TWAP window duration required for price calculations
    /// @dev Should be at least 5 minutes, though 15 minutes is recommended by Pendle
    uint32 internal constant MIN_TWAP_WINDOW = 5 minutes;

    uint8 internal constant FEED_DECIMALS = 18;

    /// @notice The address of the Pendle market
    address public immutable PENDLE_MARKET;

    /// @notice The desired length of the twap window
    /// @dev Recommended value by Pendle is 15 minutes
    uint32 public immutable TWAP_WINDOW;

    /// @notice The address of the price oracle middleware
    /// @dev Must support pricing for the asset obtained from SY.assetInfo()
    address public immutable PRICE_MIDDLEWARE;

    /// @notice The address of the underlying asset from SY.assetInfo()
    address public immutable ASSET_ADDRESS;

    /// @notice The decimals of the underlying asset from SY.assetInfo()
    uint8 public immutable ASSET_DECIMALS;

    /// @notice The number of decimals used in price values
    // solhint-disable-next-line const-name-snakecase
    uint8 public constant override decimals = 8;

    error PriceOracle_InvalidConfiguration();

    /// @notice Initializes the PT price feed
    /// @dev Verifies that:
    /// 1. TWAP window is sufficiently long (min 5 min, recommended 15 min)
    /// 2. Pendle oracle is active and has enough historical data
    /// 3. Price middleware supports the underlying asset from SY
    /// @param _pendleOracle Address of the Pendle oracle
    /// @param _pendleMarket Address of the Pendle market
    /// @param _twapWindow Duration of TWAP window (recommended 15 minutes)
    /// @param _priceMiddleware Address of price oracle middleware that must support the underlying asset
    constructor(address _pendleOracle, address _pendleMarket, uint32 _twapWindow, address _priceMiddleware) {
        // Verify that the TWAP window is sufficiently long.
        if (_twapWindow < MIN_TWAP_WINDOW) revert PriceOracle_InvalidConfiguration();

        // Verify that the observations buffer is adequately sized and populated.
        // This confirms that the Pendle oracle is active and has enough historical data
        (bool increaseCardinalityRequired, , bool oldestObservationSatisfied) = IPPYLpOracle(_pendleOracle)
            .getOracleState(_pendleMarket, _twapWindow);
        if (increaseCardinalityRequired || !oldestObservationSatisfied) {
            revert PriceOracle_InvalidConfiguration();
        }

        (IStandardizedYield sy, , ) = IPMarket(_pendleMarket).readTokens();

        PENDLE_MARKET = _pendleMarket;
        TWAP_WINDOW = _twapWindow;
        PRICE_MIDDLEWARE = _priceMiddleware;
        // Get asset info from SY - price middleware must support this asset
        (, ASSET_ADDRESS, ASSET_DECIMALS) = sy.assetInfo();
    }

    /// @inheritdoc IPriceFeed
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        // Get PT to asset rate in 18 decimals
        uint256 unitPrice = PendlePYOracleLib.getPtToAssetRate(IPMarket(PENDLE_MARKET), TWAP_WINDOW);
        // Get price of underlying asset from middleware - must support the asset from SY.assetInfo()
        (uint256 assetPrice, uint256 decimals) = IPriceOracleMiddleware(PRICE_MIDDLEWARE).getAssetPrice(ASSET_ADDRESS);

        price = ((unitPrice * assetPrice) / 10 ** (FEED_DECIMALS + decimals - _decimals())).toInt256();
        time = block.timestamp;
    }

    function _decimals() internal view returns (uint8) {
        return 8;
    }
}
