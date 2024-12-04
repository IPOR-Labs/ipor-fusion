// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
    function getPriceOracle() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}
