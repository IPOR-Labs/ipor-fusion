// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IPool {

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    function setUserEMode(uint8 categoryId) external;
}