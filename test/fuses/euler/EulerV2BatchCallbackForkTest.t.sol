// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
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
import {EulerV2SupplyFuse, EulerV2SupplyFuseExitData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {CallbackHandlerEuler} from "../../../contracts/handlers/callbacks/CallbackHandlerEuler.sol";
import {CallbackData} from "../../../contracts/libraries/CallbackHandlerLib.sol";

/// @notice Regression helper (GLM C-016/C-028, Codex C-003 observation 7, Codex C-049): an ungranted contract passed as
///         the Euler vault of `EulerV2SupplyFuse.exit`, which has no substrate check by design. When the vault's EVC
///         call reaches its `withdraw` during `execute`, it calls `EVC.call(vault, itself, 0, onEulerFlashLoan(...))`
///         and asks the vault to approve its asset to a spender.
contract CallbackOriginForkFakeEulerVault {
    IEVC public immutable EVC;
    address public immutable PLASMA_VAULT;
    address public immutable ASSET;
    address public immutable SPENDER;

    constructor(address evc_, address plasmaVault_, address asset_, address spender_) {
        EVC = IEVC(evc_);
        PLASMA_VAULT = plasmaVault_;
        ASSET = asset_;
        SPENDER = spender_;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1e6;
    }

    function convertToAssets(uint256 shares_) external pure returns (uint256) {
        return shares_;
    }

    function withdraw(uint256, address, address) external returns (uint256) {
        EVC.call(
            PLASMA_VAULT,
            address(this),
            0,
            abi.encodeWithSelector(
                CallbackHandlerEuler.onEulerFlashLoan.selector,
                abi.encode(
                    CallbackData({
                        asset: ASSET,
                        addressToApprove: SPENDER,
                        amountToApprove: type(uint256).max,
                        actionData: abi.encode(new FuseAction[](0))
                    })
                )
            )
        );
        return 0;
    }
}

/// @title EulerV2BatchCallbackForkTest
/// @notice Fork test (IL-9253; GLM C-011 with C-016/C-018/C-028/C-053/C-072/C-090, Codex C-003/C-011/C-030/C-033/C-048/
///         C-049): the Euler callback can no longer leave a vault allowance to an arbitrary spender.
///         Layer 1 - CallbackHandlerEuler accepts `onEulerFlashLoan` only when the EVC on-behalf-of account shares the
///         vault's address prefix, which closes the route through `EulerV2SupplyFuse.exit` and a nested `EVC.call`.
///         Layer 2 - EulerV2BatchFuse accepts a vault-targeted callback item only when its approval is one of the
///         declared (and validated) approval pairs, which the batch resets to 0 afterwards.
/// @dev The judge PoCs are ported as negative regressions only: each test expects the revert and checks that no
///      allowance and no funds left the vault.
contract EulerV2BatchCallbackForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22 (asset USDC), granted on sub-account 0x00 (collateral + borrow) and on 0x01 (supply only)
    address private constant _EULER_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485839;
    uint256 private constant _DEPOSIT = 10_000e6;
    uint256 private constant _FLASH_AMOUNT = 1_000e6;
    uint256 private constant _SUPPLY = 1_000e6;
    uint256 private constant _CALLBACK_APPROVAL = 2_000e6;
    bytes1 private constant _SUB_ZERO = bytes1(0x00);
    bytes1 private constant _SUB_ONE = bytes1(0x01);

    EulerV2BatchFuse private _batchFuse;
    EulerV2SupplyFuse private _supplyFuse;
    address private _plasmaVault;
    address private _attacker;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);
        _attacker = makeAddr("attacker");

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchCallback",
            "EULERV2BATCHCB",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;

        _batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, _EVC);
        _supplyFuse = new EulerV2SupplyFuse(IporFusionMarkets.EULER_V2, _EVC);

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
            EulerSubstrate({eulerVault: _EULER_VAULT, isCollateral: true, canBorrow: true, subAccounts: _SUB_ZERO})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EULER_VAULT, isCollateral: false, canBorrow: false, subAccounts: _SUB_ONE})
        );
        address[] memory fuses = new address[](2);
        fuses[0] = address(_batchFuse);
        fuses[1] = address(_supplyFuse);

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

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).convertToPublicVault();

        // A depositor funds the vault with idle USDC
        deal(_USDC, TestAddresses.USER, _DEPOSIT);
        vm.startPrank(TestAddresses.USER);
        IERC20(_USDC).approve(_plasmaVault, _DEPOSIT);
        PlasmaVault(_plasmaVault).deposit(_DEPOSIT, TestAddresses.USER);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ layer 2: batch route

    /// @notice Port of GLM C-011: one vault-targeted callback item approves ALPHA's own address for max, with no
    ///         approval pairs declared
    function testShouldRejectCallbackApprovingAlphaGlmC011() public {
        uint256 userAssetsBefore = _userAssets();

        vm.expectRevert(_invalidCallbackApproval(_USDC, TestAddresses.ALPHA));
        _executeBatch(
            _single(_callbackItem(_SUB_ZERO, _USDC, TestAddresses.ALPHA, type(uint256).max)),
            new address[](0),
            new address[](0)
        );

        _assertNoLeak(TestAddresses.ALPHA);
        assertEq(_userAssets(), userAssetsBefore, "depositor value unchanged");
    }

    /// @notice Port of GLM C-018: the callback approves an outside address for max, with no approval pairs declared
    function testShouldRejectCallbackApprovingOutsiderGlmC018() public {
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        vm.expectRevert(_invalidCallbackApproval(_USDC, _attacker));
        _executeBatch(
            _single(_callbackItem(_SUB_ZERO, _USDC, _attacker, type(uint256).max)),
            new address[](0),
            new address[](0)
        );

        _assertNoLeak(_attacker);
        assertEq(PlasmaVault(_plasmaVault).totalAssets(), totalAssetsBefore, "NAV unchanged");
    }

    /// @notice Port of Codex C-003: the same item on a vault that also holds idle capital outside any share
    ///         (donated), with both approval arrays empty so the batch reset has nothing to clear
    function testShouldRejectCallbackApprovingOutsiderCodexC003() public {
        deal(_USDC, _plasmaVault, _DEPOSIT + 1_000e6);

        vm.expectRevert(_invalidCallbackApproval(_USDC, _attacker));
        _executeBatch(
            _single(_callbackItem(_SUB_ZERO, _USDC, _attacker, type(uint256).max)),
            new address[](0),
            new address[](0)
        );

        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _DEPOSIT + 1_000e6, "vault USDC unchanged");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _attacker), 0, "no allowance left to the spender");
        assertEq(IERC20(_USDC).balanceOf(_attacker), 0, "spender received nothing");
    }

    /// @notice Port of Codex C-011 on sub-account 0x01: the callback item comes from a genuine vault account, so the
    ///         handler origin check passes and only the declared-pair check of the batch stops it
    function testShouldRejectSubAccountCallbackApprovingOutsiderCodexC011() public {
        vm.expectRevert(_invalidCallbackApproval(_USDC, _attacker));
        _executeBatch(
            _single(_callbackItem(_SUB_ONE, _USDC, _attacker, type(uint256).max)),
            new address[](0),
            new address[](0)
        );

        _assertNoLeak(_attacker);
    }

    /// @notice Port of Codex C-030 after a real depositor deposit; the amount is the vault's whole idle balance
    ///         instead of max, which is not what the check looks at
    function testShouldRejectCallbackApprovingOutsiderForIdleBalanceCodexC030() public {
        vm.expectRevert(_invalidCallbackApproval(_USDC, _attacker));
        _executeBatch(
            _single(_callbackItem(_SUB_ZERO, _USDC, _attacker, _DEPOSIT)),
            new address[](0),
            new address[](0)
        );

        _assertNoLeak(_attacker);
    }

    /// @notice Port of Codex C-033 inside a full flash-liquidity batch: the pair (USDC, eUSDC-22) is declared and
    ///         valid, but the callback between borrow and repay approves an outside address instead
    function testShouldRejectUndeclaredCallbackPairNextToDeclaredPairCodexC033() public {
        address subAccount = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ZERO);

        vm.expectRevert(_invalidCallbackApproval(_USDC, _attacker));
        _executeBatch(
            _flashLiquidityItems(_callbackItem(_SUB_ZERO, _USDC, _attacker, type(uint256).max)),
            _one(_USDC),
            _one(_EULER_VAULT)
        );

        _assertNoLeak(_attacker);
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT), 0, "declared pair not approved");
        assertEq(IBorrowing(_EULER_VAULT).debtOf(subAccount), 0, "no Euler debt");
    }

    /// @notice The callback pair must match one declared pair as a whole: the declared vault with another token is
    ///         rejected
    function testShouldRejectCallbackPairWithUndeclaredAssetForDeclaredVault() public {
        vm.expectRevert(_invalidCallbackApproval(_WETH, _EULER_VAULT));
        _executeBatch(
            _single(_callbackItem(_SUB_ZERO, _WETH, _EULER_VAULT, type(uint256).max)),
            _one(_USDC),
            _one(_EULER_VAULT)
        );

        assertEq(IERC20(_WETH).allowance(_plasmaVault, _EULER_VAULT), 0, "no WETH allowance");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT), 0, "declared pair not approved");
        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _DEPOSIT, "vault USDC unchanged");
    }

    // ------------------------------------------------------------------ layer 1: handler origin

    /// @notice GLM C-016/C-028, Codex C-003 observation 7, Codex C-049: no batch fuse involved. ALPHA exits the
    ///         supply fuse from an ungranted contract, whose `withdraw` calls back the vault through `EVC.call` on
    ///         behalf of itself; the handler rejects that account
    function testShouldRejectCallbackFromSupplyFuseExitTarget() public {
        CallbackOriginForkFakeEulerVault fakeVault = new CallbackOriginForkFakeEulerVault(
            _EVC,
            _plasmaVault,
            _USDC,
            _attacker
        );

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_supplyFuse),
            abi.encodeWithSelector(
                EulerV2SupplyFuse.exit.selector,
                EulerV2SupplyFuseExitData({eulerVault: address(fakeVault), maxAmount: 1e6, subAccount: _SUB_ZERO})
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CallbackHandlerEuler.CallbackHandlerEulerUnauthorizedOrigin.selector,
                address(fakeVault)
            )
        );
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        _assertNoLeak(_attacker);
    }

    // ------------------------------------------------------------------ positive

    /// @notice A callback on sub-account 0x01 that approves the declared pair passes both layers; the next item
    ///         deposits with that approval and the batch resets the rest to 0
    function testShouldRunDeclaredCallbackPairOnSubAccountAndResetIt() public {
        address subAccount = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ONE);

        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
        items[0] = _callbackItem(_SUB_ONE, _USDC, _EULER_VAULT, _CALLBACK_APPROVAL);
        items[1] = EulerV2BatchItem(
            _EULER_VAULT,
            _SUB_ONE,
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _SUPPLY, subAccount)
        );

        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT, _CALLBACK_APPROVAL)));
        _executeBatch(items, _one(_USDC), _one(_EULER_VAULT));

        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _DEPOSIT - _SUPPLY, "vault paid the deposit");
        assertGt(IERC4626(_EULER_VAULT).balanceOf(subAccount), 0, "sub-account holds the eUSDC-22 shares");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT), 0, "callback approval reset after the batch");
    }

    // ------------------------------------------------------------------ helpers

    function _assertNoLeak(address spender_) private view {
        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _DEPOSIT, "vault USDC unchanged");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, spender_), 0, "no allowance left to the spender");
        assertEq(IERC20(_USDC).balanceOf(_attacker), 0, "outside address received nothing");
    }

    function _userAssets() private view returns (uint256) {
        return PlasmaVault(_plasmaVault).convertToAssets(PlasmaVault(_plasmaVault).balanceOf(TestAddresses.USER));
    }

    function _invalidCallbackApproval(address asset_, address spender_) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(EulerV2BatchFuse.EulerV2BatchFuseInvalidCallbackApproval.selector, asset_, spender_);
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
        bytes1 subAccount_,
        address asset_,
        address spender_,
        uint256 amount_
    ) private view returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                _plasmaVault,
                subAccount_,
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

    /// @dev enableController -> borrow -> callback -> repay -> disableController on sub-account 0x00
    function _flashLiquidityItems(
        EulerV2BatchItem memory callback_
    ) private view returns (EulerV2BatchItem[] memory items) {
        items = new EulerV2BatchItem[](5);
        items[0] = EulerV2BatchItem(
            _EVC,
            _SUB_ZERO,
            abi.encodeWithSelector(IEVC.enableController.selector, _plasmaVault, _EULER_VAULT)
        );
        items[1] = EulerV2BatchItem(
            _EULER_VAULT,
            _SUB_ZERO,
            abi.encodeWithSelector(IBorrowing.borrow.selector, _FLASH_AMOUNT, _plasmaVault)
        );
        items[2] = callback_;
        items[3] = EulerV2BatchItem(
            _EULER_VAULT,
            _SUB_ZERO,
            abi.encodeWithSelector(IBorrowing.repay.selector, _FLASH_AMOUNT, _plasmaVault)
        );
        items[4] = EulerV2BatchItem(_EULER_VAULT, _SUB_ZERO, abi.encodeWithSelector(IVault.disableController.selector));
    }

    function _single(EulerV2BatchItem memory item_) private pure returns (EulerV2BatchItem[] memory items) {
        items = new EulerV2BatchItem[](1);
        items[0] = item_;
    }

    function _one(address value_) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value_;
    }
}
