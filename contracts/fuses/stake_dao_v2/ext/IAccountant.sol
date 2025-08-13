// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IAccountant {
    function claim(address[] calldata _gauges, bytes[] calldata harvestData, address receiver) external;
}
