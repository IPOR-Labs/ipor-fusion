// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
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
import {
    TransientStorageSetInputsFuse,
    TransientStorageSetInputsFuseEnterData
} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";

/// @notice Test-only fuse that copies the transient outputs of a fuse into an event, so the test can read what
///         `enterTransient` wrote (transient storage belongs to the vault, the test contract cannot tload it)
contract TransientOutputsProbeFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event TransientOutputs(bytes32[] outputs);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function probe(address fuse_) external {
        emit TransientOutputs(TransientStorageLib.getOutputs(fuse_));
    }
}

/// @title EulerV2BatchTransientForkTest
/// @notice Fork test (IL-9344, GLM C-102, Codex C-042): `EulerV2BatchFuse.enterTransient` runs through
///         `PlasmaVault.execute` with ABI-encoded `EulerV2BatchFuseData` in transient inputs. Two deposits with two
///         approval pairs produce the outputs `[batchSize, assetsLen, a0, a1, vaultsLen, v0, v1]`; an invalid pair
///         supplied through transient inputs reverts with `EulerV2BatchFuseInvalidApprovalPair`.
/// @dev Mutation this suite must kill (T25): shift or drop an index of the outputs written by `enterTransient`.
contract EulerV2BatchTransientForkTest is Test {
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
    uint256 private constant _FORK_BLOCK = 23485842;
    uint256 private constant _IDLE_USDC = 100_000e6;
    uint256 private constant _IDLE_WETH = 10e18;
    uint256 private constant _USDC_DEPOSIT = 1_000e6;
    uint256 private constant _WETH_DEPOSIT = 1e18;

    EulerV2BatchFuse private _batchFuse;
    TransientStorageSetInputsFuse private _setInputsFuse;
    TransientOutputsProbeFuse private _probeFuse;
    address private _plasmaVault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "EulerV2BatchTransient",
            "EULERV2BATCHTR",
            _USDC,
            0,
            TestAddresses.OWNER,
            0
        );
        _plasmaVault = instance.plasmaVault;

        _batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, _EVC);
        _setInputsFuse = new TransientStorageSetInputsFuse();
        _probeFuse = new TransientOutputsProbeFuse(IporFusionMarkets.EULER_V2);

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
            EulerSubstrate({eulerVault: _EULER_VAULT_USDC, isCollateral: false, canBorrow: false, subAccounts: 0x00})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EULER_VAULT_WETH, isCollateral: false, canBorrow: false, subAccounts: 0x00})
        );
        address[] memory fuses = new address[](3);
        fuses[0] = address(_batchFuse);
        fuses[1] = address(_setInputsFuse);
        fuses[2] = address(_probeFuse);

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

        deal(_USDC, _plasmaVault, _IDLE_USDC);
        deal(_WETH, _plasmaVault, _IDLE_WETH);
    }

    /// @notice enterTransient with two deposits and two approval pairs: deposits happen, allowances end at 0 and the
    ///         transient outputs are `[2, 2, USDC, WETH, 2, eUSDC-22, eWETH]`
    function testShouldRunEnterTransientThroughExecuteWithTwoPairs() public {
        assertEq(IERC4626(_EULER_VAULT_USDC).asset(), _USDC, "eUSDC-22 asset");
        assertEq(IERC4626(_EULER_VAULT_WETH).asset(), _WETH, "eWETH asset");

        EulerV2BatchFuseData memory data = _twoPairData(_USDC, _EULER_VAULT_USDC, _WETH, _EULER_VAULT_WETH);

        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = _setInputsAction(abi.encode(data));
        actions[1] = FuseAction(address(_batchFuse), abi.encodeWithSignature("enterTransient()"));
        actions[2] = FuseAction(
            address(_probeFuse),
            abi.encodeCall(TransientOutputsProbeFuse.probe, (address(_batchFuse)))
        );

        vm.recordLogs();
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        bytes32[] memory outputs = _readProbedOutputs(vm.getRecordedLogs());

        assertEq(outputs.length, 7, "outputs length");
        assertEq(uint256(outputs[0]), 2, "batchSize");
        assertEq(uint256(outputs[1]), 2, "assetsLength");
        assertEq(address(uint160(uint256(outputs[2]))), _USDC, "asset 0");
        assertEq(address(uint160(uint256(outputs[3]))), _WETH, "asset 1");
        assertEq(uint256(outputs[4]), 2, "vaultsLength");
        assertEq(address(uint160(uint256(outputs[5]))), _EULER_VAULT_USDC, "vault 0");
        assertEq(address(uint160(uint256(outputs[6]))), _EULER_VAULT_WETH, "vault 1");

        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _IDLE_USDC - _USDC_DEPOSIT, "vault paid the USDC deposit");
        assertEq(IERC20(_WETH).balanceOf(_plasmaVault), _IDLE_WETH - _WETH_DEPOSIT, "vault paid the WETH deposit");
        assertGt(IERC4626(_EULER_VAULT_USDC).balanceOf(_plasmaVault), 0, "vault holds eUSDC-22 shares");
        assertGt(IERC4626(_EULER_VAULT_WETH).balanceOf(_plasmaVault), 0, "vault holds eWETH shares");
        assertEq(IERC20(_USDC).allowance(_plasmaVault, _EULER_VAULT_USDC), 0, "USDC pair reset");
        assertEq(IERC20(_WETH).allowance(_plasmaVault, _EULER_VAULT_WETH), 0, "WETH pair reset");
    }

    /// @notice The first invalid pair supplied through transient inputs is reported and nothing moves: (WETH, eUSDC-22)
    ///         is a granted vault with a token that is not its asset()
    function testShouldRejectInvalidApprovalPairSuppliedThroughTransientInputs() public {
        EulerV2BatchFuseData memory data = _twoPairData(_WETH, _EULER_VAULT_USDC, _WETH, _EULER_VAULT_WETH);

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = _setInputsAction(abi.encode(data));
        actions[1] = FuseAction(address(_batchFuse), abi.encodeWithSignature("enterTransient()"));

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2BatchFuse.EulerV2BatchFuseInvalidApprovalPair.selector,
                _WETH,
                _EULER_VAULT_USDC
            )
        );
        vm.prank(TestAddresses.ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        assertEq(IERC20(_USDC).balanceOf(_plasmaVault), _IDLE_USDC, "vault USDC unchanged");
        assertEq(IERC20(_WETH).balanceOf(_plasmaVault), _IDLE_WETH, "vault WETH unchanged");
        assertEq(IERC20(_WETH).allowance(_plasmaVault, _EULER_VAULT_USDC), 0, "no allowance to eUSDC-22");
        assertEq(IERC20(_WETH).allowance(_plasmaVault, _EULER_VAULT_WETH), 0, "no allowance to eWETH");
    }

    // ------------------------------------------------------------------ helpers

    function _twoPairData(
        address asset0_,
        address vault0_,
        address asset1_,
        address vault1_
    ) private view returns (EulerV2BatchFuseData memory data) {
        data.batchItems = new EulerV2BatchItem[](2);
        data.batchItems[0] = EulerV2BatchItem(
            _EULER_VAULT_USDC,
            bytes1(0x00),
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _USDC_DEPOSIT, _plasmaVault)
        );
        data.batchItems[1] = EulerV2BatchItem(
            _EULER_VAULT_WETH,
            bytes1(0x00),
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _WETH_DEPOSIT, _plasmaVault)
        );
        data.assetsForApprovals = new address[](2);
        data.assetsForApprovals[0] = asset0_;
        data.assetsForApprovals[1] = asset1_;
        data.eulerVaultsForApprovals = new address[](2);
        data.eulerVaultsForApprovals[0] = vault0_;
        data.eulerVaultsForApprovals[1] = vault1_;
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

    function _readProbedOutputs(Vm.Log[] memory logs_) private view returns (bytes32[] memory outputs) {
        bytes32 topic = keccak256("TransientOutputs(bytes32[])");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics.length > 0 && logs_[i].topics[0] == topic) {
                return abi.decode(logs_[i].data, (bytes32[]));
            }
        }
        revert("TransientOutputs event not found");
    }
}
