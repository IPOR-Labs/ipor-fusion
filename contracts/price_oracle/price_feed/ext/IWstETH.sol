// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IWstETH {
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
}
