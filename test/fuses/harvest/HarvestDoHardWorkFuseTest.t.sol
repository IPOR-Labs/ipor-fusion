// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {HarvestDoHardWorkFuse, HarvestDoHardWorkFuseEnterData} from "../../../contracts/fuses/harvest/HarvestDoHardWorkFuse.sol";
import {IHarvestController} from "../../../contracts/fuses/harvest/ext/IHarvestController.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {FuseAction, PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";

contract HarvestDoHardWorkFuseTest is Test {
    address public constant AUTOPILOT_USDC = 0x0d877Dc7C8Fa3aD980DfDb18B48eC9F8768359C4;
    address public constant HARVEST_USDC = 0xcEa7de485Cf3B69CF3D5f7DFadF9e1df31303988;

    address public constant FUSE_MANAGER = 0x6a74649aCFD7822ae8Fb78463a9f2192752E5Aa2;
    address public constant AUTOPILOT_ALPHA = 0x48d3615d78B152819ea0367adF7b9944e399ac9a;
    address public constant AUTOPILOT_ATOMIST = 0x6a74649aCFD7822ae8Fb78463a9f2192752E5Aa2;
    address public constant CONTROLER_GOVERNANCE = 0x920b1aCb7618B553324aa0F71620226FA2e09870;
    address public constant CONTROLER = 0xF90FF0F7c8Db52bF1bF869F74226eAD125EFa745;

    address public fuse;
    address private _transientStorageSetInputsFuse;

    event HarvestDoHardWorkFuseEnter(address version, address vault, address comptroller);

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 30880244);

        fuse = address(new HarvestDoHardWorkFuse(IporFusionMarkets.HARVEST_HARD_WORK));
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());

        address[] memory fuses = new address[](2);
        fuses[0] = fuse;
        fuses[1] = _transientStorageSetInputsFuse;

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(AUTOPILOT_USDC).addFuses(fuses);
        PlasmaVaultGovernance(AUTOPILOT_USDC).addBalanceFuse(
            IporFusionMarkets.HARVEST_HARD_WORK,
            address(new ZeroBalanceFuse(IporFusionMarkets.HARVEST_HARD_WORK))
        );
        PlasmaVaultGovernance(AUTOPILOT_USDC).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
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

        // when/then - function should execute without reverting
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

    /// @notice Tests performing hard work using transient storage
    /// @dev Verifies that enterTransient() correctly reads vaults from transient storage and performs hard work
    function testShouldHarvestDoHardWorkUsingTransientStorage() public {
        // given
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuse;

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(uint256(1)); // length
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(HARVEST_USDC); // vault address

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(fuse, abi.encodeWithSignature("enterTransient()"));

        // when/then - function should execute without reverting
        vm.startPrank(AUTOPILOT_ALPHA);
        PlasmaVault(AUTOPILOT_USDC).execute(calls);
        vm.stopPrank();
    }

    /// @notice Tests reverting when unsupported vault is provided via transient storage
    /// @dev Verifies that enterTransient() correctly validates vaults and reverts for unsupported vaults
    function testShouldRevertWhenUnsupportedVaultUsingTransientStorage() public {
        // given
        address unsupportedVault = address(0x123);
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuse;

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(uint256(1)); // length
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(unsupportedVault); // unsupported vault address

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(fuse, abi.encodeWithSignature("enterTransient()"));

        // when/then
        vm.expectRevert(abi.encodeWithSelector(HarvestDoHardWorkFuse.UnsupportedVault.selector, unsupportedVault));

        vm.startPrank(AUTOPILOT_ALPHA);
        PlasmaVault(AUTOPILOT_USDC).execute(calls);
        vm.stopPrank();
    }
}
