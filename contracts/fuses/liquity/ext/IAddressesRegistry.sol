// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAddressesRegistry {
    function stabilityPool() external returns (address);

    function collToken() external returns (address);

    function priceFeed() external returns (address);

    function boldToken() external returns (address);
}
