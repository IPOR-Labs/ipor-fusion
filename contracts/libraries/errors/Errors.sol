// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

library Errors {
    error WrongAddress();
    error UnsupportedBaseCurrencyFromOracle(string errorCode);
    error UnsupportedPriceOracle();

    string public constant UNSUPPORTED_ASSET = "IPF_001";
    string public constant UNSUPPORTED_ERC4626 = "IPF_002";
    string public constant UNSUPPORTED_EMPTY_ARRAY = "IPF_003";
    string public constant UNSUPPORTED_ZERO_ADDRESS = "IPF_004";
    string public constant ARRAY_LENGTH_MISMATCH = "IPF_005";
    string public constant UNSUPPORTED_MARKET = "IPF_006";
    string public constant UNSUPPORTED_BASE_CURRENCY = "IPF_007";
    string public constant INCORRECT_CHAINLINK_PRICE = "IPF_008";
    string public constant INCORRECT_PRICE_ORACLE = "IPF_009";
}
