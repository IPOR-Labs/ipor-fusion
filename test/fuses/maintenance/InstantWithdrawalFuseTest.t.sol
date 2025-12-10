// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {ConfigureInstantWithdrawalFuse, ConfigureInstantWithdrawalFuseEnterData} from "../../../contracts/fuses/maintenance/ConfigureInstantWithdrawalFuse.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";

contract InstantWithdrawalFuseTest is Test {
    address public constant FUSION_PLASMA_VAULT = 0x3151cEE0cdb517C0E7Db2B55FF5085e7D1809d90;
    address public constant FUSION_ACCESS_MANAGER = 0xDcf1EC5bfCA5C16D7b656B3af2481B4234Dd2E46;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public constant ATOMIST = 0xC4C3065Bf62A11edF8A6B5252f550adEC82Dd38F;
    address public constant FUSE_MANAGER = 0xC4C3065Bf62A11edF8A6B5252f550adEC82Dd38F;
    address public constant ALPHA = 0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6;
    address public constant USER = 0xc2479e356E96597Cba1c05202FB65bE1d862CD4D;

    uint256 public constant SHARE_AMOUNT = 1005747814032;

    mapping(address => bytes32[]) public fuseParams;
    address public fuseAddress;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23451270);
        ConfigureInstantWithdrawalFuse fuse = new ConfigureInstantWithdrawalFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);
        fuseAddress = address(fuse);

        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).addFuses(fuses);
        vm.stopPrank();
    }

    function testConfigureInstantWithdrawalFuse() public {
        // given

        address[] memory fusesBefore = PlasmaVaultGovernance(FUSION_PLASMA_VAULT).getInstantWithdrawalFuses();

        for (uint256 i; i < fusesBefore.length; i++) {
            bytes32[] memory params = PlasmaVaultGovernance(FUSION_PLASMA_VAULT).getInstantWithdrawalFusesParams(
                fusesBefore[i],
                i
            );
            fuseParams[fusesBefore[i]] = params;
        }

        InstantWithdrawalFusesParamsStruct[] memory fusesParams = new InstantWithdrawalFusesParamsStruct[](
            fusesBefore.length
        );

        for (uint256 i = fusesBefore.length; i > 0; i--) {
            fusesParams[fusesBefore.length - i] = InstantWithdrawalFusesParamsStruct({
                fuse: fusesBefore[i - 1],
                params: fuseParams[fusesBefore[i - 1]]
            });
        }

        ConfigureInstantWithdrawalFuseEnterData memory enterData = ConfigureInstantWithdrawalFuseEnterData({
            fuses: fusesParams
        });

        // Create FuseAction array for execute function
        FuseAction[] memory fuseActions = new FuseAction[](1);
        fuseActions[0] = FuseAction({
            fuse: fuseAddress,
            data: abi.encodeWithSelector(ConfigureInstantWithdrawalFuse.enter.selector, enterData)
        });

        // When
        vm.startPrank(ALPHA);
        PlasmaVault(FUSION_PLASMA_VAULT).execute(fuseActions);
        vm.stopPrank();

        // then
        address[] memory fusesAfter = PlasmaVaultGovernance(FUSION_PLASMA_VAULT).getInstantWithdrawalFuses();

        for (uint256 i; i < fusesAfter.length; i++) {
            assertEq(fusesBefore[i], fusesAfter[fusesAfter.length - i - 1], "fuses not equal");
        }
    }
}
