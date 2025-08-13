// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256 wstETHAmount);

    function unwrap(uint256 _wstETHAmount) external returns (uint256 stETHAmount);
}
