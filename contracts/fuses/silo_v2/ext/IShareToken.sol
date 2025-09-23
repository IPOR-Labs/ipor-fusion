// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IShareToken {

   /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);
}