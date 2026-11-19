// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
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
import {
    EulerV2BorrowFuse,
    EulerV2BorrowFuseEnterData,
    EulerV2BorrowFuseExitData
} from "../../../contracts/fuses/euler/EulerV2BorrowFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";

/// @title EulerV2RepayWithoutCanBorrowForkTest
/// @notice Fork test (IL-9271, IL-9276): a position must stay repayable after the `canBorrow` flag of its borrow vault
///         was revoked. Repaying through EulerV2BorrowFuse.exit and through an EulerV2BatchFuse repay item only
///         requires the granted (vault, sub-account) entry. With the entry removed both paths revert: the entry
///         check protects the `max` approval that BorrowFuse.exit gives to the vault.
contract EulerV2RepayWithoutCanBorrowForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22: borrow vault (USDC); eUSDC-2 (USDC) is in its LTV list and serves as collateral
    address private constant _BORROW_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address private constant _COLLATERAL_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    bytes1 private constant _SUB = bytes1(0x01);
    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485843;
    bytes4 private immutable _INVALID_PERMISSIONS = EulerV2BatchFuse.EulerV2BatchFuseInvalidVaultPermissions.selector;
    bytes4 private immutable _UNSUPPORTED_ENTER_ACTION =
        EulerV2BorrowFuse.EulerV2BorrowFuseUnsupportedEnterAction.selector;
    bytes4 private immutable _UNSUPPORTED_EXIT_ACTION =
        EulerV2BorrowFuse.EulerV2BorrowFuseUnsupportedExitAction.selector;

    EulerV2BatchFuse private _batchFuse;
    EulerV2CollateralFuse private _collateralFuse;
    EulerV2BorrowFuse private _borrowFuse;
    address private _plasmaVault;
    address private _sub;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2RepayNoCanBorrow",
            "EULERV2REPAYNOCANBORROW",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;
        _sub = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB);

        _batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, _EVC);
        _collateralFuse = new EulerV2CollateralFuse(IporFusionMarkets.EULER_V2, _EVC);
        _borrowFuse = new EulerV2BorrowFuse(IporFusionMarkets.EULER_V2, _EVC);

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

        address[] memory fuses = new address[](3);
        fuses[0] = address(_batchFuse);
        fuses[1] = address(_collateralFuse);
        fuses[2] = address(_borrowFuse);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, _substrates(true, true));
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.EULER_V2, _BALANCE_FUSE_EULERV2);
        vm.stopPrank();

        deal(_USDC, _plasmaVault, 100_000e6);

        _openPosition();
    }

    function testShouldRepayWithBorrowFuseAfterCanBorrowRevoked() public {
        _grantSubstrates(true, false);
        uint256 debtBefore = IBorrowing(_BORROW_VAULT).debtOf(_sub);
        uint256 vaultUsdc = _usdc(_plasmaVault);

        // control: with the flag revoked a new borrow is refused
        vm.expectRevert(abi.encodeWithSelector(_UNSUPPORTED_ENTER_ACTION, _BORROW_VAULT, _SUB));
        _executeBorrowEnter(1_000e6);

        _executeBorrowExit(1_000e6);

        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), debtBefore - 1_000e6, "debt reduced by the repayment");
        assertEq(_usdc(_plasmaVault), vaultUsdc - 1_000e6, "vault paid the repayment");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _BORROW_VAULT), 0, "allowance reset");
    }

    function testShouldRepayInBatchAfterCanBorrowRevoked() public {
        _grantSubstrates(true, false);
        uint256 debtBefore = IBorrowing(_BORROW_VAULT).debtOf(_sub);
        uint256 vaultUsdc = _usdc(_plasmaVault);

        _executeBatchRepay(1_000e6);

        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), debtBefore - 1_000e6, "debt reduced by the repayment");
        assertEq(_usdc(_plasmaVault), vaultUsdc - 1_000e6, "vault paid the repayment");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _BORROW_VAULT), 0, "allowance reset");
    }

    function testShouldRevertBorrowFuseExitWhenEntryRemoved() public {
        _removeBorrowVaultEntry();
        uint256 debtBefore = IBorrowing(_BORROW_VAULT).debtOf(_sub);

        vm.expectRevert(abi.encodeWithSelector(_UNSUPPORTED_EXIT_ACTION, _BORROW_VAULT, _SUB));
        _executeBorrowExit(1_000e6);

        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), debtBefore, "debt unchanged");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _BORROW_VAULT), 0, "no allowance given");
    }

    function testShouldRevertBatchRepayWhenEntryRemoved() public {
        _removeBorrowVaultEntry();
        uint256 debtBefore = IBorrowing(_BORROW_VAULT).debtOf(_sub);

        vm.expectRevert(abi.encodeWithSelector(_INVALID_PERMISSIONS));
        _executeBatchRepayWithoutApprovals(1_000e6);

        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), debtBefore, "debt unchanged");
    }

    function testShouldRepayWithSharesInBatchAfterCanBorrowRevoked() public {
        _grantSubstrates(true, false);
        _executeBatchDepositToSubAccount(2_000e6);
        uint256 debtBefore = IBorrowing(_BORROW_VAULT).debtOf(_sub);
        uint256 sharesBefore = IERC20(_BORROW_VAULT).balanceOf(_sub);
        uint256 vaultUsdc = _usdc(_plasmaVault);
        assertGt(sharesBefore, 0, "sub-account holds borrow vault shares");

        _executeBatchRepayWithShares(1_000e6);

        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), debtBefore - 1_000e6, "debt reduced by the repayment");
        assertLt(IERC20(_BORROW_VAULT).balanceOf(_sub), sharesBefore, "sub-account shares burned");
        assertEq(_usdc(_plasmaVault), vaultUsdc, "vault USDC untouched by repayWithShares");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _BORROW_VAULT), 0, "no allowance given");
    }

    function testShouldRevertBatchRepayWithSharesWhenEntryRemoved() public {
        _grantSubstrates(true, false);
        _executeBatchDepositToSubAccount(2_000e6);
        _removeBorrowVaultEntry();
        uint256 debtBefore = IBorrowing(_BORROW_VAULT).debtOf(_sub);
        uint256 sharesBefore = IERC20(_BORROW_VAULT).balanceOf(_sub);

        vm.expectRevert(abi.encodeWithSelector(_INVALID_PERMISSIONS));
        _executeBatchRepayWithShares(1_000e6);

        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), debtBefore, "debt unchanged");
        assertEq(IERC20(_BORROW_VAULT).balanceOf(_sub), sharesBefore, "sub-account shares unchanged");
    }

    // ------------------------------------------------------------------ helpers

    function _usdc(address account_) private view returns (uint256) {
        return IERC20(_USDC).balanceOf(account_);
    }

    function _substrates(
        bool borrowVaultCollateral_,
        bool borrowVaultCanBorrow_
    ) private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _BORROW_VAULT,
                isCollateral: borrowVaultCollateral_,
                canBorrow: borrowVaultCanBorrow_,
                subAccounts: _SUB
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _COLLATERAL_VAULT, isCollateral: true, canBorrow: false, subAccounts: _SUB})
        );
    }

    function _grantSubstrates(bool borrowVaultCollateral_, bool borrowVaultCanBorrow_) private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.EULER_V2,
            _substrates(borrowVaultCollateral_, borrowVaultCanBorrow_)
        );
    }

    /// @dev Grants only the collateral vault: the (borrow vault, sub-account) entry is gone
    function _removeBorrowVaultEntry() private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _COLLATERAL_VAULT, isCollateral: true, canBorrow: false, subAccounts: _SUB})
        );
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
    }

    /// @dev Collateral deposit, controller enabled on the borrow vault, 5 000 USDC borrowed on sub-account 0x01
    function _openPosition() private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
        items[0] = EulerV2BatchItem(
            _EVC,
            _SUB,
            abi.encodeWithSelector(IEVC.enableController.selector, _sub, _BORROW_VAULT)
        );
        items[1] = EulerV2BatchItem(
            _COLLATERAL_VAULT,
            _SUB,
            abi.encodeWithSelector(bytes4(keccak256("deposit(uint256,address)")), 20_000e6, _sub)
        );
        address[] memory assets = new address[](1);
        assets[0] = _USDC;
        address[] memory vaults = new address[](1);
        vaults[0] = _COLLATERAL_VAULT;

        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = FuseAction(
            address(_collateralFuse),
            abi.encodeWithSelector(
                EulerV2CollateralFuse.enter.selector,
                EulerV2CollateralFuseEnterData({eulerVault: _COLLATERAL_VAULT, subAccount: _SUB})
            )
        );
        actions[1] = _batchAction(items, assets, vaults);
        actions[2] = FuseAction(
            address(_borrowFuse),
            abi.encodeWithSelector(
                EulerV2BorrowFuse.enter.selector,
                EulerV2BorrowFuseEnterData({eulerVault: _BORROW_VAULT, assetAmount: 5_000e6, subAccount: _SUB})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_sub), 5_000e6, "position opened: debt on the sub-account");
    }

    function _executeBorrowEnter(uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_borrowFuse),
            abi.encodeWithSelector(
                EulerV2BorrowFuse.enter.selector,
                EulerV2BorrowFuseEnterData({eulerVault: _BORROW_VAULT, assetAmount: amount_, subAccount: _SUB})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _executeBorrowExit(uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_borrowFuse),
            abi.encodeWithSelector(
                EulerV2BorrowFuse.exit.selector,
                EulerV2BorrowFuseExitData({eulerVault: _BORROW_VAULT, maxAssetAmount: amount_, subAccount: _SUB})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @dev Repay item without declared approvals, so the validation reaches the repay permission check itself
    function _executeBatchRepayWithoutApprovals(uint256 amount_) private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            _BORROW_VAULT,
            _SUB,
            abi.encodeWithSelector(IBorrowing.repay.selector, amount_, _sub)
        );
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _batchAction(items, new address[](0), new address[](0));
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _executeBatchRepay(uint256 amount_) private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            _BORROW_VAULT,
            _SUB,
            abi.encodeWithSelector(IBorrowing.repay.selector, amount_, _sub)
        );
        address[] memory assets = new address[](1);
        assets[0] = _USDC;
        address[] memory vaults = new address[](1);
        vaults[0] = _BORROW_VAULT;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _batchAction(items, assets, vaults);
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @dev Deposits USDC from the Plasma Vault into the borrow vault, the shares go to the sub-account
    function _executeBatchDepositToSubAccount(uint256 amount_) private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            _BORROW_VAULT,
            _SUB,
            abi.encodeWithSelector(bytes4(keccak256("deposit(uint256,address)")), amount_, _sub)
        );
        address[] memory assets = new address[](1);
        assets[0] = _USDC;
        address[] memory vaults = new address[](1);
        vaults[0] = _BORROW_VAULT;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _batchAction(items, assets, vaults);
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @dev repayWithShares item without approvals: the sub-account burns its own shares
    function _executeBatchRepayWithShares(uint256 amount_) private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            _BORROW_VAULT,
            _SUB,
            abi.encodeWithSelector(IBorrowing.repayWithShares.selector, amount_, _sub)
        );
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _batchAction(items, new address[](0), new address[](0));
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
}
