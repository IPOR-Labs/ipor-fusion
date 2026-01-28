// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockDexActionEthereum is Test {
    using SafeERC20 for ERC20;

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function returnExtra1000Usdc(address executor) external {
        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(address(this), 1_000e6);
        ERC20(USDC).transfer(executor, 1_000e6);
    }

    function returnExtra1000Usdt(address executor) external {
        // USDT: deal() fails due to stdStorage slot detection issue with proxy storage layout.
        // Write directly to balances mapping (slot 2) in TetherToken contract.
        vm.store(USDT, keccak256(abi.encode(address(this), uint256(2))), bytes32(uint256(1_000e6)));
        ERC20(USDT).safeTransfer(executor, 1_000e6);
    }

    function returnExtra500Usdt(address executor) external {
        // USDT: deal() fails due to stdStorage slot detection issue with proxy storage layout.
        // Write directly to balances mapping (slot 2) in TetherToken contract.
        vm.store(USDT, keccak256(abi.encode(address(this), uint256(2))), bytes32(uint256(1_000e6)));
        ERC20(USDT).safeTransfer(executor, 500e6);
    }
}
