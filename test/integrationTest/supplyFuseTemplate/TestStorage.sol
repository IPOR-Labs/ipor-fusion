// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {FoundryRandom} from "foundry-random/FoundryRandom.sol";

abstract contract TestStorage is Test {
    address[] public accounts;
    address public asset;
    address public plasmaVault;
    address public priceOracle;
    address public alpha;
    address public feeManager;
    FoundryRandom public random;
    address[] public fuses;
    address public accessManager;

    function getOwner() public view returns (address) {
        return accounts[0];
    }

    function initStorage() public {
        setupAsset();
        random = new FoundryRandom();
    }

    function setupAsset() public virtual;
}
