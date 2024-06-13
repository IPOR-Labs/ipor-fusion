// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";

import {IPriceOracleMiddleware} from "./IPriceOracleMiddleware.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {PriceOracleMiddlewareStorageLib} from "./PriceOracleMiddlewareStorageLib.sol";
import {Errors} from "../libraries/errors/Errors.sol";

contract PriceOracleMiddleware is IPriceOracleMiddleware, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeCast for int256;

    // usd - 0x0000000000000000000000000000000000000348
    address public immutable BASE_CURRENCY;
    // usd - 8
    uint256 public immutable BASE_CURRENCY_DECIMALS;
    address public immutable CHAINLINK_FEED_REGISTRY;

    constructor(address baseCurrency, uint256 baseCurrencyDecimals, address chainlinkFeedRegistry) {
        if (baseCurrency == address(0)) {
            revert IPriceOracleMiddleware.ZeroAddress(Errors.UNSUPPORTED_ZERO_ADDRESS, "baseCurrency");
        }

        BASE_CURRENCY = baseCurrency;
        BASE_CURRENCY_DECIMALS = baseCurrencyDecimals;
        CHAINLINK_FEED_REGISTRY = chainlinkFeedRegistry;
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        // todo check what is needed
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return _getAssetPrice(asset);
    }

    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory) {
        uint256 assetsLength = assets.length;
        if (assetsLength == 0) {
            revert IPriceOracleMiddleware.EmptyArrayNotSupported(Errors.UNSUPPORTED_EMPTY_ARRAY);
        }
        uint256[] memory prices = new uint256[](assetsLength);
        for (uint256 i; i < assetsLength; ++i) {
            prices[i] = _getAssetPrice(assets[i]);
        }
        return prices;
    }

    function getSourceOfAsset(address asset) external view returns (address) {
        return PriceOracleMiddlewareStorageLib.getSourceOfAsset(asset);
    }

    function setAssetSources(address[] calldata assets, address[] calldata sources) external onlyOwner {
        uint256 assetsLength = assets.length;
        uint256 sourcesLength = sources.length;
        if (assetsLength == 0 || sourcesLength == 0) {
            revert IPriceOracleMiddleware.EmptyArrayNotSupported(Errors.UNSUPPORTED_EMPTY_ARRAY);
        }
        if (assetsLength != sourcesLength) {
            revert IPriceOracleMiddleware.ArrayLengthMismatch(Errors.ARRAY_LENGTH_MISMATCH);
        }
        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareStorageLib.setAssetSource(assets[i], sources[i]);
        }
    }

    function _getAssetPrice(address asset) private view returns (uint256) {
        address source = PriceOracleMiddlewareStorageLib.getSourceOfAsset(asset);
        uint80 roundId;
        int256 price;
        uint256 startedAt;
        uint256 time;
        uint80 answeredInRound;
        if (source != address(0)) {
            (roundId, price, startedAt, time, answeredInRound) = IPriceFeed(source).latestRoundData();
        } else {
            if (CHAINLINK_FEED_REGISTRY == address(0)) {
                revert IPriceOracleMiddleware.UnsupportedAsset(Errors.UNSUPPORTED_ASSET);
            }
            try FeedRegistryInterface(CHAINLINK_FEED_REGISTRY).latestRoundData(asset, BASE_CURRENCY) returns (
                uint80 roundIdChainlink,
                int256 priceChainlink,
                uint256 startedAtChainlink,
                uint256 timeChainlink,
                uint80 answeredInRoundChainlink
            ) {
                price = priceChainlink;
            } catch {
                revert IPriceOracleMiddleware.UnsupportedAsset(Errors.UNSUPPORTED_ASSET);
            }
        }
        if (price <= 0) {
            revert IPriceOracleMiddleware.UnexpectedPriceResult(Errors.CHAINLINK_PRICE_ERROR);
        }
        return price.toUint256();
    }

    //solhint-disable-next-line
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
