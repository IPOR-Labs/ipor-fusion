// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../contracts/vaults/PlasmaVault.sol";
import "../contracts/managers/fee/FeeManager.sol";
import "../contracts/vaults/PlasmaVaultGovernance.sol";

contract TestsTTTest is Test {
    function setUp() public {
        // Setup would initialize contracts and set initial state
        // For this simple test we'll just create a mock setup
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"));
    }

    function testBasicContextFlow() public {
        PlasmaVault vault = PlasmaVault(0x94D2de617Cf5805233Cc4367a96DEaC53073e695);
        address cbBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

        address user = address(0x27B19813451BcAe3031CaBd40B7587B26eAa7D8a);
        address IporDaoAccount = address(0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569);

        deal(cbBTC, user, 10000e8);

        console2.log(PlasmaVaultGovernance(address(vault)).getManagementFeeData().feeAccount);
        console2.log(PlasmaVaultGovernance(address(vault)).getManagementFeeData().feeInPercentage);
        console2.log(PlasmaVaultGovernance(address(vault)).getManagementFeeData().lastUpdateTimestamp);

        vm.startPrank(user);
        IERC20(cbBTC).approve(address(vault), type(uint256).max);

        console2.log(IERC20(cbBTC).balanceOf(user));

        vault.deposit(90e8, user);

        console2.log("IporDaoAccount balance", vault.balanceOf(IporDaoAccount));
        console2.log("block.timestamp", block.timestamp);

        console2.log("###########################");
        uint256 blockTimestamp = block.timestamp;
        vm.warp(blockTimestamp + 100 days);

        vault.deposit(1e8, user);
        // console2.log(vault.balanceOf(user));
        console2.log("block.timestamp", block.timestamp);
        vm.stopPrank();

        FeeManager(0xfd0d1643f95bb9Ce6D820Cd089Fc0e0Cf7Beb022).initialize();
        FeeManager(0xfd0d1643f95bb9Ce6D820Cd089Fc0e0Cf7Beb022).harvestManagementFee();

        console2.log("IporDaoAccount balance", vault.balanceOf(IporDaoAccount));
    }
}
