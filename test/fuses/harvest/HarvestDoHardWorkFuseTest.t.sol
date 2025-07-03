// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HarvestDoHardWorkFuse, HarvestDoHardWorkFuseEnterData} from "../../../contracts/fuses/harvest/HarvestDoHardWorkFuse.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {FuseAction, PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IHarvestController} from "../../../contracts/fuses/harvest/ext/IHarvestController.sol";

contract HarvestDoHardWorkFuseTest is Test {
    address public constant AUTOPILOT_USDC = 0x0d877Dc7C8Fa3aD980DfDb18B48eC9F8768359C4;
    address public constant HARVEST_USDC = 0xcEa7de485Cf3B69CF3D5f7DFadF9e1df31303988;

    address public constant FUSE_MANAGER = 0x6a74649aCFD7822ae8Fb78463a9f2192752E5Aa2;
    address public constant AUTOPILOT_ALPHA = 0x48d3615d78B152819ea0367adF7b9944e399ac9a;
    address public constant AUTOPILOT_ATOMIST = 0x6a74649aCFD7822ae8Fb78463a9f2192752E5Aa2;
    address public constant CONTROLER_GOVERNANCE = 0x920b1aCb7618B553324aa0F71620226FA2e09870;
    address public constant CONTROLER = 0xF90FF0F7c8Db52bF1bF869F74226eAD125EFa745;

    address public fuse;

    event HarvestDoHardWorkFuseEnter(address version, address vault, address comptroller);

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 30880244);

        fuse = address(new HarvestDoHardWorkFuse(IporFusionMarkets.HARVEST_HARD_WORK));

        address[] memory fuses = new address[](1);
        fuses[0] = fuse;

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(AUTOPILOT_USDC).addFuses(fuses);
        PlasmaVaultGovernance(AUTOPILOT_USDC).addBalanceFuse(
            IporFusionMarkets.HARVEST_HARD_WORK,
            address(new ZeroBalanceFuse(IporFusionMarkets.HARVEST_HARD_WORK))
        );
        vm.stopPrank();

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(HARVEST_USDC);

        vm.startPrank(AUTOPILOT_ATOMIST);
        PlasmaVaultGovernance(AUTOPILOT_USDC).grantMarketSubstrates(IporFusionMarkets.HARVEST_HARD_WORK, substrates);
        vm.stopPrank();

        vm.startPrank(CONTROLER_GOVERNANCE);
        IHarvestController(CONTROLER).addHardWorker(AUTOPILOT_USDC);
        vm.stopPrank();
    }

    function testShouldHarvestDoHardWork() public {
        // given
        address[] memory vaults = new address[](1);
        vaults[0] = HARVEST_USDC;
        HarvestDoHardWorkFuseEnterData memory enterData = HarvestDoHardWorkFuseEnterData({vaults: vaults});

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSignature("enter((address[]))", enterData));

        vm.expectEmit(true, true, true, true);
        emit HarvestDoHardWorkFuseEnter(fuse, HARVEST_USDC, CONTROLER);

        // when/then
        vm.startPrank(AUTOPILOT_ALPHA);
        PlasmaVault(AUTOPILOT_USDC).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenUnsupportedVault() public {
        // given
        address unsupportedVault = address(0x123);
        address[] memory vaults = new address[](1);
        vaults[0] = unsupportedVault;
        HarvestDoHardWorkFuseEnterData memory enterData = HarvestDoHardWorkFuseEnterData({vaults: vaults});

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSignature("enter((address[]))", enterData));

        // when/then
        vm.expectRevert(abi.encodeWithSelector(HarvestDoHardWorkFuse.UnsupportedVault.selector, unsupportedVault));

        vm.startPrank(AUTOPILOT_ALPHA);
        PlasmaVault(AUTOPILOT_USDC).execute(enterCalls);
        vm.stopPrank();
    }
}
