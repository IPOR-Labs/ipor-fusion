// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPriceOracleMiddleware} from "../../contracts/price_oracle/IPriceOracleMiddleware.sol";

contract PriceOracleMiddlewareMock is IPriceOracleMiddleware {
    //solhint-disable-next-line
    address public QUOTE_CURRENCY;
    // usd - 8
    //solhint-disable-next-line
    uint256 public QUOTE_CURRENCY_DECIMALS;
    address public immutable CHAINLINK_FEED_REGISTRY;

    constructor(address quoteCurrency_, uint256 quoteCurrencyDecimals_, address chainlinkFeedRegistry_) {
        QUOTE_CURRENCY = quoteCurrency_;
        QUOTE_CURRENCY_DECIMALS = quoteCurrencyDecimals_;
        CHAINLINK_FEED_REGISTRY = chainlinkFeedRegistry_;
    }
    //solhint-disable-next-line
    function getAssetPrice(address asset) external view override returns (uint256 assetPrice, uint256 decimals) {
        return (0, 0);
    }
    //solhint-disable-next-line
    function getAssetsPrices(
        address[] calldata
    ) external view override returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        return (new uint256[](0), new uint256[](0));
    }
    //solhint-disable-next-line
    function getSourceOfAssetPrice(address asset) external view returns (address) {
        return address(0);
    }

    //solhint-disable-next-line
    function setAssetsPricesSources(address[] calldata assets, address[] calldata sources) external {}
}
