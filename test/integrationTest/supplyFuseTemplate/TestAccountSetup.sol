// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TestBase} from "forge-std/Base.sol";
import {TestStorage} from "./TestStorage.sol";

abstract contract TestAccountSetup is TestBase, TestStorage {
    function initAccount() public {
        address[] memory _accounts = new address[](5);
        for (uint256 i; i < 5; i++) {
            _accounts[i] = vm.rememberKey(i + 1000);
            dealAssets(_accounts[i], 100_000 * 10 ** ERC20(asset).decimals());
        }
        alpha = vm.rememberKey(1011);
        accounts = _accounts;
        feeManager = vm.rememberKey(1012);
    }

    function initApprove() public {
        for (uint256 i; i < 5; i++) {
            vm.prank(accounts[i]);
            ERC20(asset).approve(plasmaVault, type(uint256).max);
        }
    }

    function dealAssets(address account_, uint256 amount_) public virtual;
}
