// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquityBalanceFuse} from "../../../contracts/fuses/liquity/LiquityBalanceFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IAddressesRegistry} from "../../../contracts/fuses/liquity/ext/IAddressesRegistry.sol";
import {IStabilityPool} from "../../../contracts/fuses/liquity/ext/IStabilityPool.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquityBalanceFuseTest is Test {
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_REGISTRY = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    PlasmaVaultMock private vaultMock;
    LiquityBalanceFuse private liquityBalanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22631293);
        liquityBalanceFuse = new LiquityBalanceFuse(IporFusionMarkets.LIQUITY_V2, ETH_REGISTRY);
        vaultMock = new PlasmaVaultMock(address(0x0), address(liquityBalanceFuse));
    }

    function testShouldUpdateBalanceWhenProvidingAndLiquidatingToLiquity() external {
        // given
        uint256 initialBalance = vaultMock.balanceOf();
        assertEq(initialBalance, 0, "Initial balance should be zero");

        deal(BOLD, address(vaultMock), 1000 ether);
        initialBalance = vaultMock.balanceOf();
        assertEq(initialBalance, 1000 ether, "Balance should be 1000 BOLD after dealing");

        IStabilityPool stabilityPool = IStabilityPool(IAddressesRegistry(ETH_REGISTRY).stabilityPool());
        vm.startPrank(address(vaultMock));
        ERC20(BOLD).approve(address(stabilityPool), 500 ether);
        stabilityPool.provideToSP(500 ether, false);
        vm.stopPrank();

        // when
        uint256 afterDepBalance = vaultMock.balanceOf();
        assertEq(afterDepBalance, initialBalance, "Balance should not change after providing to SP");

        vm.prank(address(stabilityPool.troveManager()));
        stabilityPool.offset(100000000, 100 ether);

        vm.prank(address(vaultMock));
        stabilityPool.provideToSP(1, false);

        // then
        uint256 afterLiquidationBalance = vaultMock.balanceOf();
        assertGt(afterLiquidationBalance, afterDepBalance, "Balance should increase after liquidation");
    }
}
