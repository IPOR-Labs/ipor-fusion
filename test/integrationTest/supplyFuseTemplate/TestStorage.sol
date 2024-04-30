// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

abstract contract TestStorage is Test {
    address[] public accounts;
    address public asset;
    address public plasmaVault;
    address public priceOracle;
    address public alpha;

    function getOwner() public view returns (address) {
        return accounts[0];
    }

    function initStorage() public {
        setupAsset();
    }

    function setupAsset() public virtual;
}
