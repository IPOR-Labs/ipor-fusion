// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TestBase} from "forge-std/Base.sol";
import {console2} from "forge-std/Test.sol";
import {TestStorage} from "./TestStorage.sol";

abstract contract TestAccountSetup is TestBase, TestStorage {
    function initAccount() public {
        console2.log("initUsers inside UserSetup");
        console2.log("asset: ", asset);
        address[] memory _accounts = new address[](5);
        for (uint256 i; i < 5; i++) {
            console2.log("initUsers inside UserSetup loop: ", i);
            _accounts[i] = vm.rememberKey(i + 1000);
            console2.log("_accounts[i]: ", _accounts[i]);
            console2.log("ERC20(asset).decimals(): ", ERC20(asset).decimals());
            dealAssets(_accounts[i], 100_000 * 10 ** ERC20(asset).decimals());
        }
        alpha = vm.rememberKey(1011);
        accounts = _accounts;
    }

    function initApprove() public {
        console2.log("initApprove inside UserSetup");
        for (uint256 i; i < 5; i++) {
            ERC20(asset).approve(plasmaVault, type(uint256).max);
        }
    }

    function dealAssets(address account_, uint256 amount_) public virtual;
}
