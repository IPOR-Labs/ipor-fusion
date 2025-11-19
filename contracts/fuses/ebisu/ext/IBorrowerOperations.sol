// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IBorrowerOperations {
    function activePool() external view returns (address);
}
