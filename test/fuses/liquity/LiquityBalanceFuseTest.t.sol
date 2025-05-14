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
    address[] private registries;

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
        registries = new address[](3);
        registries[0] = address(0x38e1F07b954cFaB7239D7acab49997FBaAD96476); // ETH_REGISTRY
        registries[1] = address(0x2D4ef56cb626E9a4C90c156018BA9CE269573c61); // WSTETH_REGISTRY
        registries[2] = address(0x3b48169809DD827F22C9e0F2d71ff12Ea7A94a2F); // RETH_REGISTRY
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

        vaultMock.updateMarketConfiguration(1, registries);

        uint256 balanceBefore = vaultMock.balanceOf();

        deal(tokens[0], address(vaultMock), initialAmount + 1);
        uint256 balanceAfter = vaultMock.balanceOf();

        assertTrue(balanceAfter > balanceBefore, "Balance should be greater");
    }
}
