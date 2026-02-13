// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PauseFunctionPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/PauseFunctionPreHook.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";

/**
 * @title Balance Fuses Reader Test
 * @notice Tests for reading balance fuses data from PlasmaVault
 * @dev Tests reading market IDs and fuse addresses from a specific PlasmaVault on Ethereum mainnet
 */
contract PauseFunctionPreHookTest is Test {
    PauseFunctionPreHook public preHook;
    address public user = TestAddresses.USER;
    address public constant PLASMA_VAULT = 0xa121d23cECD8050082d13a1FC062598c5449dBE9;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant ATOMIST = 0x1F75844A2905eba5Dd8898fb8A289967b0AB2a29;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 27849076);

        // Deploy BalanceFusesReader
        preHook = new PauseFunctionPreHook();

        deal(WETH, user, 1000 ether);
    }

    function testShouldPauseFunction() public {
        // given
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);

        vm.startPrank(user);
        IERC20(WETH).approve(PLASMA_VAULT, 10000 ether);
        PlasmaVault(PLASMA_VAULT).deposit(1 ether, user);
        vm.stopPrank();

        uint256 balanceBefore = IERC20(PLASMA_VAULT).balanceOf(user);

        // when
        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).setPreHookImplementations(selectors, preHooks, substrates);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(PauseFunctionPreHook.FunctionPaused.selector, PlasmaVault.deposit.selector)
        );
        PlasmaVault(PLASMA_VAULT).deposit(1 ether, user);
        vm.stopPrank();

        // then
        assertEq(balanceBefore, 1 ether * 100);
        assertEq(IERC20(PLASMA_VAULT).balanceOf(user), balanceBefore, "Balance should not change");
    }
}
