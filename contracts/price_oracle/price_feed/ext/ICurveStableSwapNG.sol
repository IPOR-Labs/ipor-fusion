// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.26;

interface ICurveStableSwapNG {
    function totalSupply() external view returns (uint256);
    function N_COINS() external view returns (uint256);
    function balances(uint256) external view returns (uint256);
    function decimals() external view returns (uint256);
    function coins(uint256) external view returns (address);
}
