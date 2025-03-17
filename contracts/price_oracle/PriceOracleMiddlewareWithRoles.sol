// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";
import {IPriceOracleMiddleware} from "./IPriceOracleMiddleware.sol";
import {IPriceFeed} from "./price_feed/IPriceFeed.sol";
import {PriceOracleMiddlewareStorageLib} from "./PriceOracleMiddlewareStorageLib.sol";
import {IporMath} from "../libraries/math/IporMath.sol";

import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {PtPriceFeed} from "./price_feed/PtPriceFeed.sol";
import {IporFusionAccessControl} from "./IporFusionAccessControl.sol";

/// @title Price Oracle Middleware
/// @notice Contract responsible for providing standardized asset price feeds in USD
/// @dev Supports both custom price feeds and Chainlink Feed Registry as fallback.
/// @dev When CHAINLINK_FEED_REGISTRY is set to address(0), Chainlink fallback is disabled
/// @dev and only custom price feeds will be supported
contract PriceOracleMiddlewareWithRoles is IporFusionAccessControl, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeCast for int256;

    /// @dev Quote currency address representing USD (Chainlink standard)
    /// @notice This is the standard Chainlink USD address used for price feeds
    address public constant QUOTE_CURRENCY = address(0x0000000000000000000000000000000000000348);

    /// @dev Number of decimals used for USD price representation
    /// @notice Every price returned by a specific price feed is converted to this decimals
    uint256 public constant QUOTE_CURRENCY_DECIMALS = 18;

    /// @dev Address of Chainlink Feed Registry (immutable, set in constructor)
    /// @notice Currently supported only on Ethereum Mainnet
    /// @notice If set to address(0), Chainlink Registry fallback is disabled and only custom price feeds will work
    address public immutable CHAINLINK_FEED_REGISTRY;

    constructor(address chainlinkFeedRegistry_) {
        CHAINLINK_FEED_REGISTRY = chainlinkFeedRegistry_;
    }

    /// @notice Initializes the contract
    /// @param initialAdmin_ The address that will own the contract
    /// @dev Should be a multi-sig wallet for security
    function initialize(address initialAdmin_) external initializer {
        __IporFusionAccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin_);
    }

    /// @notice Gets the USD price for a single asset
    /// @param asset_ The address of the asset to price
    /// @return assetPrice The price in USD (with QUOTE_CURRENCY_DECIMALS decimals)
    /// @return decimals The number of decimals in the returned price
    function getAssetPrice(address asset_) external view returns (uint256 assetPrice, uint256 decimals) {
        (assetPrice, decimals) = _getAssetPrice(asset_);
    }

    /// @notice Gets USD prices for multiple assets in a single call
    /// @param assets_ Array of asset addresses to price
    /// @return assetPrices Array of prices in USD (with QUOTE_CURRENCY_DECIMALS decimals)
    /// @return decimalsList Array of decimals for each returned price
    /// @dev Reverts if:
    /// @dev - assets_ array is empty
    /// @dev - any asset price feed returns price <= 0
    /// @dev - any price feed has incorrect decimals
    /// @dev - any asset is unsupported (no custom feed and no Chainlink support)
    /// @dev - zero address is provided as an asset
    /// @dev Note: This is a batch operation - if any asset price fetch fails, the entire call reverts
    function getAssetsPrices(
        address[] calldata assets_
    ) external view returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        uint256 assetsLength = assets_.length;

        if (assetsLength == 0) {
            revert IPriceOracleMiddleware.EmptyArrayNotSupported();
        }

        assetPrices = new uint256[](assetsLength);
        decimalsList = new uint256[](assetsLength);

        for (uint256 i; i < assetsLength; ++i) {
            (assetPrices[i], decimalsList[i]) = _getAssetPrice(assets_[i]);
        }
    }

    /// @notice Returns the price feed source for a given asset
    /// @param asset_ The address of the asset
    /// @return sourceOfAssetPrice The address of the price feed source (returns zero address if using Chainlink Registry)
    function getSourceOfAssetPrice(address asset_) external view returns (address sourceOfAssetPrice) {
        sourceOfAssetPrice = PriceOracleMiddlewareStorageLib.getSourceOfAssetPrice(asset_);
    }

    /// @notice Sets or updates price feed sources for multiple assets
    /// @param assets_ Array of asset addresses
    /// @param sources_ Array of corresponding price feed sources
    /// @dev Arrays must be equal length and non-empty
    /// @dev Only callable by owner
    function setAssetsPricesSources(
        address[] calldata assets_,
        address[] calldata sources_
    ) external onlyRole(SET_ASSETS_PRICES_SOURCES) {
        uint256 assetsLength = assets_.length;
        uint256 sourcesLength = sources_.length;

        if (assetsLength == 0 || sourcesLength == 0) {
            revert IPriceOracleMiddleware.EmptyArrayNotSupported();
        }
        if (assetsLength != sourcesLength) {
            revert IPriceOracleMiddleware.ArrayLengthMismatch();
        }

        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareStorageLib.setAssetPriceSource(assets_[i], sources_[i]);
        }
    }

    /// @notice Adds a new Pendle Principal Token (PT) to the price oracle system
    /// @dev Creates and configures a new PtPriceFeed contract for the PT token
    /// @dev Validates the initial price against expected price with 1% tolerance
    /// @dev The function will revert if:
    /// @dev - Expected price is <= 0
    /// @dev - Price delta between actual and expected price is > 1%
    /// @dev - PT token already has a price source configured
    /// @param pendleOracle_ Address of the Pendle Oracle contract used for price feeds
    /// @param pendleMarket_ Address of the Pendle Market contract associated with the PT
    /// @param twapWindow_ Time window in seconds for TWAP calculations
    /// @param expextedPriceAfterDeployment_ Expected initial price of PT token (used for validation)
    /// @param usePendleOracleMethod_ Configuration parameter for the PtPriceFeed's oracle method
    function addNewPtToken(
        address pendleOracle_,
        address pendleMarket_,
        uint32 twapWindow_,
        int256 expextedPriceAfterDeployment_,
        uint256 usePendleOracleMethod_
    ) external onlyRole(ADD_PT_TOKEN_PRICE) {
        if (expextedPriceAfterDeployment_ <= 0) {
            revert IPriceOracleMiddleware.InvalidExpectedPrice();
        }

        PtPriceFeed ptPriceFeed = new PtPriceFeed(
            pendleOracle_,
            pendleMarket_,
            twapWindow_,
            address(this),
            usePendleOracleMethod_
        );

        (, int256 price, , , ) = ptPriceFeed.latestRoundData();

        if (price < expextedPriceAfterDeployment_) {
            int256 priceDelta = expextedPriceAfterDeployment_ - price;
            int256 priceDeltaPercentage = (priceDelta * 100) / expextedPriceAfterDeployment_;

            if (priceDeltaPercentage > 1) {
                revert IPriceOracleMiddleware.PriceDeltaTooHigh();
            }
        } else {
            int256 priceDelta = price - expextedPriceAfterDeployment_;
            int256 priceDeltaPercentage = (priceDelta * 100) / expextedPriceAfterDeployment_;

            if (priceDeltaPercentage > 1) {
                revert IPriceOracleMiddleware.PriceDeltaTooHigh();
            }
        }

        address pendleMarket = ptPriceFeed.PENDLE_MARKET();
        (, IPPrincipalToken pt, ) = IPMarket(pendleMarket).readTokens();

        address sourceOfAssetPrice = PriceOracleMiddlewareStorageLib.getSourceOfAssetPrice(address(pt));

        if (sourceOfAssetPrice != address(0)) {
            revert IPriceOracleMiddleware.AssetPriceSourceAlreadySet();
        }

        PriceOracleMiddlewareStorageLib.setAssetPriceSource(address(pt), address(ptPriceFeed));
    }

    /// @notice Internal function to get asset price from either custom feed or Chainlink
    /// @param asset_ The address of the asset to price
    /// @return assetPrice The price in USD (with QUOTE_CURRENCY_DECIMALS decimals)
    /// @return decimals The number of decimals in the returned price
    /// @dev Tries custom price feed first, falls back to Chainlink Registry if no custom feed is set
    /// @dev Reverts if:
    /// @dev - asset_ is zero address
    /// @dev - price <= 0
    /// @dev - decimals don't match QUOTE_CURRENCY_DECIMALS
    /// @dev - no custom price feed is set and CHAINLINK_FEED_REGISTRY is address(0)
    /// @dev - asset is not supported in Chainlink Registry when using it as fallback
    /// @dev - Chainlink Registry call fails
    function _getAssetPrice(address asset_) private view returns (uint256 assetPrice, uint256 decimals) {
        if (asset_ == address(0)) {
            revert IPriceOracleMiddleware.UnsupportedAsset();
        }

        address source = PriceOracleMiddlewareStorageLib.getSourceOfAssetPrice(asset_);

        int256 priceFeedPrice;
        uint256 priceFeedDecimals;

        if (source != address(0)) {
            priceFeedDecimals = IPriceFeed(source).decimals();
            (, priceFeedPrice, , , ) = IPriceFeed(source).latestRoundData();
        } else {
            if (CHAINLINK_FEED_REGISTRY == address(0)) {
                revert IPriceOracleMiddleware.UnsupportedAsset();
            }

            try FeedRegistryInterface(CHAINLINK_FEED_REGISTRY).latestRoundData(asset_, QUOTE_CURRENCY) returns (
                uint80 roundIdChainlink,
                int256 chainlinkPrice,
                uint256 startedAtChainlink,
                uint256 timeChainlink,
                uint80 answeredInRoundChainlink
            ) {
                priceFeedDecimals = FeedRegistryInterface(CHAINLINK_FEED_REGISTRY).decimals(asset_, QUOTE_CURRENCY);
                priceFeedPrice = chainlinkPrice;
            } catch {
                revert IPriceOracleMiddleware.UnsupportedAsset();
            }
        }

        assetPrice = IporMath.convertToWad(priceFeedPrice.toUint256(), priceFeedDecimals);

        if (assetPrice <= 0) {
            revert IPriceOracleMiddleware.UnexpectedPriceResult();
        }

        decimals = QUOTE_CURRENCY_DECIMALS;
    }

    /// @dev Required by the OZ UUPS module
    /// @param newImplementation Address of the new implementation
    //solhint-disable-next-line
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
