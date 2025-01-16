// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface MErc20 {
    function mint(uint256 mintAmount) external returns (uint256);
    function underlying() external view returns (address);
    function balanceOfUnderlying(address account) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
    function borrowBalanceStored(address account) external returns (uint256);
    function balanceOf(address account) external returns (uint256);
}
