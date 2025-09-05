// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAddressesRegistry {
    function MCR() external view returns (uint256);

    function stabilityPool() external view returns (address);

    function collToken() external view returns (address);

    function priceFeed() external view returns (address);

    function boldToken() external view returns (address);
}
