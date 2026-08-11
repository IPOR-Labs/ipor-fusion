// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {Roles} from "../../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";

import {
    ExternalStateOperationFuse,
    ExternalStateOperationFuseEnterData
} from "../../../../contracts/fuses/external_state/ExternalStateOperationFuse.sol";
import {ExternalStateBalanceFuse} from "../../../../contracts/fuses/external_state/ExternalStateBalanceFuse.sol";
import {ExternalStateUnpauseFuse, ExternalStateUnpauseData} from "../../../../contracts/fuses/external_state/ExternalStateUnpauseFuse.sol";
import {IExternalStateExecutor, ExternalStateExecutorAction} from "../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateErrors} from "../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {ExternalStateSubstrateLib} from "../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";

import {FeeConfigHelper} from "../../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../../RoleLib.sol";
import {MutableValuePriceFeed} from "../../../managers/MutableValuePriceFeed.sol";
import {MockERC20ForExternalState} from "./mocks/MockERC20ForExternalState.sol";
import {MockExternalStateTarget} from "./mocks/MockExternalStateTarget.sol";
import {ExternalStateTestConstants, ExternalStateSlotHelpers} from "./ExternalStateTestHelpers.sol";

/// @title ExternalStateRealVaultExecuteTest
/// @notice IL-7895 regression suite: drives the ExternalState fuses through a REAL `PlasmaVault.execute()`
///         (not `MockPlasmaVaultForExternalState`). Before the push-based bootstrap fix, every test in the
///         "via execute" group reverted with `CallbackHandlerLib.HandlerNotFound()` because the
///         vault's fallback routes all unmatched selectors to the callback handler while
///         `execute` is running, blocking the executor's `getMarketSubstrates` pull and the
///         unpause fuse's `getAccessManagerAddress` self-call.
contract ExternalStateRealVaultExecuteTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;
    uint256 internal constant STALENESS_MAX_S = 1 days;
    uint256 internal constant BIG_CHANGE_BPS = 1000;

    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    PriceOracleMiddleware internal priceOracle;
    MockERC20ForExternalState internal underlying;
    MutableValuePriceFeed internal priceFeed;
    MockExternalStateTarget internal target;

    ExternalStateOperationFuse internal opFuse;
    ExternalStateBalanceFuse internal balanceFuse;
    ExternalStateUnpauseFuse internal unpauseFuse;

    address internal atomist;
    uint256 internal atomistPk;
    address internal alpha;
    address internal custodianA;
    address internal balanceAccount;

    UsersToRoles internal usersToRoles;

    function setUp() public {
        (atomist, atomistPk) = makeAddrAndKey("atomist");
        alpha = makeAddr("alpha");
        custodianA = makeAddr("custA");
        balanceAccount = makeAddr("ba");

        underlying = new MockERC20ForExternalState("Underlying", "UND", 18);
        target = new MockExternalStateTarget();

        priceOracle = new PriceOracleMiddleware(address(0));
        priceOracle.initialize(atomist);
        priceFeed = new MutableValuePriceFeed(1e18);
        address[] memory assets = new address[](1);
        assets[0] = address(underlying);
        address[] memory sources = new address[](1);
        sources[0] = address(priceFeed);
        vm.prank(atomist);
        priceOracle.setAssetsPricesSources(assets, sources);

        // RoleLib's fee-manager wiring requires superAdmin to also hold ATOMIST_ROLE — use one
        // address for both, mirroring PlasmaVaultNonceTest.
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        usersToRoles.alphas = new address[](1);
        usersToRoles.alphas[0] = alpha;
        usersToRoles.performanceFeeManagers = new address[](0);
        usersToRoles.managementFeeManagers = new address[](0);
        usersToRoles.feeTimelock = 0;

        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vm.startPrank(atomist);
        vault = new PlasmaVault();
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "ExternalState Plasma Vault",
                assetSymbol: "externalStatePV",
                underlyingToken: address(underlying),
                priceOracleMiddleware: address(priceOracle),
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: address(accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(vault), accessManager, withdrawManager);

        // RoleLib does not wire grantMarketSubstrates — grant it to the atomist here.
        bytes4[] memory substrateSig = new bytes4[](1);
        substrateSig[0] = PlasmaVaultGovernance.grantMarketSubstrates.selector;
        vm.prank(atomist);
        accessManager.setTargetFunctionRole(address(vault), substrateSig, Roles.ATOMIST_ROLE);

        opFuse = new ExternalStateOperationFuse(MARKET_ID);
        balanceFuse = new ExternalStateBalanceFuse(MARKET_ID);
        unpauseFuse = new ExternalStateUnpauseFuse(MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(opFuse);
        fuses[1] = address(unpauseFuse);

        bytes32[] memory substrates = new bytes32[](6);
        substrates[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(underlying));
        substrates[1] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        substrates[2] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        substrates[3] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        substrates[4] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        substrates[5] = ExternalStateSubstrateLib.encodeTargetSubstrate(address(target), MockExternalStateTarget.noop.selector);

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(vault)).addFuses(fuses);
        PlasmaVaultGovernance(address(vault)).addBalanceFuse(MARKET_ID, address(balanceFuse));
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET_ID, substrates);
        vm.stopPrank();

        // Funds the vault directly so enter-with-amount can transfer to the executor.
        underlying.mint(address(vault), 1_000_000e18);
    }

    // ============================================================
    // Bootstrap via a real PlasmaVault.execute (IL-7895 regression)
    // ============================================================

    function test_execute_createExecutor_bootstrapsExecutorInsideExecute() public {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({fuse: address(opFuse), data: abi.encodeCall(opFuse.createExecutor, ())});

        vm.prank(alpha);
        vault.execute(calls);

        address executor = _readExecutor();
        assertTrue(executor != address(0), "executor deployed and stored");
        // Substrate caches populated via the vault push — proves the bootstrap completed.
        assertEq(IExternalStateExecutor(executor).stalenessMax(), STALENESS_MAX_S, "stalenessMax cached");
        assertEq(IExternalStateExecutor(executor).VAULT(), address(vault), "bound to real vault");
        assertEq(ExternalStateExecutorCacheReader(executor).custodians(0), custodianA, "custodian cached");
        assertEq(ExternalStateExecutorCacheReader(executor).balanceAccounts(0), balanceAccount, "balance account cached");
        assertEq(ExternalStateExecutorCacheReader(executor).assets(0), address(underlying), "asset cached");
    }

    function test_execute_enter_implicitBootstrap_actionsOnly() public {
        ExternalStateExecutorAction[] memory actions = new ExternalStateExecutorAction[](1);
        actions[0] = ExternalStateExecutorAction({target: address(target), data: abi.encodeCall(MockExternalStateTarget.noop, ())});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(opFuse),
            data: abi.encodeCall(
                opFuse.enter,
                (ExternalStateOperationFuseEnterData({asset: address(0), amount: 0, balanceAccount: address(0), actions: actions}))
            )
        });

        vm.prank(alpha);
        vault.execute(calls);

        assertTrue(_readExecutor() != address(0), "executor lazily deployed on enter");
        assertEq(target.callsLength(), 1, "action forwarded to target");
    }

    function test_execute_enter_withAmount_transfersAndCreditsBalance() public {
        uint256 amount = 1_000e18;
        _executeEnterWithAmount(amount);

        address executor = _readExecutor();
        assertEq(underlying.balanceOf(executor), amount, "tokens moved vault -> executor");

        (uint256 totalBalance,,) = IExternalStateExecutor(executor).getBalanceFuseSnapshot();
        assertEq(totalBalance, amount, "balance account credited 1:1 (price 1e18)");
        assertEq(vault.totalAssetsInMarket(MARKET_ID), amount, "market balance updated via balance fuse");
    }

    function test_execute_secondEnter_reusesExistingExecutor() public {
        _executeEnterWithAmount(100e18);
        address executor1 = _readExecutor();

        _executeEnterWithAmount(50e18);
        address executor2 = _readExecutor();

        assertEq(executor1, executor2, "executor address stable across executes");
        (uint256 totalBalance,,) = IExternalStateExecutor(_readExecutor()).getBalanceFuseSnapshot();
        assertEq(totalBalance, 150e18, "balances accumulate on the same executor");
    }

    function test_execute_unpause_insideExecute_clearsPauseFlag() public {
        uint256 amount = 500e18;
        _executeEnterWithAmount(amount);
        ExternalStateSlotHelpers.setPaused(address(vault), true);

        ExternalStateUnpauseData memory d = _signedUnpauseData(amount, 1, block.timestamp + 1 hours, atomistPk);
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({fuse: address(unpauseFuse), data: abi.encodeCall(unpauseFuse.unpause, (d))});

        vm.prank(alpha);
        vault.execute(calls);

        assertFalse(ExternalStateSlotHelpers.readPaused(address(vault)), "pause flag cleared through real execute");
    }

    function test_execute_unpause_signerNotAtomist_reverts() public {
        uint256 amount = 500e18;
        _executeEnterWithAmount(amount);
        ExternalStateSlotHelpers.setPaused(address(vault), true);

        (address stranger, uint256 strangerPk) = makeAddrAndKey("stranger");
        ExternalStateUnpauseData memory d = _signedUnpauseData(amount, 1, block.timestamp + 1 hours, strangerPk);
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({fuse: address(unpauseFuse), data: abi.encodeCall(unpauseFuse.unpause, (d))});

        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateUnpauseSignerNotAtomist.selector, stranger));
        vault.execute(calls);

        assertTrue(ExternalStateSlotHelpers.readPaused(address(vault)), "vault stays paused");
    }

    // ============================================================
    // Pull path still works outside execute
    // ============================================================

    function test_syncSubstrates_stillWorksOutsideExecute() public {
        _executeEnterWithAmount(100e18);
        address executor = _readExecutor();
        assertEq(IExternalStateExecutor(executor).stalenessMax(), STALENESS_MAX_S);

        // Governance re-grants with a changed STALENESS_MAX; anyone re-syncs directly (pull path).
        bytes32[] memory substrates = new bytes32[](6);
        substrates[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(underlying));
        substrates[1] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        substrates[2] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        substrates[3] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(2 days);
        substrates[4] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        substrates[5] = ExternalStateSubstrateLib.encodeTargetSubstrate(address(target), MockExternalStateTarget.noop.selector);
        vm.prank(atomist);
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET_ID, substrates);

        IExternalStateExecutor(executor).syncSubstrates();
        assertEq(IExternalStateExecutor(executor).stalenessMax(), 2 days, "pull-based resync against real vault");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _executeEnterWithAmount(uint256 amount_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(opFuse),
            data: abi.encodeCall(
                opFuse.enter,
                (
                    ExternalStateOperationFuseEnterData({
                        asset: address(underlying),
                        amount: amount_,
                        balanceAccount: balanceAccount,
                        actions: new ExternalStateExecutorAction[](0)
                    })
                )
            )
        });
        vm.prank(alpha);
        vault.execute(calls);
    }

    function _readExecutor() internal view returns (address) {
        bytes32 slot = bytes32(uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) + ExternalStateTestConstants.EXECUTOR_SLOT_OFFSET);
        return address(uint160(uint256(vm.load(address(vault), slot))));
    }

    function _signedUnpauseData(uint256 balance_, uint256 nonce_, uint256 expiration_, uint256 pk_)
        internal
        view
        returns (ExternalStateUnpauseData memory d)
    {
        bytes32 digest =
            keccak256(abi.encodePacked(address(vault), MARKET_ID, balance_, nonce_, expiration_, block.chainid));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk_, digest);
        d = ExternalStateUnpauseData({
            confirmedTotalBalance: balance_,
            nonce: nonce_,
            expirationTime: expiration_,
            signature: abi.encodePacked(r, s, v)
        });
    }
}

/// @dev Minimal reader for ExternalStateExecutor public array getters not exposed on IExternalStateExecutor.
interface ExternalStateExecutorCacheReader {
    function custodians(uint256) external view returns (address);
    function balanceAccounts(uint256) external view returns (address);
    function assets(uint256) external view returns (address);
}
