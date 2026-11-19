// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
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
import {
    EulerV2CollateralFuse,
    EulerV2CollateralFuseEnterData
} from "../../../contracts/fuses/euler/EulerV2CollateralFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";

/// @title EulerV2BatchEnableControllerAtomicBorrowForkTest
/// @notice Pinning fork test (IL-9684, report L53): the report claims an atomic `[enableController, borrow]` batch
///         always reverts because the batch checks the collateral flag instead of `canBorrow`. The check is fixed on
///         base (IL-9257); this suite replays the report scenario in ONE batch against the real EVC and EVK vaults:
///         a `canBorrow`-only grant passes and borrows, a collateral-only grant reverts with
///         `EulerV2BatchFuseInvalidController`.
contract EulerV2BatchEnableControllerAtomicBorrowForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22: borrow vault (USDC); eUSDC-2 is in its LTV list and serves as collateral
    address private constant _BORROW_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address private constant _COLLATERAL_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    bytes1 private constant _SUB = bytes1(0x01);
    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485860;
    uint256 private constant _COLLATERAL_DEPOSIT = 20_000e6;
    uint256 private constant _BORROW_AMOUNT = 5_000e6;

    EulerV2BatchFuse private _batchFuse;
    EulerV2CollateralFuse private _collateralFuse;
    address private _plasmaVault;
    address private _sub;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchAtomicBorrow",
            "EULERV2BATCHATOMIC",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;
        _sub = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB);

        _batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, _EVC);
        _collateralFuse = new EulerV2CollateralFuse(IporFusionMarkets.EULER_V2, _EVC);

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

        deal(_USDC, _plasmaVault, 100_000e6);
    }

    /// @notice Grant with `canBorrow` only (no collateral flag): one batch [enableController, borrow] passes
    function testShouldEnableControllerAndBorrowInOneBatchForBorrowOnlyGrant() public {
        _grant(false, true);
        _depositCollateral();
        uint256 vaultUsdc = _usdc(_plasmaVault);
        assertFalse(IEVC(_EVC).isControllerEnabled(_sub, _BORROW_VAULT), "controller not enabled before the batch");

        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
        items[0] = _enableControllerItem();
        items[1] = EulerV2BatchItem(
            _BORROW_VAULT,
            _SUB,
            abi.encodeWithSelector(IBorrowing.borrow.selector, _BORROW_AMOUNT, _plasmaVault)
        );
        _execute(items);

        assertTrue(IEVC(_EVC).isControllerEnabled(_sub, _BORROW_VAULT), "controller enabled by the batch");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), _BORROW_AMOUNT, "debt on the sub-account");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_plasmaVault), 0, "vault holds no debt");
        assertEq(_usdc(_plasmaVault), vaultUsdc + _BORROW_AMOUNT, "borrowed tokens on the vault");
        assertEq(_usdc(_sub), 0, "sub-account holds no tokens");
    }

    /// @notice Grant with the collateral flag only: the same batch reverts on the controller check, nothing moves
    function testShouldRevertSameBatchForCollateralOnlyGrant() public {
        _grant(true, false);
        _depositCollateral();
        uint256 vaultUsdc = _usdc(_plasmaVault);

        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
        items[0] = _enableControllerItem();
        items[1] = EulerV2BatchItem(
            _BORROW_VAULT,
            _SUB,
            abi.encodeWithSelector(IBorrowing.borrow.selector, _BORROW_AMOUNT, _plasmaVault)
        );

        vm.expectRevert(
            abi.encodeWithSelector(EulerV2BatchFuse.EulerV2BatchFuseInvalidController.selector, _sub, _BORROW_VAULT)
        );
        _execute(items);

        assertFalse(IEVC(_EVC).isControllerEnabled(_sub, _BORROW_VAULT), "no controller enabled");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), 0, "no debt");
        assertEq(_usdc(_plasmaVault), vaultUsdc, "vault USDC unchanged");
    }

    // ------------------------------------------------------------------ helpers

    function _usdc(address account_) private view returns (uint256) {
        return IERC20(_USDC).balanceOf(account_);
    }

    /// @dev Grants the collateral vault as collateral and the borrow vault with the given flags
    function _grant(bool borrowVaultIsCollateral_, bool borrowVaultCanBorrow_) private {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _BORROW_VAULT,
                isCollateral: borrowVaultIsCollateral_,
                canBorrow: borrowVaultCanBorrow_,
                subAccounts: _SUB
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _COLLATERAL_VAULT, isCollateral: true, canBorrow: false, subAccounts: _SUB})
        );
        address[] memory fuses = new address[](2);
        fuses[0] = address(_batchFuse);
        fuses[1] = address(_collateralFuse);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.EULER_V2, _BALANCE_FUSE_EULERV2);
        vm.stopPrank();
    }

    /// @dev Enables the collateral vault on the sub-account and deposits collateral (shares to the sub-account)
    function _depositCollateral() private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            _COLLATERAL_VAULT,
            _SUB,
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _COLLATERAL_DEPOSIT, _sub)
        );

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction(
            address(_collateralFuse),
            abi.encodeWithSelector(
                EulerV2CollateralFuse.enter.selector,
                EulerV2CollateralFuseEnterData({eulerVault: _COLLATERAL_VAULT, subAccount: _SUB})
            )
        );
        actions[1] = _batchAction(items, _approvalAssets(), _collateralVaults());
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        assertGt(IERC4626(_COLLATERAL_VAULT).balanceOf(_sub), 0, "sub-account holds the collateral shares");
    }

    function _enableControllerItem() private view returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(_EVC, _SUB, abi.encodeWithSelector(IEVC.enableController.selector, _sub, _BORROW_VAULT));
    }

    function _execute(EulerV2BatchItem[] memory items_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _batchAction(items_, new address[](0), new address[](0));
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _batchAction(
        EulerV2BatchItem[] memory items_,
        address[] memory assets_,
        address[] memory vaults_
    ) private view returns (FuseAction memory) {
        return
            FuseAction(
                address(_batchFuse),
                abi.encodeWithSelector(
                    EulerV2BatchFuse.enter.selector,
                    EulerV2BatchFuseData({
                        batchItems: items_,
                        assetsForApprovals: assets_,
                        eulerVaultsForApprovals: vaults_
                    })
                )
            );
    }

    function _approvalAssets() private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = _USDC;
    }

    function _collateralVaults() private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = _COLLATERAL_VAULT;
    }
}
