// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IConnector {
    function enter(bytes calldata data) external returns (uint256 executionStatus);
    function exit(bytes calldata data) external returns (uint256 executionStatus);
}