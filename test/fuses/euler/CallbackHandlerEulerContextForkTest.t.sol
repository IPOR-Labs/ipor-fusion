// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
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
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {CallbackHandlerEuler} from "../../../contracts/handlers/callbacks/CallbackHandlerEuler.sol";
import {CallbackData} from "../../../contracts/libraries/CallbackHandlerLib.sol";

/// @dev Contract that the vault makes an operator of its sub-account. It gets control as the target of
///      `Erc4626SupplyFuse.enter` (`deposit`) and calls `EVC.call(vault, subAccount, 0, onEulerFlashLoan(...))`:
///      the EVC authenticates it as an operator of the sub-account, whose address shares the vault prefix.
contract ContextForkOperatorVault {
    IEVC public immutable EVC;
    address public immutable PLASMA_VAULT;
    address public immutable ASSET;
    address public immutable SPENDER;
    address public immutable SUB_ACCOUNT;

    constructor(address evc_, address plasmaVault_, address asset_, address spender_, address subAccount_) {
        EVC = IEVC(evc_);
        PLASMA_VAULT = plasmaVault_;
        ASSET = asset_;
        SPENDER = spender_;
        SUB_ACCOUNT = subAccount_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        return 0;
    }

    function deposit(uint256, address) external returns (uint256) {
        EVC.call(PLASMA_VAULT, SUB_ACCOUNT, 0, _callbackCall(ASSET, SPENDER));
        return 0;
    }

    function _callbackCall(address asset_, address spender_) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                CallbackHandlerEuler.onEulerFlashLoan.selector,
                abi.encode(
                    CallbackData({
                        asset: asset_,
                        addressToApprove: spender_,
                        amountToApprove: type(uint256).max,
                        actionData: abi.encode(new FuseAction[](0))
                    })
                )
            );
    }
}

/// @dev Controller of the vault's sub-account (the vault is enabled as its collateral). It gets control as the target
///      of `Erc4626SupplyFuse.enter` (`deposit`) and calls `EVC.controlCollateral(vault, subAccount, 0,
///      onEulerFlashLoan(...))`: the EVC delivers the call to the vault on behalf of the sub-account while the
///      control-collateral flag is set.
contract ContextForkController {
    IEVC public immutable EVC;
    address public immutable PLASMA_VAULT;
    address public immutable ASSET;
    address public immutable SPENDER;
    address public immutable SUB_ACCOUNT;

    constructor(address evc_, address plasmaVault_, address asset_, address spender_, address subAccount_) {
        EVC = IEVC(evc_);
        PLASMA_VAULT = plasmaVault_;
        ASSET = asset_;
        SPENDER = spender_;
        SUB_ACCOUNT = subAccount_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        return 0;
    }

    function checkAccountStatus(address, address[] calldata) external pure returns (bytes4) {
        return this.checkAccountStatus.selector;
    }

    function deposit(uint256, address) external returns (uint256) {
        EVC.controlCollateral(
            PLASMA_VAULT,
            SUB_ACCOUNT,
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

/// @title CallbackHandlerEulerContextForkTest
/// @notice Fork test (IL-9697, 3sigma v2 finding #12): on top of the 19-byte prefix check (IL-9253),
///         `CallbackHandlerEuler` rejects the EVC contexts in which a legitimate vault callback never runs:
///         (a) an operator-authenticated call (`EVC.isOperatorAuthenticated()`), (b) `controlCollateral`
///         (`EVC.isControlCollateralInProgress()`). Both routes reach the handler with an on-behalf-of account that
///         has the vault prefix, so the prefix check alone accepts them. Both must revert with
///         `CallbackHandlerEulerUnauthorizedOrigin(sub-account)` and leave the vault allowances untouched.
contract CallbackHandlerEulerContextForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    /// @dev Own fork block: suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485872;
    uint256 private constant _DEPOSIT = 10_000e6;
    uint256 private constant _SUPPLY = 1_000e6;
    uint256 private constant _ERC4626_MARKET = IporFusionMarkets.ERC4626_0001;

    EulerV2BatchFuse private _batchFuse;
    Erc4626SupplyFuse private _erc4626Fuse;
    address private _plasmaVault;
    address private _attacker;
    address private _subAccount;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);
        _attacker = makeAddr("attacker");

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "CallbackContextForks",
            "CBCTX",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;

        _batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, _EVC);
        _erc4626Fuse = new Erc4626SupplyFuse(_ERC4626_MARKET);
        Erc4626BalanceFuse erc4626BalanceFuse = new Erc4626BalanceFuse(_ERC4626_MARKET);

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

        address[] memory fuses = new address[](2);
        fuses[0] = address(_batchFuse);
        fuses[1] = address(_erc4626Fuse);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.EULER_V2, _BALANCE_FUSE_EULERV2);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(_ERC4626_MARKET, address(erc4626BalanceFuse));
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

        _subAccount = address(uint160(_plasmaVault) ^ 1);
    }

    /// @notice (a) A contract that is an operator of the vault's sub-account 0x01 gets control during
    ///         `Erc4626SupplyFuse.enter` and calls `EVC.call(vault, subAccount, ...)`; the EVC authenticates it as
    ///         operator, so the context is rejected although the account has the vault prefix
    function testShouldRejectCallbackFromOperatorAuthenticatedContext() public {
        ContextForkOperatorVault operator = new ContextForkOperatorVault(
            _EVC,
            _plasmaVault,
            _USDC,
            _attacker,
            _subAccount
        );
        vm.prank(_plasmaVault);
        IEVC(_EVC).setAccountOperator(_subAccount, address(operator), true);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(address(operator))));
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(_ERC4626_MARKET, substrates);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_erc4626Fuse),
            abi.encodeWithSelector(
                Erc4626SupplyFuse.enter.selector,
                Erc4626SupplyFuseEnterData({vault: address(operator), vaultAssetAmount: _SUPPLY, minSharesOut: 0})
            )
        );

        vm.expectRevert(_unauthorizedOrigin(_subAccount));
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        _assertNoLeak();
    }

    /// @notice (b) The vault is enabled as collateral of its sub-account and a controller is enabled for it; the
    ///         controller gets control during `Erc4626SupplyFuse.enter` and calls `EVC.controlCollateral(vault, subAccount, ...)`, which must not reach the callback
    function testShouldRejectCallbackFromControlCollateralContext() public {
        ContextForkController controller = new ContextForkController(_EVC, _plasmaVault, _USDC, _attacker, _subAccount);
        vm.startPrank(_plasmaVault);
        IEVC(_EVC).enableCollateral(_subAccount, _plasmaVault);
        IEVC(_EVC).enableController(_subAccount, address(controller));
        vm.stopPrank();

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(address(controller))));
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(_ERC4626_MARKET, substrates);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_erc4626Fuse),
            abi.encodeWithSelector(
                Erc4626SupplyFuse.enter.selector,
                Erc4626SupplyFuseEnterData({vault: address(controller), vaultAssetAmount: _SUPPLY, minSharesOut: 0})
            )
        );

        vm.expectRevert(_unauthorizedOrigin(_subAccount));
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        _assertNoLeak();
    }

    // ------------------------------------------------------------------ helpers

    function _unauthorizedOrigin(address account_) private pure returns (bytes memory) {
        return abi.encodeWithSelector(CallbackHandlerEuler.CallbackHandlerEulerUnauthorizedOrigin.selector, account_);
    }

    function _assertNoLeak() private view {
        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _DEPOSIT, "vault USDC unchanged");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _attacker), 0, "no allowance left to the spender");
        assertEq(IERC20(_USDC).balanceOf(_attacker), 0, "outside address received nothing");
    }
}
