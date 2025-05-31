// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PriceOracleMiddlewareMock} from "../price_oracle/PriceOracleMiddlewareMock.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {console2} from "forge-std/console2.sol";


contract PlasmaVaultTotalSupplyCapTest is Test {

    address public plasmaVault = 0x29d322DD088e9b9D1416F43188954F08748fafbb;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22376009);
       
    }

    function testShouldPrintTotalSupplyCap() public {
        PlasmaVault vault = PlasmaVault(payable(plasmaVault));
        uint256 totalSupplyCap = PlasmaVaultBase(address(vault)).cap();
        console2.log("Total Supply Cap:", totalSupplyCap);

        uint256 totalSupply = vault.totalSupply();
        console2.log("Total Supply:", totalSupply);

        
    }

    function testShouldDepositWithdrawAndDepositAgain() public {
        PlasmaVault vault = PlasmaVault(payable(plasmaVault));
        address userOne = address(0x777);
        address userTwo = address(0x888);
        uint256 depositAmount = 1_500_000e18; // 1.5 million with 18 decimals

        // Deal DAI to userOne for testing
        deal(vault.asset(), userOne, depositAmount);
        deal(vault.asset(), userTwo, depositAmount);
        // Get initial state
        uint256 initialTotalSupply = vault.totalSupply();
        console2.log("Initial Total Supply:", initialTotalSupply);

        // First deposit
        vm.startPrank(userOne);
        ERC20(vault.asset()).approve(address(vault), depositAmount);
        uint256 sharesReceived = vault.deposit(depositAmount, userOne);
        console2.log("Shares received from first deposit:", sharesReceived);

        // Check total supply after deposit
        uint256 totalSupplyAfterDeposit = vault.totalSupply();
        console2.log("Total Supply after deposit:", totalSupplyAfterDeposit);

        vm.warp(block.timestamp + 1);
        
        // Withdraw everything
        vault.withdraw(vault.maxWithdraw(userOne), userOne, userOne);
        
        // Check total supply after withdrawal
        uint256 totalSupplyAfterWithdraw = vault.totalSupply();
        console2.log("Total Supply after withdrawal:", totalSupplyAfterWithdraw);
        vm.stopPrank();

        // Deposit again
        vm.startPrank(userTwo);
        ERC20(vault.asset()).approve(address(vault), depositAmount);
        uint256 sharesReceivedSecond = vault.deposit(depositAmount, userTwo);
        console2.log("Shares received from second deposit:", sharesReceivedSecond);

        // Final total supply check
        uint256 finalTotalSupply = vault.totalSupply();
        console2.log("Final Total Supply:", finalTotalSupply);
        vm.stopPrank();
    }

}
