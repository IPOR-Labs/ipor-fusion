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

/// @notice Regression helper (Codex C-012): a token whose `approve` spends an allowance the caller granted it in an
///         earlier approval pair. EulerV2BatchFuse must reject the pair before it calls this contract.
contract ApprovalPairsForkMaliciousToken {
    address public immutable UNDERLYING;
    address public immutable RECEIVER;

    constructor(address underlying_, address receiver_) {
        UNDERLYING = underlying_;
        RECEIVER = receiver_;
    }

    function approve(address, uint256 value_) external returns (bool) {
        if (value_ != 0) {
            uint256 balance = IERC20(UNDERLYING).balanceOf(msg.sender);
            if (balance > 0) {
                IERC20(UNDERLYING).transferFrom(msg.sender, RECEIVER, balance);
            }
        }
        return true;
    }
}

/// @notice Regression helper: reports the asset of a granted Euler vault but is not granted in any substrate
contract ApprovalPairsForkUngrantedVault {
    address public immutable ASSET;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }
}

/// @title EulerV2BatchApprovalPairsForkTest
/// @notice Fork test (IL-9244, GLM C-002, Codex C-002/C-006/C-012/C-026): EulerV2BatchFuse accepts an approval pair only
///         when the Euler vault is granted in an EULER_V2 substrate and the token is that vault's `asset()`. Pairs are
///         checked in order before any external call, so the first invalid pair is reported and nothing moves.
contract EulerV2BatchApprovalPairsForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-22 (asset USDC), granted on sub-account 0x00 with both flags
    address private constant _EULER_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    /// @dev eUSDC-2 (asset USDC), granted only on sub-account 0x01 without flags
    address private constant _OTHER_EULER_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant _BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;
    address private constant _ATTACKER = address(0xBADBAD);

    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 23485838;
    uint256 private constant _IDLE = 1_000_000e6;
    uint256 private constant _DEPOSIT = 1_000e6;
    bytes1 private constant _SUB_ONE = bytes1(0x01);

    EulerV2BatchFuse private _batchFuse;
    ApprovalPairsForkMaliciousToken private _maliciousToken;
    address private _plasmaVault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchPairs",
            "EULERV2BATCHPAIRS",
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

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EULER_VAULT, isCollateral: true, canBorrow: true, subAccounts: 0x00})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _OTHER_EULER_VAULT,
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
        vm.stopPrank();

        _maliciousToken = new ApprovalPairsForkMaliciousToken(_USDC, _ATTACKER);

        deal(_USDC, _plasmaVault, _IDLE);
    }

    /// @notice Codex C-012: pairs [USDC, M] / [M, M] reverted on the first pair, M is never called, no USDC moves
    function testShouldRejectMaliciousApprovalTokenPairs() public {
        vm.expectRevert(_invalidPair(_USDC, address(_maliciousToken)));
        _execute(
            _depositItem(_EULER_VAULT, bytes1(0x00), _plasmaVault),
            _pair(_USDC, address(_maliciousToken)),
            _pair(address(_maliciousToken), address(_maliciousToken))
        );

        _assertNothingMoved(address(_maliciousToken));
    }

    /// @notice Codex layout [T, M] / [M, D] with D a granted Euler vault: the first pair (T, M) has an ungranted spender
    function testShouldRejectFirstPairOfAttackLayoutWithGrantedSecondSpender() public {
        vm.expectRevert(_invalidPair(_USDC, address(_maliciousToken)));
        _execute(
            _depositItem(_EULER_VAULT, bytes1(0x00), _plasmaVault),
            _pair(_USDC, address(_maliciousToken)),
            _pair(address(_maliciousToken), _EULER_VAULT)
        );

        _assertNothingMoved(address(_maliciousToken));
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT), 0, "granted vault allowance unchanged");
    }

    /// @notice Token binding: the valid pair (USDC, D) passes, the next pair (M, D) has a granted spender but a token
    ///         that is not D's asset(), so it is rejected
    function testShouldRejectTokenThatIsNotTheAssetOfTheGrantedVault() public {
        vm.expectRevert(_invalidPair(address(_maliciousToken), _EULER_VAULT));
        _execute(
            _depositItem(_EULER_VAULT, bytes1(0x00), _plasmaVault),
            _pair(_USDC, address(_maliciousToken)),
            _pair(_EULER_VAULT, _EULER_VAULT)
        );

        _assertNothingMoved(_EULER_VAULT);
    }

    /// @notice Grant binding: the valid pair (USDC, D) passes, the next pair (USDC, F) names an ungranted vault F that
    ///         reports USDC as its asset(), so it is rejected
    function testShouldRejectUngrantedVaultWithMatchingAsset() public {
        ApprovalPairsForkUngrantedVault fakeVault = new ApprovalPairsForkUngrantedVault(_USDC);

        vm.expectRevert(_invalidPair(_USDC, address(fakeVault)));
        _execute(
            _depositItem(_EULER_VAULT, bytes1(0x00), _plasmaVault),
            _pair(_USDC, _USDC),
            _pair(_EULER_VAULT, address(fakeVault))
        );

        _assertNothingMoved(address(fakeVault));
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT), 0, "granted vault allowance unchanged");
    }

    /// @notice A zero-address vault is not granted and is rejected before any call to it
    function testShouldRejectZeroAddressVault() public {
        vm.expectRevert(_invalidPair(_USDC, address(0)));
        _execute(_depositItem(_EULER_VAULT, bytes1(0x00), _plasmaVault), _one(_USDC), _one(address(0)));

        _assertNothingMoved(address(0));
    }

    /// @notice A valid pair (USDC, eUSDC-22) is approved for max during the batch and reset to 0 after it
    function testShouldApproveGrantedVaultAssetPairAndResetIt() public {
        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT, type(uint256).max)));
        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT, 0)));
        _execute(_depositItem(_EULER_VAULT, bytes1(0x00), _plasmaVault), _one(_USDC), _one(_EULER_VAULT));

        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _IDLE - _DEPOSIT, "vault paid the deposit");
        assertGt(IERC4626(_EULER_VAULT).balanceOf(_plasmaVault), 0, "vault holds the eUSDC-22 shares");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT), 0, "allowance reset after the batch");
    }

    /// @notice The vault only has to be granted in some substrate: eUSDC-2 granted on sub-account 0x01 without flags
    function testShouldAcceptVaultGrantedOnAnotherSubAccountWithoutFlags() public {
        address subAccount = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ONE);

        _execute(_depositItem(_OTHER_EULER_VAULT, _SUB_ONE, subAccount), _one(_USDC), _one(_OTHER_EULER_VAULT));

        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _IDLE - _DEPOSIT, "vault paid the deposit");
        assertGt(IERC4626(_OTHER_EULER_VAULT).balanceOf(subAccount), 0, "sub-account holds the eUSDC-2 shares");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _OTHER_EULER_VAULT), 0, "allowance reset after the batch");
    }

    // ------------------------------------------------------------------ helpers

    function _assertNothingMoved(address spender_) private view {
        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _IDLE, "vault USDC unchanged");
        assertEq(IERC20(_USDC).balanceOf(_ATTACKER), 0, "attacker received nothing");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, spender_), 0, "no allowance left to the spender");
        assertEq(IERC4626(_EULER_VAULT).balanceOf(_plasmaVault), 0, "no deposit happened");
    }

    function _invalidPair(address asset_, address eulerVault_) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(EulerV2BatchFuse.EulerV2BatchFuseInvalidApprovalPair.selector, asset_, eulerVault_);
    }

    function _execute(EulerV2BatchItem memory item_, address[] memory assets_, address[] memory vaults_) private {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = item_;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_batchFuse),
            abi.encodeWithSelector(
                EulerV2BatchFuse.enter.selector,
                EulerV2BatchFuseData({batchItems: items, assetsForApprovals: assets_, eulerVaultsForApprovals: vaults_})
            )
        );

        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _depositItem(
        address eulerVault_,
        bytes1 subAccount_,
        address receiver_
    ) private pure returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                eulerVault_,
                subAccount_,
                abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _DEPOSIT, receiver_)
            );
    }

    function _one(address value_) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value_;
    }

    function _pair(address first_, address second_) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = first_;
        values[1] = second_;
    }
}
