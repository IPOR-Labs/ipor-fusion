// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IVault} from "ethereum-vault-connector/src/interfaces/IVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {
    EulerV2BatchFuse,
    EulerV2BatchItem,
    EulerV2BatchFuseData
} from "../../../contracts/fuses/euler/EulerV2BatchFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";

/// @title EulerV2BatchEnableControllerForkTest
/// @notice Fork test (IL-9257): batch `enableController` / `disableController` against the real EVC. The controller
///         vault must be granted with `canBorrow`; a collateral-only grant must not allow enabling a controller.
contract EulerV2BatchEnableControllerForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22: granted with canBorrow only (a valid controller)
    address private constant _BORROW_ONLY_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    /// @dev eUSDC-2: granted as collateral only (cannot become a controller)
    address private constant _COLLATERAL_ONLY_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    bytes1 private constant _SUB = bytes1(0x01);
    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485840;

    EulerV2BatchFuse private _batchFuse;
    address private _plasmaVault;
    address private _sub;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchEnableCtrl",
            "EULERV2BATCHENABLECTRL",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;
        _sub = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB);

        _batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, _EVC);

        vm.prank(TestAddresses.OWNER);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, TestAddresses.ATOMIST, 0);
        vm.startPrank(TestAddresses.ATOMIST);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.ALPHA_ROLE, TestAddresses.ALPHA, 0);
        IporFusionAccessManager(instance.accessManager).grantRole(
            Roles.FUSE_MANAGER_ROLE,
            TestAddresses.FUSE_MANAGER,
            0
        );
        vm.stopPrank();

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _BORROW_ONLY_VAULT, isCollateral: false, canBorrow: true, subAccounts: _SUB})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _COLLATERAL_ONLY_VAULT,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB
            })
        );
        address[] memory fuses = new address[](1);
        fuses[0] = address(_batchFuse);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.EULER_V2, _BALANCE_FUSE_EULERV2);
        vm.stopPrank();

        deal(_USDC, _plasmaVault, 100_000e6);
    }

    function testShouldEnableAndDisableControllerForBorrowOnlyGrant() public {
        _execute(_enableControllerItem(_sub, _BORROW_ONLY_VAULT));
        assertTrue(IEVC(_EVC).isControllerEnabled(_sub, _BORROW_ONLY_VAULT), "controller enabled");

        EulerV2BatchItem memory disableItem = EulerV2BatchItem(
            _BORROW_ONLY_VAULT,
            _SUB,
            abi.encodeWithSelector(IVault.disableController.selector)
        );
        _execute(disableItem);
        assertFalse(IEVC(_EVC).isControllerEnabled(_sub, _BORROW_ONLY_VAULT), "controller disabled");
    }

    function testShouldRevertEnableControllerForCollateralOnlyGrant() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2BatchFuse.EulerV2BatchFuseInvalidController.selector,
                _sub,
                _COLLATERAL_ONLY_VAULT
            )
        );
        _execute(_enableControllerItem(_sub, _COLLATERAL_ONLY_VAULT));

        assertFalse(IEVC(_EVC).isControllerEnabled(_sub, _COLLATERAL_ONLY_VAULT), "no controller enabled");
    }

    function testShouldRevertEnableControllerForWrongAccountOnBorrowOnlyGrant() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2BatchFuse.EulerV2BatchFuseInvalidController.selector,
                _plasmaVault,
                _BORROW_ONLY_VAULT
            )
        );
        _execute(_enableControllerItem(_plasmaVault, _BORROW_ONLY_VAULT));

        assertFalse(IEVC(_EVC).isControllerEnabled(_plasmaVault, _BORROW_ONLY_VAULT), "no controller enabled");
    }

    // ------------------------------------------------------------------ helpers

    function _enableControllerItem(address account_, address vault_) private pure returns (EulerV2BatchItem memory) {
        return EulerV2BatchItem(_EVC, _SUB, abi.encodeWithSelector(IEVC.enableController.selector, account_, vault_));
    }

    function _execute(EulerV2BatchItem memory item_) private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = item_;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_batchFuse),
            abi.encodeWithSelector(
                EulerV2BatchFuse.enter.selector,
                EulerV2BatchFuseData({
                    batchItems: items,
                    assetsForApprovals: new address[](0),
                    eulerVaultsForApprovals: new address[](0)
                })
            )
        );
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }
}
