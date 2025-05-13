// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquityBalanceFuse} from "../../../contracts/fuses/liquity/ethereum/LiquityBalanceFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract LiquityBalanceFuseTest is Test {
    struct Asset {
        address token;
        string name;
    }
    Asset[3] private assets;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22375819);
        assets[0] = Asset({
            token: address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // WETH
            name: "WETH"
        });
        assets[1] = Asset({
            token: address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0), // WSTETH
            name: "WSTETH"
        });
        assets[2] = Asset({
            token: address(0xae78736Cd615f374D3085123A210448E74Fc6393), // rETH
            name: "rETH"
        });
    }

    function testLiquityBalance() external {
        LiquityBalanceFuse liquityBalanceFuse = new LiquityBalanceFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(0x0), address(liquityBalanceFuse));

        uint256 initialAmount = 1000 * 1e18;
        address[] memory tokens = new address[](3);
        tokens[0] = assets[0].token;
        tokens[1] = assets[1].token;
        tokens[2] = assets[2].token;
        deal(tokens[0], address(vaultMock), initialAmount);
        deal(tokens[1], address(vaultMock), initialAmount);
        deal(tokens[2], address(vaultMock), initialAmount);

        vaultMock.updateMarketConfiguration(1, tokens);

        uint256 balanceBefore = vaultMock.balanceOf();

        deal(tokens[0], address(vaultMock), initialAmount + 1);
        uint256 balanceAfter = vaultMock.balanceOf();

        assertTrue(balanceAfter > balanceBefore, "Balance should be greater");
    }
}
