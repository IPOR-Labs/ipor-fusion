// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

/// @title EulerV2BatchCallbackApprovalInvariantForkTest
/// @notice Pinning fuzz test on a mainnet fork (IL-9592, finding M02; fixed on base by IL-9253). The callback of an
///         `EulerV2BatchFuse` batch carries `(asset, addressToApprove, amountToApprove)` chosen by ALPHA. Property,
///         for any such payload and any set of declared approval pairs: `execute` either reverts
///         (`EulerV2BatchFuseInvalidApprovalPair` when a declared pair is not `(asset(), granted Euler vault)`,
///         `EulerV2BatchFuseInvalidCallbackApproval` when the callback pair is not one of the declared pairs) or, when
///         it succeeds, the vault's allowance for every address of the payload is 0 afterwards. Nothing leaves the
///         vault either way. The hand-picked cases are in `EulerV2BatchCallbackForkTest`. Passes on base 8692fbe5.
/// @dev Dropping the declared-pair check in `EulerV2BatchFuse._validatePlasmaVaultCallback` makes the expected
///      `InvalidCallbackApproval` outcome fail: the callback would leave an allowance for an undeclared spender.
contract EulerV2BatchCallbackApprovalInvariantForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22 (asset USDC), granted on sub-account 0x00
    address private constant _EULER_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    /// @dev Own fork block: suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485870;
    uint256 private constant _DEPOSIT = 10_000e6;
    bytes1 private constant _SUB_ZERO = bytes1(0x00);

    EulerV2BatchFuse private _batchFuse;
    address private _plasmaVault;
    address private _attacker;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);
        _attacker = makeAddr("attacker");

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchCallbackInvariant",
            "EULERV2BATCHINV",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;
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

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EULER_VAULT, isCollateral: true, canBorrow: true, subAccounts: _SUB_ZERO})
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

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).convertToPublicVault();

        deal(_USDC, TestAddresses.USER, _DEPOSIT);
        vm.startPrank(TestAddresses.USER);
        IERC20(_USDC).approve(_plasmaVault, _DEPOSIT);
        PlasmaVault(_plasmaVault).deposit(_DEPOSIT, TestAddresses.USER);
        vm.stopPrank();
        // Idle WETH too, so a leaked WETH allowance would be worth something
        deal(_WETH, _plasmaVault, 10e18);
    }

    /// @notice Property over the callback payload and the declared approval pairs (see the contract NatSpec)
    /// forge-config: default.fuzz.runs = 96
    /// @param declaredMode_ 0 none, 1 the valid pair (USDC, eUSDC-22), 2 the valid pair and a fuzzed pair, 3 a fuzzed pair
    /// @param assetPick_ Selects the callback token: USDC, WETH or a fuzzed address
    /// @param spenderPick_ Selects the callback spender: eUSDC-22, attacker, ALPHA or a fuzzed address
    /// @param fuzzAsset_ Fuzzed token (declared pair and callback payload)
    /// @param fuzzSpender_ Fuzzed spender (declared pair and callback payload)
    /// @param amount_ Fuzzed `amountToApprove`
    function testFuzzCallbackApprovalIsDeclaredOrRejected(
        uint8 declaredMode_,
        uint8 assetPick_,
        uint8 spenderPick_,
        address fuzzAsset_,
        address fuzzSpender_,
        uint256 amount_
    ) public {
        address cbAsset = assetPick_ % 3 == 0 ? _USDC : (assetPick_ % 3 == 1 ? _WETH : fuzzAsset_);
        uint256 spenderIndex = spenderPick_ % 4;
        address cbSpender = spenderIndex == 0
            ? _EULER_VAULT
            : (spenderIndex == 1 ? _attacker : (spenderIndex == 2 ? TestAddresses.ALPHA : fuzzSpender_));

        (address[] memory assets, address[] memory vaults) = _declaredPairs(
            declaredMode_ % 4,
            fuzzAsset_,
            fuzzSpender_
        );

        // Expected outcome, derived independently of the fuse: every declared pair must be (USDC, eUSDC-22) because
        // that is the only granted Euler vault; then the callback pair must equal one declared pair
        bool pairsValid = true;
        bool callbackDeclared;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] != _USDC || vaults[i] != _EULER_VAULT) {
                pairsValid = false;
            }
            if (assets[i] == cbAsset && vaults[i] == cbSpender) {
                callbackDeclared = true;
            }
        }

        uint256 vaultUsdcBefore = IERC20(_USDC).balanceOf(_plasmaVault);
        uint256 vaultWethBefore = IERC20(_WETH).balanceOf(_plasmaVault);

        bytes4 selector = _tryExecute(cbAsset, cbSpender, amount_, assets, vaults);

        if (!pairsValid) {
            assertEq(selector, EulerV2BatchFuse.EulerV2BatchFuseInvalidApprovalPair.selector, "invalid declared pair");
        } else if (!callbackDeclared) {
            assertEq(
                selector,
                EulerV2BatchFuse.EulerV2BatchFuseInvalidCallbackApproval.selector,
                "undeclared callback approval"
            );
        } else {
            assertEq(selector, bytes4(0), "declared callback approval succeeds");
        }

        // Whatever the outcome: nothing left the vault and no allowance of the vault stays open
        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), vaultUsdcBefore, "vault USDC unchanged");
        assertEq(IERC20(_WETH).balanceOf(_plasmaVault), vaultWethBefore, "vault WETH unchanged");
        _assertNoAllowance(_EULER_VAULT);
        _assertNoAllowance(_attacker);
        _assertNoAllowance(TestAddresses.ALPHA);
        _assertNoAllowance(cbSpender);
        _assertNoAllowance(fuzzSpender_);
    }

    /// @notice Anti-vacuity canary: the success branch of the property is reachable with the declared pair
    function testCallbackWithDeclaredPairSucceedsAndLeavesNoAllowance() public {
        address[] memory assets = new address[](1);
        address[] memory vaults = new address[](1);
        assets[0] = _USDC;
        vaults[0] = _EULER_VAULT;

        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT, uint256(123))));
        bytes4 selector = _tryExecute(_USDC, _EULER_VAULT, 123, assets, vaults);

        assertEq(selector, bytes4(0), "succeeds");
        _assertNoAllowance(_EULER_VAULT);
    }

    /// @notice Anti-vacuity canary: the reject branch is reachable with an undeclared spender
    function testCallbackWithUndeclaredSpenderIsRejected() public {
        bytes4 selector = _tryExecute(_USDC, _attacker, type(uint256).max, new address[](0), new address[](0));

        assertEq(selector, EulerV2BatchFuse.EulerV2BatchFuseInvalidCallbackApproval.selector, "rejected");
        _assertNoAllowance(_attacker);
    }

    // ------------------------------------------------------------------ helpers

    function _declaredPairs(
        uint8 mode_,
        address fuzzAsset_,
        address fuzzSpender_
    ) private pure returns (address[] memory assets, address[] memory vaults) {
        if (mode_ == 0) {
            return (new address[](0), new address[](0));
        }
        if (mode_ == 1) {
            assets = new address[](1);
            vaults = new address[](1);
            assets[0] = _USDC;
            vaults[0] = _EULER_VAULT;
            return (assets, vaults);
        }
        if (mode_ == 2) {
            assets = new address[](2);
            vaults = new address[](2);
            assets[0] = _USDC;
            vaults[0] = _EULER_VAULT;
            assets[1] = fuzzAsset_;
            vaults[1] = fuzzSpender_;
            return (assets, vaults);
        }
        assets = new address[](1);
        vaults = new address[](1);
        assets[0] = fuzzAsset_;
        vaults[0] = fuzzSpender_;
    }

    /// @dev Runs the batch as ALPHA; returns the selector of the revert, or 0 when `execute` succeeded
    function _tryExecute(
        address asset_,
        address spender_,
        uint256 amount_,
        address[] memory assets_,
        address[] memory vaults_
    ) private returns (bytes4 selector) {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            _plasmaVault,
            _SUB_ZERO,
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

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_batchFuse),
            abi.encodeWithSelector(
                EulerV2BatchFuse.enter.selector,
                EulerV2BatchFuseData({batchItems: items, assetsForApprovals: assets_, eulerVaultsForApprovals: vaults_})
            )
        );

        vm.prank(TestAddresses.ALPHA);
        try PlasmaVault(_plasmaVault).execute(actions) {
            return bytes4(0);
        } catch (bytes memory reason) {
            return bytes4(reason);
        }
    }

    /// @dev Reads the two real tokens only: a fuzzed token address is never called
    function _assertNoAllowance(address spender_) private view {
        assertEq(IERC20(_USDC).allowance(_plasmaVault, spender_), 0, "no USDC allowance");
        assertEq(IERC20(_WETH).allowance(_plasmaVault, spender_), 0, "no WETH allowance");
    }
}
