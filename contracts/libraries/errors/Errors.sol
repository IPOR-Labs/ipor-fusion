// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

library Errors {
    error WrongAddress();
    error WrongValue();
    error UnsupportedBaseCurrencyFromOracle();
    error UnsupportedPriceOracle();
    error WrongArrayLength();
    error WrongCaller(address caller);
}
