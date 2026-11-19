// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IVault} from "ethereum-vault-connector/src/interfaces/IVault.sol";
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

/// @title EulerV2BatchSubAccountRolesForkTest
/// @notice Fork test (IL-9243): EulerV2BatchFuse on sub-account 0x01 against the real EVC and EVK vaults.
///         Pins who pays, who receives and who owns the shares for deposit, borrow, repay, repayWithShares, withdraw
///         and disableController, and the receiver/owner validation of borrow and withdraw.
contract EulerV2BatchSubAccountRolesForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22: borrow vault (USDC); eUSDC-2 (USDC) is in its LTV list and serves as collateral
    address private constant _BORROW_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address private constant _COLLATERAL_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    bytes1 private constant _SUB = bytes1(0x01);
    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485837;
    bytes4 private immutable _INVALID_PERMISSIONS = EulerV2BatchFuse.EulerV2BatchFuseInvalidVaultPermissions.selector;

    EulerV2BatchFuse private _batchFuse;
    EulerV2CollateralFuse private _collateralFuse;
    address private _plasmaVault;
    address private _sub;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchRoles",
            "EULERV2BATCHROLES",
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

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _BORROW_VAULT, isCollateral: true, canBorrow: true, subAccounts: _SUB})
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

        deal(_USDC, _plasmaVault, 100_000e6);
    }

    /// @notice Full lifecycle on sub-account 0x01 with the exact asset, share and debt deltas of every step
    function testShouldRunDepositBorrowRepayWithdrawLifecycleOnSubAccountOne() public {
        // 1) collateral deposit on behalf of the vault (payer), shares credited to the sub-account; controller enabled
        uint256 collateralDeposit = 20_000e6;
        uint256 vaultUsdc = _usdc(_plasmaVault);

        _enableCollateralAndController(collateralDeposit);

        assertEq(_usdc(_plasmaVault), vaultUsdc - collateralDeposit, "deposit: vault USDC paid");
        uint256 collateralShares = IERC4626(_COLLATERAL_VAULT).balanceOf(_sub);
        assertGt(collateralShares, 0, "deposit: sub-account holds the collateral shares");
        assertEq(IERC4626(_COLLATERAL_VAULT).balanceOf(_plasmaVault), 0, "deposit: vault holds no collateral shares");
        assertApproxEqAbs(
            IERC4626(_COLLATERAL_VAULT).convertToAssets(collateralShares),
            collateralDeposit,
            1,
            "deposit: shares are worth the deposit"
        );
        assertTrue(IEVC(_EVC).isControllerEnabled(_sub, _BORROW_VAULT), "controller enabled for the sub-account");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _COLLATERAL_VAULT), 0, "deposit: allowance reset");

        // 2) borrow: receiver is the vault, debt lands on the sub-account
        uint256 borrowAmount = 5_000e6;
        vaultUsdc = _usdc(_plasmaVault);
        _execute(_borrowItem(borrowAmount, _plasmaVault), new address[](0), new address[](0));
        assertEq(_usdc(_plasmaVault), vaultUsdc + borrowAmount, "borrow: vault received the tokens");
        assertEq(_usdc(_sub), 0, "borrow: sub-account holds no tokens");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), borrowAmount, "borrow: debt on the sub-account");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_plasmaVault), 0, "borrow: vault holds no debt");

        // 3) partial repay: paid by the vault, debt of the sub-account reduced
        uint256 repayAmount = 1_000e6;
        vaultUsdc = _usdc(_plasmaVault);
        _execute(_repayItem(repayAmount), _borrowApprovalAssets(), _borrowApprovalVaults());
        assertEq(_usdc(_plasmaVault), vaultUsdc - repayAmount, "repay: vault paid");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), borrowAmount - repayAmount, "repay: debt reduced");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _BORROW_VAULT), 0, "repay: allowance reset");

        // 4) deposit into the borrow vault (shares to the sub-account), then repayWithShares burns the sub-account shares
        uint256 depositAmount = 2_000e6;
        vaultUsdc = _usdc(_plasmaVault);
        _execute(_depositItem(_BORROW_VAULT, depositAmount, _sub), _borrowApprovalAssets(), _borrowApprovalVaults());
        uint256 borrowVaultShares = IERC4626(_BORROW_VAULT).balanceOf(_sub);
        assertEq(_usdc(_plasmaVault), vaultUsdc - depositAmount, "deposit2: vault paid");
        assertGt(borrowVaultShares, 0, "deposit2: sub-account holds the shares");
        assertEq(IERC4626(_BORROW_VAULT).balanceOf(_plasmaVault), 0, "deposit2: vault holds no shares");

        uint256 repayShares = 500e6;
        vaultUsdc = _usdc(_plasmaVault);
        uint256 debtBefore = IBorrowing(_BORROW_VAULT).debtOf(_sub);
        _execute(_repayWithSharesItem(repayShares), new address[](0), new address[](0));
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), debtBefore - repayShares, "repayWithShares: debt reduced");
        assertLt(IERC4626(_BORROW_VAULT).balanceOf(_sub), borrowVaultShares, "repayWithShares: shares burned");
        assertEq(_usdc(_plasmaVault), vaultUsdc, "repayWithShares: vault USDC untouched");

        // 5) withdraw: owner is the sub-account (shares burned), receiver is the vault
        uint256 withdrawAmount = 300e6;
        vaultUsdc = _usdc(_plasmaVault);
        uint256 sharesBefore = IERC4626(_BORROW_VAULT).balanceOf(_sub);
        _execute(_withdrawItem(withdrawAmount, _plasmaVault, _sub), new address[](0), new address[](0));
        assertEq(_usdc(_plasmaVault), vaultUsdc + withdrawAmount, "withdraw: vault received the tokens");
        assertEq(_usdc(_sub), 0, "withdraw: sub-account holds no tokens");
        assertLt(IERC4626(_BORROW_VAULT).balanceOf(_sub), sharesBefore, "withdraw: sub-account shares burned");

        // 6) repay everything, then disable the controller
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
        items[0] = _repayItem(type(uint256).max);
        items[1] = EulerV2BatchItem(_BORROW_VAULT, _SUB, abi.encodeWithSelector(IVault.disableController.selector));
        _executeItems(items, _borrowApprovalAssets(), _borrowApprovalVaults());
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), 0, "repay all: no debt");
        assertFalse(IEVC(_EVC).isControllerEnabled(_sub, _BORROW_VAULT), "disableController: controller removed");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _BORROW_VAULT), 0, "repay all: allowance reset");
    }

    function testShouldRevertWhenBorrowReceiverIsSubAccount() public {
        _enableCollateralAndController(20_000e6);
        uint256 vaultUsdc = _usdc(_plasmaVault);

        vm.expectRevert(abi.encodeWithSelector(_INVALID_PERMISSIONS));
        _execute(_borrowItem(1_000e6, _sub), new address[](0), new address[](0));

        assertEq(_usdc(_plasmaVault), vaultUsdc, "vault USDC unchanged");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), 0, "no debt");
    }

    function testShouldRevertWhenWithdrawReceiverIsSubAccount() public {
        _enableCollateralAndController(20_000e6);
        uint256 shares = IERC4626(_COLLATERAL_VAULT).balanceOf(_sub);

        vm.expectRevert(abi.encodeWithSelector(_INVALID_PERMISSIONS));
        _execute(_withdrawItem(1_000e6, _sub, _sub), new address[](0), new address[](0));

        assertEq(IERC4626(_COLLATERAL_VAULT).balanceOf(_sub), shares, "sub-account shares unchanged");
        assertEq(_usdc(_sub), 0, "sub-account holds no tokens");
    }

    function testShouldRevertWhenWithdrawOwnerIsPlasmaVault() public {
        _enableCollateralAndController(20_000e6);
        uint256 shares = IERC4626(_COLLATERAL_VAULT).balanceOf(_sub);

        vm.expectRevert(abi.encodeWithSelector(_INVALID_PERMISSIONS));
        _execute(_withdrawItem(1_000e6, _plasmaVault, _plasmaVault), new address[](0), new address[](0));

        assertEq(IERC4626(_COLLATERAL_VAULT).balanceOf(_sub), shares, "sub-account shares unchanged");
    }

    function testShouldRevertWhenDepositReceiverIsPlasmaVault() public {
        vm.expectRevert(abi.encodeWithSelector(_INVALID_PERMISSIONS));
        _execute(
            _depositItem(_COLLATERAL_VAULT, 1_000e6, _plasmaVault),
            _collateralApprovalAssets(),
            _collateralApprovalVaults()
        );

        assertEq(IERC4626(_COLLATERAL_VAULT).balanceOf(_plasmaVault), 0, "vault holds no shares");
    }

    // ------------------------------------------------------------------ helpers

    function _usdc(address account_) private view returns (uint256) {
        return IERC20(_USDC).balanceOf(account_);
    }

    function _enableCollateralAndController(uint256 collateralDeposit_) private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
        items[0] = EulerV2BatchItem(
            _EVC,
            _SUB,
            abi.encodeWithSelector(IEVC.enableController.selector, _sub, _BORROW_VAULT)
        );
        items[1] = _depositItem(_COLLATERAL_VAULT, collateralDeposit_, _sub);

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction(
            address(_collateralFuse),
            abi.encodeWithSelector(
                EulerV2CollateralFuse.enter.selector,
                EulerV2CollateralFuseEnterData({eulerVault: _COLLATERAL_VAULT, subAccount: _SUB})
            )
        );
        actions[1] = _batchAction(items, _collateralApprovalAssets(), _collateralApprovalVaults());

        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _execute(EulerV2BatchItem memory item_, address[] memory assets_, address[] memory vaults_) private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = item_;
        _executeItems(items, assets_, vaults_);
    }

    function _executeItems(
        EulerV2BatchItem[] memory items_,
        address[] memory assets_,
        address[] memory vaults_
    ) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _batchAction(items_, assets_, vaults_);
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

    function _depositItem(
        address eulerVault_,
        uint256 amount_,
        address receiver_
    ) private pure returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                eulerVault_,
                _SUB,
                abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, amount_, receiver_)
            );
    }

    function _borrowItem(uint256 amount_, address receiver_) private pure returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                _BORROW_VAULT,
                _SUB,
                abi.encodeWithSelector(IBorrowing.borrow.selector, amount_, receiver_)
            );
    }

    function _repayItem(uint256 amount_) private view returns (EulerV2BatchItem memory) {
        return EulerV2BatchItem(_BORROW_VAULT, _SUB, abi.encodeWithSelector(IBorrowing.repay.selector, amount_, _sub));
    }

    function _repayWithSharesItem(uint256 amount_) private view returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                _BORROW_VAULT,
                _SUB,
                abi.encodeWithSelector(IBorrowing.repayWithShares.selector, amount_, _sub)
            );
    }

    function _withdrawItem(
        uint256 amount_,
        address receiver_,
        address owner_
    ) private view returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                _BORROW_VAULT,
                _SUB,
                abi.encodeWithSelector(ERC4626Upgradeable.withdraw.selector, amount_, receiver_, owner_)
            );
    }

    function _borrowApprovalAssets() private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = _USDC;
    }

    function _borrowApprovalVaults() private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = _BORROW_VAULT;
    }

    function _collateralApprovalAssets() private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = _USDC;
    }

    function _collateralApprovalVaults() private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = _COLLATERAL_VAULT;
    }
}
