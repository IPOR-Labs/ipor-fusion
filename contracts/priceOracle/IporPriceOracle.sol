// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FeedRegistryInterface} from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";

import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";
import {IIporPriceOracle} from "./IIporPriceOracle.sol";
import {IIporPriceFeed} from "./IIporPriceFeed.sol";
import {IporPriceOracleStorageLib} from "./IporPriceOracleStorageLib.sol";
import {Errors} from "../libraries/errors/Errors.sol";

contract IporPriceOracle is IIporPriceOracle, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeCast for int256;

    // usd - 0x0000000000000000000000000000000000000348
    address public immutable BASE_CURRENCY;
    // usd - 8
    uint256 public immutable BASE_CURRENCY_DECIMALS;
    address public immutable CHAINLINK_FEED_REGISTRY;

    constructor(address baseCurrency, uint256 baseCurrencyDecimals, address chainlinkFeedRegistry) {
        if (baseCurrency == address(0)) {
            revert IIporPriceOracle.ZeroAddress(Errors.ZERO_ADDRESS_NOT_SUPPORTED, "baseCurrency");
        }
        if (chainlinkFeedRegistry == address(0)) {
            revert IIporPriceOracle.ZeroAddress(Errors.ZERO_ADDRESS_NOT_SUPPORTED, "chainlinkFeedRegistry");
        }

        BASE_CURRENCY = baseCurrency;
        BASE_CURRENCY_DECIMALS = baseCurrencyDecimals;
        CHAINLINK_FEED_REGISTRY = chainlinkFeedRegistry;
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        // todo check what is needed
    }

    function setAssetSources(address[] calldata assets, address[] calldata sources) external onlyOwner {
        uint256 assetsLength = assets.length;
        uint256 sourcesLength = sources.length;
        if (assetsLength == 0 || sourcesLength == 0) {
            revert IIporPriceOracle.EmptyArrayNotSupported(Errors.EMPTY_ARRAY_NOT_SUPPORTED);
        }
        if (assetsLength != sourcesLength) {
            revert IIporPriceOracle.ArrayLengthMismatch(Errors.ARRAY_LENGTH_MISMATCH);
        }
        for (uint256 i; i < assetsLength; ++i) {
            IporPriceOracleStorageLib.setAssetSource(assets[i], sources[i]);
        }
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return _getAssetPrice(asset);
    }

    function _getAssetPrice(address asset) private view returns (uint256) {
        address source = IporPriceOracleStorageLib.getSourceOfAsset(asset);
        if (source != address(0)) {
            return IIporPriceFeed(source).getLatestPrice();
        }
        try FeedRegistryInterface(CHAINLINK_FEED_REGISTRY).latestRoundData(asset, BASE_CURRENCY) returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 time,
            uint80 answeredInRound
        ) {
            return price.toUint256();
        } catch {
            revert IIporPriceOracle.UnsupportedAsset(Errors.UNSUPPORTED_ASSET);
        }
    }

    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory) {
        uint256 assetsLength = assets.length;
        if (assetsLength == 0) {
            revert IIporPriceOracle.EmptyArrayNotSupported(Errors.EMPTY_ARRAY_NOT_SUPPORTED);
        }
        uint256[] memory prices = new uint256[](assetsLength);
        for (uint256 i; i < assetsLength; ++i) {
            prices[i] = _getAssetPrice(assets[i]);
        }
        return prices;
    }

    function getSourceOfAsset(address asset) external view returns (address) {
        return IporPriceOracleStorageLib.getSourceOfAsset(asset);
    }

    //solhint-disable-next-line
    function _authorizeUpgrade(address) internal override onlyOwner {}
}