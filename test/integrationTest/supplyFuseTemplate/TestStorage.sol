// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @dev forge-std v1.8.0 does not expose `randomUint` yet, but the cheatcode is supported by forge itself
interface VmRandom {
    function randomUint(uint256 min, uint256 max) external returns (uint256);
}

abstract contract TestStorage is Test {
    address[] public accounts;
    address public asset;
    address public plasmaVault;
    address public priceOracle;
    address public alpha;
    address public feeManager;
    address[] public fuses;
    address public accessManager;

    function getOwner() public view returns (address) {
        return accounts[0];
    }

    function initStorage() public {
        setupAsset();
    }

    function setupAsset() public virtual;

    function randomNumber(uint256 minVal, uint256 maxVal) internal returns (uint256) {
        return VmRandom(address(vm)).randomUint(minVal, maxVal);
    }

    function randomNumber(uint256 maxVal) internal returns (uint256) {
        return VmRandom(address(vm)).randomUint(0, maxVal);
    }
}
