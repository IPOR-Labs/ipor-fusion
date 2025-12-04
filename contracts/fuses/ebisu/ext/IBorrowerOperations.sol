// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IBorrowerOperations {
    function activePool() external view returns (address);
}
