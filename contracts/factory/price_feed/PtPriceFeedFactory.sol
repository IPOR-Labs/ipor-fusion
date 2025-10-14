// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PtPriceFeed} from "../../price_oracle/price_feed/PtPriceFeed.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {PendlePYOracleLib} from "@pendle/core-v2/contracts/oracles/PendlePYOracleLib.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PtPriceFeedFactory
/// @notice Factory contract for creating price feeds for Pendle Principal Tokens (PT)
/// @dev This contract is upgradeable and uses UUPS pattern for upgrades
contract PtPriceFeedFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    using SafeCast for uint256;

    uint8 internal constant FEED_DECIMALS = 18;
    /// @notice Emitted when a new PT price feed is created
    /// @param priceFeed The address of the newly created price feed
    /// @param pendleMarket The address of the Pendle market
    event PtPriceFeedCreated(address priceFeed, address pendleMarket);

    /// @notice Error thrown when an invalid address (zero address) is provided
    error InvalidAddress();

    /// @notice Error thrown when the expected price is invalid (zero or negative)
    error InvalidExpectedPrice();

    /// @notice Error thrown when the price delta exceeds 1% tolerance
    error PriceDeltaTooHigh();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the factory contract
    /// @dev This function can only be called once during contract deployment
    /// @param initialFactoryAdmin_ The address that will be set as the initial admin of the factory
    function initialize(address initialFactoryAdmin_) external initializer {
        if (initialFactoryAdmin_ == address(0)) revert InvalidAddress();
        __Ownable_init(initialFactoryAdmin_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Creates a new PT price feed instance
    /// @dev The function validates that:
    /// @dev - All addresses are valid (non-zero)
    /// @dev - Expected price is positive
    /// @dev - Actual price is within 1% of expected price
    /// @dev The price validation logic follows the same approach as PriceOracleMiddlewareWithRoles.createAndAddPtTokenPriceFeed
    /// @param pendleOracle_ Address of the Pendle oracle contract used for price feeds
    /// @param pendleMarket_ Address of the Pendle market contract associated with the PT
    /// @param twapWindow_ Time window in seconds for TWAP calculations
    /// @param priceMiddleware_ Address of the price oracle middleware
    /// @param usePendleOracleMethod_ Configuration parameter for the PtPriceFeed's oracle method (0 for getPtToSyRate, 1 for getPtToAssetRate)
    /// @param expextedPriceAfterDeployment_ Expected initial price of PT token (used for validation with 1% tolerance)
    /// @return priceFeedAddress The address of the newly created price feed
    function create(
        address pendleOracle_,
        address pendleMarket_,
        uint32 twapWindow_,
        address priceMiddleware_,
        uint256 usePendleOracleMethod_,
        int256 expextedPriceAfterDeployment_
    ) external returns (address priceFeedAddress) {
        if (pendleOracle_ == address(0) || pendleMarket_ == address(0) || priceMiddleware_ == address(0)) {
            revert InvalidAddress();
        }

        if (expextedPriceAfterDeployment_ <= 0) {
            revert InvalidExpectedPrice();
        }

        PtPriceFeed ptPriceFeed = new PtPriceFeed(
            pendleOracle_,
            pendleMarket_,
            twapWindow_,
            priceMiddleware_,
            usePendleOracleMethod_
        );

        (, int256 price, , , ) = ptPriceFeed.latestRoundData();

        if (price < expextedPriceAfterDeployment_) {
            int256 priceDelta = expextedPriceAfterDeployment_ - price;
            int256 priceDeltaPercentage = (priceDelta * 100) / expextedPriceAfterDeployment_;

            if (priceDeltaPercentage > 1) {
                revert PriceDeltaTooHigh();
            }
        } else {
            int256 priceDelta = price - expextedPriceAfterDeployment_;
            int256 priceDeltaPercentage = (priceDelta * 100) / expextedPriceAfterDeployment_;

            if (priceDeltaPercentage > 1) {
                revert PriceDeltaTooHigh();
            }
        }

        priceFeedAddress = address(ptPriceFeed);
        emit PtPriceFeedCreated(priceFeedAddress, pendleMarket_);
    }

    /// @notice Calculates the price for a PT token without creating a price feed instance
    /// @dev Uses the same pricing logic as PtPriceFeed.latestRoundData()
    /// @dev This is useful for previewing the price before creating an actual price feed
    /// @param pendleMarket_ Address of the Pendle market contract associated with the PT
    /// @param twapWindow_ Time window in seconds for TWAP calculations
    /// @param priceMiddleware_ Address of the price oracle middleware
    /// @param usePendleOracleMethod_ Configuration parameter for the oracle method (0 for getPtToSyRate, 1 for getPtToAssetRate)
    /// @return price The calculated price in the same format as PtPriceFeed returns
    function calculatePrice(
        address pendleMarket_,
        uint32 twapWindow_,
        address priceMiddleware_,
        uint256 usePendleOracleMethod_
    ) external view returns (int256 price) {
        (IStandardizedYield sy, , ) = IPMarket(pendleMarket_).readTokens();

        (, address assetAddress, ) = sy.assetInfo();

        uint256 unitPrice;
        if (usePendleOracleMethod_ == 1) {
            unitPrice = PendlePYOracleLib.getPtToAssetRate(IPMarket(pendleMarket_), twapWindow_);
        } else {
            unitPrice = PendlePYOracleLib.getPtToSyRate(IPMarket(pendleMarket_), twapWindow_);
        }

        (uint256 assetPrice, uint256 priceDecimals) = IPriceOracleMiddleware(priceMiddleware_).getAssetPrice(
            assetAddress
        );

        uint256 scalingFactor = FEED_DECIMALS + priceDecimals - _decimals();
        price = SafeCast.toInt256((unitPrice * assetPrice) / 10 ** scalingFactor);
    }

    /// @notice Returns the number of decimals used in price values, used in PtPriceFeed
    /// @return The number of decimals (8)
    function _decimals() internal pure returns (uint8) {
        return 8;
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required by the OZ UUPS module, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
