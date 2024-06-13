// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IIporPriceOracle} from "../../contracts/priceOracle/IIporPriceOracle.sol";

contract IporPriceOracleMock is IIporPriceOracle {
    //solhint-disable-next-line
    address public BASE_CURRENCY;
    // usd - 8
    //solhint-disable-next-line
    uint256 public BASE_CURRENCY_DECIMALS;
    address public immutable CHAINLINK_FEED_REGISTRY;

    constructor(address baseCurrency, uint256 baseCurrencyDecimals, address chainlinkFeedRegistry) {
        BASE_CURRENCY = baseCurrency;
        BASE_CURRENCY_DECIMALS = baseCurrencyDecimals;
        CHAINLINK_FEED_REGISTRY = chainlinkFeedRegistry;
    }
    //solhint-disable-next-line
    function getAssetPrice(address asset) external view returns (uint256) {
        return 0;
    }
    //solhint-disable-next-line
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory) {
        return new uint256[](0);
    }
    //solhint-disable-next-line
    function getSourceOfAsset(address asset) external view returns (address) {
        return address(0);
    }

    //solhint-disable-next-line
    function setAssetSources(address[] calldata assets, address[] calldata sources) external {}
}
