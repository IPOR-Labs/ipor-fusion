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

import {
    TransientStorageSetInputsFuse,
    TransientStorageSetInputsFuseEnterData
} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

/// @title EulerV2BatchSubAccountRolesTransientForkTest
/// @notice Pinning fork test (IL-9678, report L47): the report claims that for a sub-account other than 0 borrow and
///         withdraw pay the sub-account while deposit and repay pull from it. The role binding is fixed on base
///         (IL-9243) and pinned for `enter` by `EulerV2BatchSubAccountRolesForkTest`; this suite replays the full
///         lifecycle deposit -> borrow -> repay -> withdraw through `enterTransient` (inputs set by
///         `TransientStorageSetInputsFuse`) on sub-accounts 0x01 and 0x7f against the real EVC and EVK vaults.
///         Invariant checked after every step: tokens only on the Plasma Vault, shares and debt only on the
///         sub-account, never on the vault or on the other sub-account.
contract EulerV2BatchSubAccountRolesTransientForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22: borrow vault (USDC); eUSDC-2 (USDC) is in its LTV list and serves as collateral
    address private constant _BORROW_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address private constant _COLLATERAL_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485861;

    EulerV2BatchFuse private _batchFuse;
    EulerV2CollateralFuse private _collateralFuse;
    TransientStorageSetInputsFuse private _setInputsFuse;
    address private _plasmaVault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchRolesTr",
            "EULERV2BATCHROLESTR",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;

        _batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, _EVC);
        _collateralFuse = new EulerV2CollateralFuse(IporFusionMarkets.EULER_V2, _EVC);
        _setInputsFuse = new TransientStorageSetInputsFuse();

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

        bytes1[2] memory subs = [bytes1(0x01), bytes1(0x7f)];
        bytes32[] memory substrates = new bytes32[](4);
        for (uint256 i; i < 2; ++i) {
            substrates[2 * i] = EulerFuseLib.substrateToBytes32(
                EulerSubstrate({eulerVault: _BORROW_VAULT, isCollateral: true, canBorrow: true, subAccounts: subs[i]})
            );
            substrates[2 * i + 1] = EulerFuseLib.substrateToBytes32(
                EulerSubstrate({
                    eulerVault: _COLLATERAL_VAULT,
                    isCollateral: true,
                    canBorrow: false,
                    subAccounts: subs[i]
                })
            );
        }
        address[] memory fuses = new address[](3);
        fuses[0] = address(_batchFuse);
        fuses[1] = address(_collateralFuse);
        fuses[2] = address(_setInputsFuse);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.EULER_V2, _BALANCE_FUSE_EULERV2);
        // TransientStorageSetInputsFuse belongs to ERC20_VAULT_BALANCE, which execute refreshes after the actions
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
        vm.stopPrank();

        deal(_USDC, _plasmaVault, 100_000e6);
    }

    function testShouldRunLifecycleThroughEnterTransientOnSubAccountOne() public {
        _runLifecycle(bytes1(0x01), bytes1(0x7f));
    }

    function testShouldRunLifecycleThroughEnterTransientOnSubAccountSevenF() public {
        _runLifecycle(bytes1(0x7f), bytes1(0x01));
    }

    // ------------------------------------------------------------------ lifecycle

    function _runLifecycle(bytes1 subId_, bytes1 otherSubId_) private {
        address sub = EulerFuseLib.generateSubAccountAddress(_plasmaVault, subId_);
        address other = EulerFuseLib.generateSubAccountAddress(_plasmaVault, otherSubId_);
        assertTrue(sub != other && sub != _plasmaVault, "distinct accounts");

        // 1) enable controller + collateral deposit: vault pays, shares to the sub-account
        uint256 vaultUsdc = _usdc(_plasmaVault);
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
        items[0] = EulerV2BatchItem(
            _EVC,
            subId_,
            abi.encodeWithSelector(IEVC.enableController.selector, sub, _BORROW_VAULT)
        );
        items[1] = _depositItem(_COLLATERAL_VAULT, subId_, 20_000e6, sub);
        FuseAction[] memory pre = new FuseAction[](1);
        pre[0] = FuseAction(
            address(_collateralFuse),
            abi.encodeWithSelector(
                EulerV2CollateralFuse.enter.selector,
                EulerV2CollateralFuseEnterData({eulerVault: _COLLATERAL_VAULT, subAccount: subId_})
            )
        );
        _executeTransient(pre, items, _USDC, _COLLATERAL_VAULT);
        assertEq(_usdc(_plasmaVault), vaultUsdc - 20_000e6, "deposit: vault paid");
        assertGt(IERC4626(_COLLATERAL_VAULT).balanceOf(sub), 0, "deposit: sub-account holds the shares");
        assertEq(IERC4626(_COLLATERAL_VAULT).balanceOf(_plasmaVault), 0, "deposit: vault holds no shares");
        assertEq(IERC4626(_COLLATERAL_VAULT).balanceOf(other), 0, "deposit: other sub-account holds no shares");
        assertTrue(IEVC(_EVC).isControllerEnabled(sub, _BORROW_VAULT), "controller enabled for the sub-account");
        assertFalse(IEVC(_EVC).isControllerEnabled(other, _BORROW_VAULT), "controller not enabled for the other");

        // 2) borrow: receiver is the vault, debt on the sub-account
        vaultUsdc = _usdc(_plasmaVault);
        items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            _BORROW_VAULT,
            subId_,
            abi.encodeWithSelector(IBorrowing.borrow.selector, 5_000e6, _plasmaVault)
        );
        _executeTransient(new FuseAction[](0), items, address(0), address(0));
        assertEq(_usdc(_plasmaVault), vaultUsdc + 5_000e6, "borrow: vault received the tokens");
        assertEq(_usdc(sub), 0, "borrow: sub-account holds no tokens");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(sub), 5_000e6, "borrow: debt on the sub-account");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(_plasmaVault), 0, "borrow: vault holds no debt");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(other), 0, "borrow: other sub-account holds no debt");

        // 3) partial repay: paid by the vault, debt of the sub-account reduced
        vaultUsdc = _usdc(_plasmaVault);
        items[0] = EulerV2BatchItem(
            _BORROW_VAULT,
            subId_,
            abi.encodeWithSelector(IBorrowing.repay.selector, 1_000e6, sub)
        );
        _executeTransient(new FuseAction[](0), items, _USDC, _BORROW_VAULT);
        assertEq(_usdc(_plasmaVault), vaultUsdc - 1_000e6, "repay: vault paid");
        assertEq(_usdc(sub), 0, "repay: sub-account pays nothing");
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(sub), 4_000e6, "repay: debt reduced");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _BORROW_VAULT), 0, "repay: allowance reset");

        // 4) deposit into the borrow vault (shares to the sub-account), then withdraw: owner sub-account, receiver vault
        vaultUsdc = _usdc(_plasmaVault);
        items[0] = _depositItem(_BORROW_VAULT, subId_, 2_000e6, sub);
        _executeTransient(new FuseAction[](0), items, _USDC, _BORROW_VAULT);
        uint256 borrowShares = IERC4626(_BORROW_VAULT).balanceOf(sub);
        assertEq(_usdc(_plasmaVault), vaultUsdc - 2_000e6, "deposit2: vault paid");
        assertGt(borrowShares, 0, "deposit2: sub-account holds the shares");
        assertEq(IERC4626(_BORROW_VAULT).balanceOf(_plasmaVault), 0, "deposit2: vault holds no shares");

        vaultUsdc = _usdc(_plasmaVault);
        items[0] = EulerV2BatchItem(
            _BORROW_VAULT,
            subId_,
            abi.encodeWithSelector(ERC4626Upgradeable.withdraw.selector, 300e6, _plasmaVault, sub)
        );
        _executeTransient(new FuseAction[](0), items, address(0), address(0));
        assertEq(_usdc(_plasmaVault), vaultUsdc + 300e6, "withdraw: vault received the tokens");
        assertEq(_usdc(sub), 0, "withdraw: sub-account holds no tokens");
        assertLt(IERC4626(_BORROW_VAULT).balanceOf(sub), borrowShares, "withdraw: sub-account shares burned");
        assertEq(IERC4626(_BORROW_VAULT).balanceOf(_plasmaVault), 0, "withdraw: vault holds no shares");

        // 5) repay everything, disable the controller, withdraw the collateral to the vault
        vaultUsdc = _usdc(_plasmaVault);
        uint256 collateralShares = IERC4626(_COLLATERAL_VAULT).balanceOf(sub);
        items = new EulerV2BatchItem[](3);
        items[0] = EulerV2BatchItem(
            _BORROW_VAULT,
            subId_,
            abi.encodeWithSelector(IBorrowing.repay.selector, type(uint256).max, sub)
        );
        items[1] = EulerV2BatchItem(_BORROW_VAULT, subId_, abi.encodeWithSelector(IVault.disableController.selector));
        items[2] = EulerV2BatchItem(
            _COLLATERAL_VAULT,
            subId_,
            abi.encodeWithSelector(ERC4626Upgradeable.withdraw.selector, 1_000e6, _plasmaVault, sub)
        );
        _executeTransientBorrowPair(items);
        assertEq(IBorrowing(_BORROW_VAULT).debtOf(sub), 0, "repay all: no debt");
        assertFalse(IEVC(_EVC).isControllerEnabled(sub, _BORROW_VAULT), "controller removed");
        assertEq(_usdc(sub), 0, "end: sub-account holds no tokens");
        assertEq(_usdc(other), 0, "end: other sub-account holds no tokens");
        assertLt(IERC4626(_COLLATERAL_VAULT).balanceOf(sub), collateralShares, "collateral withdraw: shares burned");
        assertEq(IERC4626(_COLLATERAL_VAULT).balanceOf(_plasmaVault), 0, "end: vault holds no collateral shares");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _BORROW_VAULT), 0, "end: borrow allowance reset");
        // repay all returns 4_000e6 of debt (plus accrued interest), withdraw returns 1_000e6
        assertLt(_usdc(_plasmaVault), vaultUsdc, "repay all: vault paid the debt");
    }

    // ------------------------------------------------------------------ helpers

    function _usdc(address account_) private view returns (uint256) {
        return IERC20(_USDC).balanceOf(account_);
    }

    function _depositItem(
        address eulerVault_,
        bytes1 subId_,
        uint256 amount_,
        address receiver_
    ) private pure returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                eulerVault_,
                subId_,
                abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, amount_, receiver_)
            );
    }

    /// @dev Optional pre-actions, then setInputs + enterTransient of the batch fuse with one approval pair (or none
    ///      when `asset_` is zero)
    function _executeTransient(
        FuseAction[] memory preActions_,
        EulerV2BatchItem[] memory items_,
        address asset_,
        address eulerVault_
    ) private {
        EulerV2BatchFuseData memory data;
        data.batchItems = items_;
        if (asset_ == address(0)) {
            data.assetsForApprovals = new address[](0);
            data.eulerVaultsForApprovals = new address[](0);
        } else {
            data.assetsForApprovals = new address[](1);
            data.assetsForApprovals[0] = asset_;
            data.eulerVaultsForApprovals = new address[](1);
            data.eulerVaultsForApprovals[0] = eulerVault_;
        }
        _run(preActions_, data);
    }

    function _executeTransientBorrowPair(EulerV2BatchItem[] memory items_) private {
        EulerV2BatchFuseData memory data;
        data.batchItems = items_;
        data.assetsForApprovals = new address[](1);
        data.assetsForApprovals[0] = _USDC;
        data.eulerVaultsForApprovals = new address[](1);
        data.eulerVaultsForApprovals[0] = _BORROW_VAULT;
        _run(new FuseAction[](0), data);
    }

    function _run(FuseAction[] memory preActions_, EulerV2BatchFuseData memory data_) private {
        FuseAction[] memory actions = new FuseAction[](preActions_.length + 2);
        for (uint256 i; i < preActions_.length; ++i) {
            actions[i] = preActions_[i];
        }
        actions[preActions_.length] = _setInputsAction(abi.encode(data_));
        actions[preActions_.length + 1] = FuseAction(address(_batchFuse), abi.encodeWithSignature("enterTransient()"));
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @dev Splits the ABI encoding into 32-byte chunks, the layout `enterTransient` reads
    function _setInputsAction(bytes memory encoded_) private view returns (FuseAction memory) {
        assertEq(encoded_.length % 32, 0, "encoding is word aligned");
        bytes32[] memory chunks = new bytes32[](encoded_.length / 32);
        for (uint256 i; i < chunks.length; ++i) {
            bytes32 chunk;
            assembly {
                chunk := mload(add(encoded_, add(32, mul(i, 32))))
            }
            chunks[i] = chunk;
        }

        address[] memory fusesArray = new address[](1);
        fusesArray[0] = address(_batchFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = chunks;

        return
            FuseAction(
                address(_setInputsFuse),
                abi.encodeWithSignature(
                    "enter((address[],bytes32[][]))",
                    TransientStorageSetInputsFuseEnterData({fuse: fusesArray, inputsByFuse: inputsByFuse})
                )
            );
    }
}
