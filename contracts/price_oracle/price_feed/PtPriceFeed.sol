// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

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

    /// @notice The method to use for the Pendle oracle
    /// @dev 0 for getPtToSyRate, 1 for getPtToAssetRate
    uint256 public immutable USE_PENDLE_ORACLE_METHOD;

    error PriceOracleInvalidTwapWindow(uint32 provided, uint32 minimum);
    error PriceOraclePendleOracleNotReady();
    error PriceOracleZeroAddress();
    error PriceOracleInvalidPrice();

    /// @notice Initializes the PT price feed
    /// @dev Verifies that:
    /// 1. TWAP window is sufficiently long (min 5 min, recommended 15 min)
    /// 2. Pendle oracle is active and has enough historical data
    /// 3. Price middleware supports the underlying asset from SY
    /// @param pendleOracle_ Address of the Pendle oracle
    /// @param pendleMarket_ Address of the Pendle market
    /// @param twapWindow_ Duration of TWAP window (recommended 15 minutes)
    /// @param priceMiddleware_ Address of price oracle middleware that must support the underlying asset
    /// @param usePendleOracleMethod 0 for getPtToSyRate, 1 for getPtToAssetRate
    constructor(
        address pendleOracle_,
        address pendleMarket_,
        uint32 twapWindow_,
        address priceMiddleware_,
        uint256 usePendleOracleMethod
    ) {
        if (twapWindow_ < MIN_TWAP_WINDOW) {
            revert PriceOracleInvalidTwapWindow(twapWindow_, MIN_TWAP_WINDOW);
        }

        if (pendleOracle_ == address(0) || pendleMarket_ == address(0) || priceMiddleware_ == address(0)) {
            revert PriceOracleZeroAddress();
        }

        (bool increaseCardinalityRequired, uint16 cardinalityRequired, bool oldestObservationSatisfied) = IPPYLpOracle(
            pendleOracle_
        ).getOracleState(pendleMarket_, twapWindow_);

        if (increaseCardinalityRequired || !oldestObservationSatisfied) {
            revert PriceOraclePendleOracleNotReady();
        }

        (IStandardizedYield sy, , ) = IPMarket(pendleMarket_).readTokens();

        (, address assetAddress, uint8 assetDecimals) = sy.assetInfo();

        PENDLE_MARKET = pendleMarket_;
        TWAP_WINDOW = twapWindow_;
        PRICE_MIDDLEWARE = priceMiddleware_;
        ASSET_ADDRESS = assetAddress;
        ASSET_DECIMALS = assetDecimals;
        USE_PENDLE_ORACLE_METHOD = usePendleOracleMethod;
    }

    /// @inheritdoc IPriceFeed
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        uint32 twapWindow = TWAP_WINDOW;

        uint256 unitPrice;
        if (USE_PENDLE_ORACLE_METHOD == 1) {
            unitPrice = PendlePYOracleLib.getPtToAssetRate(IPMarket(PENDLE_MARKET), twapWindow);
        } else {
            unitPrice = PendlePYOracleLib.getPtToSyRate(IPMarket(PENDLE_MARKET), twapWindow);
        }

        (uint256 assetPrice, uint256 priceDecimals) = IPriceOracleMiddleware(PRICE_MIDDLEWARE).getAssetPrice(
            ASSET_ADDRESS
        );

        uint256 scalingFactor = FEED_DECIMALS + priceDecimals - _decimals();
        price = SafeCast.toInt256((unitPrice * assetPrice) / 10 ** scalingFactor);

        if (price <= 0) {
            revert PriceOracleInvalidPrice();
        }

        time = block.timestamp;
    }

    function _decimals() internal pure returns (uint8) {
        return 8;
    }

    /// @notice Returns the raw PT to asset rate without price adjustment
    /// @return Rate in 18 decimals
    function getPtToAssetRate() external view returns (uint256) {
        return PendlePYOracleLib.getPtToAssetRate(IPMarket(PENDLE_MARKET), TWAP_WINDOW);
    }

    /// @notice Returns the underlying asset price from middleware
    /// @return price Asset price
    /// @return decimals Price decimals
    function getUnderlyingPrice() external view returns (uint256, uint256) {
        return IPriceOracleMiddleware(PRICE_MIDDLEWARE).getAssetPrice(ASSET_ADDRESS);
    }
}
