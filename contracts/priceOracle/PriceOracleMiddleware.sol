// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";

import {IPriceOracleMiddleware} from "./IPriceOracleMiddleware.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {PriceOracleMiddlewareStorageLib} from "./PriceOracleMiddlewareStorageLib.sol";

contract PriceOracleMiddleware is IPriceOracleMiddleware, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeCast for int256;

    /// @dev USD - 0x0000000000000000000000000000000000000348
    address public immutable BASE_CURRENCY;
    /// @dev USD - 8
    uint256 public immutable BASE_CURRENCY_DECIMALS;
    /// @dev Chainlink Feed Registry currently supported only on Ethereum Mainnet
    address public immutable CHAINLINK_FEED_REGISTRY;

    constructor(address baseCurrency_, uint256 baseCurrencyDecimals_, address chainlinkFeedRegistry_) {
        if (baseCurrency_ == address(0)) {
            revert IPriceOracleMiddleware.ZeroAddress("baseCurrency");
        }

        if (baseCurrencyDecimals_ == 0) {
            revert IPriceOracleMiddleware.WrongDecimals();
        }

        BASE_CURRENCY = baseCurrency_;
        BASE_CURRENCY_DECIMALS = baseCurrencyDecimals_;
        CHAINLINK_FEED_REGISTRY = chainlinkFeedRegistry_;
    }

    function initialize(address initialOwner_) external initializer {
        __Ownable_init(initialOwner_);
        __UUPSUpgradeable_init();
    }

    function getAssetPrice(address asset_) external view returns (uint256) {
        return _getAssetPrice(asset_);
    }

    function getAssetsPrices(address[] calldata assets_) external view returns (uint256[] memory) {
        uint256 assetsLength = assets_.length;
        if (assetsLength == 0) {
            revert IPriceOracleMiddleware.EmptyArrayNotSupported();
        }
        uint256[] memory prices = new uint256[](assetsLength);
        for (uint256 i; i < assetsLength; ++i) {
            prices[i] = _getAssetPrice(assets_[i]);
        }
        return prices;
    }

    function getSourceOfAssetPrice(address asset_) external view returns (address) {
        return PriceOracleMiddlewareStorageLib.getSourceOfAssetPrice(asset_);
    }

    function setAssetsPricesSources(address[] calldata assets_, address[] calldata sources_) external onlyOwner {
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

    function _getAssetPrice(address asset_) private view returns (uint256) {
        address source = PriceOracleMiddlewareStorageLib.getSourceOfAssetPrice(asset_);
        uint80 roundId;
        int256 price;
        uint256 startedAt;
        uint256 time;
        uint80 answeredInRound;

        if (source != address(0)) {
            (roundId, price, startedAt, time, answeredInRound) = IPriceFeed(source).latestRoundData();
        } else {
            if (CHAINLINK_FEED_REGISTRY == address(0)) {
                revert IPriceOracleMiddleware.UnsupportedAsset();
            }
            try FeedRegistryInterface(CHAINLINK_FEED_REGISTRY).latestRoundData(asset_, BASE_CURRENCY) returns (
                uint80 roundIdChainlink,
                int256 priceChainlink,
                uint256 startedAtChainlink,
                uint256 timeChainlink,
                uint80 answeredInRoundChainlink
            ) {
                price = priceChainlink;
            } catch {
                revert IPriceOracleMiddleware.UnsupportedAsset();
            }
        }
        if (price <= 0) {
            revert IPriceOracleMiddleware.UnexpectedPriceResult();
        }
        return price.toUint256();
    }

    //solhint-disable-next-line
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
