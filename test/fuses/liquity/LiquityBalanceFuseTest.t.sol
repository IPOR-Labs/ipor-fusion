// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquityBalanceFuse} from "../../../contracts/fuses/chains/ethereum/liquity/LiquityBalanceFuse.sol";
import {LiquityStabilityPoolFuse} from "../../../contracts/fuses/chains/ethereum/liquity/LiquityStabilityPoolFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {IAddressesRegistry} from "../../../contracts/fuses/chains/ethereum/liquity/ext/IAddressesRegistry.sol";
import {IStabilityPool} from "../../../contracts/fuses/chains/ethereum/liquity/ext/IStabilityPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquityBalanceFuseTest is Test {
    struct Asset {
        address token;
        string name;
    }

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

    function testLiquityBalance() external {
        uint256 initialBalance = vaultMock.balanceOf();
        assertEq(initialBalance, 0, "Initial balance should be zero");

        // deal BOLD to the vault
        deal(BOLD, address(vaultMock), 1000 ether);
        initialBalance = vaultMock.balanceOf();
        assertEq(initialBalance, 1000 ether, "Balance should be 1000 BOLD after dealing");

        // provide BOLD to the stability pool
        IStabilityPool stabilityPool = IStabilityPool(IAddressesRegistry(ETH_REGISTRY).stabilityPool());
        vm.startPrank(address(vaultMock));
        ERC20(BOLD).approve(address(stabilityPool), 500 ether);
        stabilityPool.provideToSP(500 ether, false);
        vm.stopPrank();

        // check the balance after providing to the stability pool: it should not change
        uint256 afterDepBalance = vaultMock.balanceOf();
        assertEq(afterDepBalance, initialBalance, "Balance should not change after providing to SP");

        // simulate liquidation
        vm.prank(address(stabilityPool.troveManager()));
        stabilityPool.offset(100000000, 100 ether);

        // trigger update
        stabilityPool.provideToSP(1, false);
        // check the balance after liquidation
        uint256 afterLiquidationBalance = vaultMock.balanceOf();
        assertGt(afterLiquidationBalance, afterDepBalance, "Balance should increase after liquidation");
    }
}
