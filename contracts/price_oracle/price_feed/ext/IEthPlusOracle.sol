// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.30;

interface IEthPlusOracle {
    function price() external view returns (uint256, uint256);
}
