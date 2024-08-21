// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {IPriceOracleMiddleware} from "../../contracts/priceOracle/IPriceOracleMiddleware.sol";

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
    function getAssetPrice(address asset) external view returns (uint256) {
        return 0;
    }
    //solhint-disable-next-line
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory) {
        return new uint256[](0);
    }
    //solhint-disable-next-line
    function getSourceOfAssetPrice(address asset) external view returns (address) {
        return address(0);
    }

    //solhint-disable-next-line
    function setAssetsPricesSources(address[] calldata assets, address[] calldata sources) external {}
}
