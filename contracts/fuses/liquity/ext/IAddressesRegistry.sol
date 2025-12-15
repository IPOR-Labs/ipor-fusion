// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAddressesRegistry {
    function stabilityPool() external view returns (address);

    function collToken() external view returns (address);

    function priceFeed() external view returns (address);

    function boldToken() external view returns (address);
}
