// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address owner) external view returns (uint256);
}
