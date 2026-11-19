// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {CallbackHandlerEuler} from "../../../contracts/handlers/callbacks/CallbackHandlerEuler.sol";
import {CallbackData} from "../../../contracts/libraries/CallbackHandlerLib.sol";

/// @title EulerV2BatchApprovalResetForkTest
/// @notice Fork test (IL-9340, GLM C-098): after `EulerV2BatchFuse.enter` every declared approval pair is back to 0.
///         The batch declares two pairs with different tokens, (USDC, eUSDC-22) and (WETH, eWETH), and its callback
///         item approves only the USDC pair. The WETH pair is therefore reset by the post-batch loop alone, so the
///         assertion cannot pass through the callback approval being consumed or overwritten.
/// @dev Mutation this suite must kill (T25): remove the post-batch reset loop in `EulerV2BatchFuse.enter`.
contract EulerV2BatchApprovalResetForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22 (asset USDC)
    address private constant _EULER_VAULT_USDC = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    /// @dev eWETH (asset WETH)
    address private constant _EULER_VAULT_WETH = 0xb3b36220fA7d12f7055dab5c9FD18E860e9a6bF8;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485841;
    uint256 private constant _IDLE_USDC = 100_000e6;
    uint256 private constant _IDLE_WETH = 10e18;
    uint256 private constant _USDC_DEPOSIT = 1_000e6;
    uint256 private constant _WETH_DEPOSIT = 1e18;
    uint256 private constant _CALLBACK_APPROVAL = 2_000e6;
    bytes1 private constant _SUB_ONE = bytes1(0x01);

    EulerV2BatchFuse private _batchFuse;
    address private _plasmaVault;
    address private _subAccount;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchReset",
            "EULERV2BATCHRESET",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;
        _subAccount = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ONE);

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
            EulerSubstrate({
                eulerVault: _EULER_VAULT_USDC,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_ONE
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EULER_VAULT_WETH,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_ONE
            })
        );
        address[] memory fuses = new address[](1);
        fuses[0] = address(_batchFuse);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.EULER_V2, _BALANCE_FUSE_EULERV2);
        PlasmaVaultGovernance(_plasmaVault).updateCallbackHandler(
            address(new CallbackHandlerEuler(_EVC)),
            _EVC,
            CallbackHandlerEuler.onEulerFlashLoan.selector
        );
        vm.stopPrank();

        deal(_USDC, _plasmaVault, _IDLE_USDC);
        deal(_WETH, _plasmaVault, _IDLE_WETH);
    }

    /// @notice Two deposits (USDC and WETH) with two approval pairs and a callback that approves only the USDC pair:
    ///         both pairs are granted max before the batch, both deposits happen, and both allowances end at 0
    function testShouldResetBothApprovalPairsAfterBatch() public {
        // sanity: the fork block has the pairs this test depends on
        assertEq(IERC4626(_EULER_VAULT_USDC).asset(), _USDC, "eUSDC-22 asset");
        assertEq(IERC4626(_EULER_VAULT_WETH).asset(), _WETH, "eWETH asset");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT_USDC), 0, "USDC allowance before");
        assertEq(IERC20(_WETH).allowance(_plasmaVault, _EULER_VAULT_WETH), 0, "WETH allowance before");

        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](3);
        items[0] = _callbackItem(_USDC, _EULER_VAULT_USDC, _CALLBACK_APPROVAL);
        items[1] = EulerV2BatchItem(
            _EULER_VAULT_USDC,
            _SUB_ONE,
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _USDC_DEPOSIT, _subAccount)
        );
        items[2] = EulerV2BatchItem(
            _EULER_VAULT_WETH,
            _SUB_ONE,
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _WETH_DEPOSIT, _subAccount)
        );

        address[] memory assets = new address[](2);
        assets[0] = _USDC;
        assets[1] = _WETH;
        address[] memory vaults = new address[](2);
        vaults[0] = _EULER_VAULT_USDC;
        vaults[1] = _EULER_VAULT_WETH;

        // each pair is granted max, and each pair is explicitly reset to 0 after the batch
        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT_USDC, type(uint256).max)));
        vm.expectCall(_WETH, abi.encodeCall(IERC20.approve, (_EULER_VAULT_WETH, type(uint256).max)));
        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT_USDC, 0)));
        vm.expectCall(_WETH, abi.encodeCall(IERC20.approve, (_EULER_VAULT_WETH, 0)));

        _executeBatch(items, assets, vaults);

        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _IDLE_USDC - _USDC_DEPOSIT, "vault paid the USDC deposit");
        assertEq(IERC20(_WETH).balanceOf(_plasmaVault), _IDLE_WETH - _WETH_DEPOSIT, "vault paid the WETH deposit");
        assertGt(IERC4626(_EULER_VAULT_USDC).balanceOf(_subAccount), 0, "sub-account holds eUSDC-22 shares");
        assertGt(IERC4626(_EULER_VAULT_WETH).balanceOf(_subAccount), 0, "sub-account holds eWETH shares");

        // WETH keeps an unlimited allowance when it is not reset (WETH9 does not decrement a max allowance)
        assertEq(IERC20(_WETH).allowance(_plasmaVault, _EULER_VAULT_WETH), 0, "WETH pair reset");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT_USDC), 0, "USDC pair reset");
    }

    function _executeBatch(
        EulerV2BatchItem[] memory items_,
        address[] memory assets_,
        address[] memory vaults_
    ) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
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

        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _callbackItem(
        address asset_,
        address spender_,
        uint256 amount_
    ) private view returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                _plasmaVault,
                _SUB_ONE,
                abi.encodeWithSelector(
                    CallbackHandlerEuler.onEulerFlashLoan.selector,
                    abi.encode(
                        CallbackData({
                            asset: asset_,
                            addressToApprove: spender_,
                            amountToApprove: amount_,
                            actionData: abi.encode(new FuseAction[](0))
                        })
                    )
                )
            );
    }
}
