// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}
