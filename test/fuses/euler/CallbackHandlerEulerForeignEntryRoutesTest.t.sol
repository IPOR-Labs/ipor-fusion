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
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {CallbackHandlerEuler} from "../../../contracts/handlers/callbacks/CallbackHandlerEuler.sol";
import {CallbackData} from "../../../contracts/libraries/CallbackHandlerLib.sol";

/// @dev Foreign contract that gets control during `execute` and calls `EVC.call(vault, itself, 0, onEulerFlashLoan(...))`
///      to have the vault approve its USDC to a spender. `deposit` is the entry used by both routes: an ERC-4626 vault
///      supplied by `Erc4626SupplyFuse.enter` and a granted-looking Euler vault target of an `EulerV2BatchFuse` batch.
contract ForeignEntryForkMaliciousVault {
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

    function asset() external view returns (address) {
        return ASSET;
    }

    function deposit(uint256, address) external returns (uint256) {
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

/// @title CallbackHandlerEulerForeignEntryRoutesTest
/// @notice Pinning fork test (IL-9594, finding M04; fixed on base by IL-9253). `CallbackHandlerEuler` accepts
///         `onEulerFlashLoan` only when the EVC on-behalf-of account shares the vault's 19-byte address prefix, so a
///         foreign contract that gets control during `execute` cannot forge the callback through `EVC.call`. The
///         existing `EulerV2BatchCallbackForkTest` covers the entry through `EulerV2SupplyFuse.exit`; this suite replays
///         the other two Olympix PoC routes: (a) an ERC-4626 vault granted as a substrate and supplied through
///         `Erc4626SupplyFuse.enter`, (b) a contract called as an Euler vault target inside an `EulerV2BatchFuse` batch.
///         Both must revert with `CallbackHandlerEulerUnauthorizedOrigin(foreign contract)` and leave the balance and
///         allowances of the vault untouched. Passes on base 8692fbe5.
/// @dev Replacing the handler by one that returns the payload without the origin check makes both tests fail: the
///      callback would leave a max USDC allowance to the spender.
contract CallbackHandlerEulerForeignEntryRoutesTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    /// @dev Own fork block: suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485871;
    uint256 private constant _DEPOSIT = 10_000e6;
    uint256 private constant _SUPPLY = 1_000e6;
    uint256 private constant _ERC4626_MARKET = IporFusionMarkets.ERC4626_0001;
    bytes1 private constant _SUB_ZERO = bytes1(0x00);

    EulerV2BatchFuse private _batchFuse;
    Erc4626SupplyFuse private _erc4626Fuse;
    address private _plasmaVault;
    address private _attacker;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);
        _attacker = makeAddr("attacker");

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "CallbackForeignRoutes",
            "CBFOREIGN",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;

        _batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, _EVC);
        _erc4626Fuse = new Erc4626SupplyFuse(_ERC4626_MARKET);

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
    }

    /// @notice Route (a): a malicious ERC-4626 vault granted as a substrate of the ERC-4626 market is supplied through
    ///         `Erc4626SupplyFuse.enter`; its `deposit` calls `EVC.call` on behalf of itself
    function testShouldRejectCallbackFromErc4626SupplyEnterTarget() public {
        ForeignEntryForkMaliciousVault malicious = new ForeignEntryForkMaliciousVault(
            _EVC,
            _plasmaVault,
            _USDC,
            _attacker
        );
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(address(malicious))));
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(_ERC4626_MARKET, substrates);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_erc4626Fuse),
            abi.encodeWithSelector(
                Erc4626SupplyFuse.enter.selector,
                Erc4626SupplyFuseEnterData({vault: address(malicious), vaultAssetAmount: _SUPPLY, minSharesOut: 0})
            )
        );

        vm.expectRevert(_unauthorizedOrigin(address(malicious)));
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        _assertNoLeak();
    }

    /// @notice Route (b): a contract granted as an Euler vault is the target of a batch `deposit`; the hook-like
    ///         `deposit` runs while the batch executes and calls `EVC.call` on behalf of itself
    function testShouldRejectCallbackFromContractCalledInsideBatch() public {
        ForeignEntryForkMaliciousVault malicious = new ForeignEntryForkMaliciousVault(
            _EVC,
            _plasmaVault,
            _USDC,
            _attacker
        );
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: address(malicious),
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_ZERO
            })
        );
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);

        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            address(malicious),
            _SUB_ZERO,
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _SUPPLY, _plasmaVault)
        );

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

        vm.expectRevert(_unauthorizedOrigin(address(malicious)));
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
