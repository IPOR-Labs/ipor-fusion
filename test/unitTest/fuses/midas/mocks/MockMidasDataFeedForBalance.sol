// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Minimal mock for IMidasDataFeed used in MidasBalanceFuse unit tests.
///         Returns a configurable price from getDataInBase18().
contract MockMidasDataFeedForBalance {
    uint256 private _price;

    function setPrice(uint256 price_) external {
        _price = price_;
    }

    function getDataInBase18() external view returns (uint256) {
        return _price;
    }
}
