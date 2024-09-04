// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IEVault {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalBorrowsExact() external view returns (uint256);
    function cash() external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function debtOfExact(address account) external view returns (uint256);
    function interestRate() external view returns (uint256);
    function interestAccumulator() external view returns (uint256);
    function dToken() external view returns (address);

    function borrow(uint256 amount, address receiver) external returns (uint256);
    function repay(uint256 amount, address receiver) external returns (uint256);
    function repayWithShares(uint256 amount, address receiver) external returns (uint256 shares, uint256 debt);
    function pullDebt(uint256 amount, address from) external;
    function touch() external;

    // Events
    event PullDebt(address indexed from, address indexed to, uint256 amount);
}
