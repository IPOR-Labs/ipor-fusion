// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IwTAC {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
