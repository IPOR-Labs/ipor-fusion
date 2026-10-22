// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

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
    ExternalStateOperationFuseEnterData,
    ExternalStateOperationFuseExitData
} from "../../../../contracts/fuses/external_state/ExternalStateOperationFuse.sol";
import {ExternalStateBalanceFuse} from "../../../../contracts/fuses/external_state/ExternalStateBalanceFuse.sol";
import {ExternalStateUnpauseFuse} from "../../../../contracts/fuses/external_state/ExternalStateUnpauseFuse.sol";
import {ExternalStateExecutor} from "../../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {ExternalStatePausePreHook} from "../../../../contracts/handlers/pre_hooks/pre_hooks/ExternalStatePausePreHook.sol";
import {
    IExternalStateExecutor,
    ExternalStateExecutorAction
} from "../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateErrors} from "../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {ExternalStateSubstrateLib} from "../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";

import {FeeConfigHelper} from "../../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../../RoleLib.sol";
import {MutableValuePriceFeed} from "../../../managers/MutableValuePriceFeed.sol";
import {MockERC20ForExternalState} from "./mocks/MockERC20ForExternalState.sol";
import {MockExternalStateTarget} from "./mocks/MockExternalStateTarget.sol";
import {ExternalStateTestConstants, ExternalStateSlotHelpers} from "./ExternalStateTestHelpers.sol";

/// @title ExternalStateAlphaFlowBreakerTest
/// @notice IL-8775 regression suite: a pending custodian confirm is settled BEFORE ALPHA's enter/exit moves
///         `balances[]`, so the big-change breaker neither trips on ALPHA's own flow nor lets it mask a real
///         custodian change. Real `PlasmaVault.execute()`, no fork. `bigChangeBps` = 500 (5 %), baseline 1000.
contract ExternalStateAlphaFlowBreakerTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;
    uint256 internal constant STALENESS_MAX_S = 1 days;
    uint256 internal constant BIG_CHANGE_BPS = 500;
    uint256 internal constant BASELINE = 1_000e18;

    event ExternalStateBigChangeDetected(uint256 previousTotal, uint256 newTotal, uint256 thresholdBps);
    event ExternalStateBalanceFuseLastCustodianConfirmCountUpdated(uint256 oldConfirmCount, uint256 newConfirmCount);

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
    address internal custodianB;
    address internal balanceAccount;
    address internal user;

    UsersToRoles internal usersToRoles;

    function setUp() public {
        (atomist, atomistPk) = makeAddrAndKey("atomist");
        alpha = makeAddr("alpha");
        custodianA = makeAddr("custA");
        custodianB = makeAddr("custB");
        user = makeAddr("user");
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

        bytes32[] memory substrates = new bytes32[](7);
        substrates[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(underlying));
        substrates[1] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        substrates[2] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        substrates[3] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        substrates[4] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        substrates[5] = ExternalStateSubstrateLib.encodeTargetSubstrate(
            address(target),
            MockExternalStateTarget.noop.selector
        );
        substrates[6] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(vault)).addFuses(fuses);
        PlasmaVaultGovernance(address(vault)).addBalanceFuse(MARKET_ID, address(balanceFuse));
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET_ID, substrates);
        vm.stopPrank();

        // Funds the vault directly so enter-with-amount can transfer to the executor.
        underlying.mint(address(vault), 1_000_000e18);

        // Gate the user-facing selectors with the real pause pre-hook (production wiring).
        ExternalStatePausePreHook preHook = new ExternalStatePausePreHook(MARKET_ID);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.mint.selector;
        selectors[2] = PlasmaVault.withdraw.selector;
        selectors[3] = PlasmaVault.redeem.selector;
        address[] memory implementations = new address[](4);
        bytes32[][] memory preHookSubstrates = new bytes32[][](4);
        for (uint256 i; i < 4; ++i) {
            implementations[i] = address(preHook);
            preHookSubstrates[i] = new bytes32[](0);
        }
        vm.prank(atomist);
        PlasmaVaultGovernance(address(vault)).setPreHookImplementations(selectors, implementations, preHookSubstrates);

        // Baseline: ALPHA enters 1000 (no custodian update yet, so no check). The tokens leave the executor to
        // custody outside a vault call, so the custodian dust check passes on the next propose.
        _execute(_enterCall(BASELINE));
        assertEq(_readLastTotalBalance(), BASELINE, "baseline lastTotalBalance");
        _moveExecutorTokensToCustody();
    }

    // ============================================================
    // Tests
    // ============================================================

    function test_smallConfirmThenLargeEnter_doesNotPause() public {
        _custodianConfirm(1_010e18);

        _execute(_enterCall(100e18));

        assertFalse(ExternalStateSlotHelpers.readPaused(address(vault)), "ALPHA enter must not trip the pause");
        assertEq(_readLastTotalBalance(), 1_110e18, "lastTotalBalance includes the flow after the check");
        assertEq(_readLastChecked(), 1, "watermark advanced");

        _userDeposit(10e18); // the pre-hook lets the user through
    }

    function test_smallConfirmThenLargeExit_doesNotPause() public {
        _custodianConfirm(1_010e18);
        underlying.mint(_executor(), 100e18); // custody returns the tokens to the executor

        _execute(_exitCall(100e18));

        assertFalse(ExternalStateSlotHelpers.readPaused(address(vault)), "ALPHA exit must not trip the pause");
        assertEq(_readLastTotalBalance(), 910e18, "lastTotalBalance includes the flow after the check");
        assertEq(_readLastChecked(), 1, "watermark advanced");

        _userDeposit(10e18);
    }

    function test_largeConfirmMaskedByExit_stillPauses() public {
        _custodianConfirm(1_100e18);
        underlying.mint(_executor(), 100e18);

        vm.expectEmit(false, false, false, true, address(vault));
        emit ExternalStateBigChangeDetected(BASELINE, 1_100e18, BIG_CHANGE_BPS);
        _execute(_exitCall(100e18));

        assertTrue(
            ExternalStateSlotHelpers.readPaused(address(vault)),
            "+10% custodian change pauses despite the exit"
        );
        assertEq(_readLastTotalBalance(), BASELINE, "lastTotalBalance after the exit (1100 - 100)");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookPaused.selector));
        vault.deposit(1e18, user);
    }

    function test_severalFlowsInOneExecute_checkRunsOnce() public {
        _custodianConfirm(1_010e18);

        FuseAction[] memory calls = new FuseAction[](3);
        calls[0] = _enterCall(100e18)[0];
        calls[1] = _exitCall(100e18)[0];
        calls[2] = _enterCall(100e18)[0];

        vm.recordLogs();
        _execute(calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 confirmCountUpdates;
        uint256 bigChanges;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ExternalStateBalanceFuseLastCustodianConfirmCountUpdated.selector) {
                ++confirmCountUpdates;
            } else if (logs[i].topics[0] == ExternalStateBigChangeDetected.selector) {
                ++bigChanges;
            }
        }
        assertEq(confirmCountUpdates, 1, "watermark advanced exactly once");
        assertEq(bigChanges, 0, "no big-change event");
        assertFalse(ExternalStateSlotHelpers.readPaused(address(vault)), "no pause");
        assertEq(_readLastTotalBalance(), 1_110e18, "final total");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _execute(FuseAction[] memory calls_) internal {
        vm.prank(alpha);
        vault.execute(calls_);
    }

    function _enterCall(uint256 amount_) internal view returns (FuseAction[] memory calls) {
        calls = new FuseAction[](1);
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
    }

    function _exitCall(uint256 amount_) internal view returns (FuseAction[] memory calls) {
        calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(opFuse),
            data: abi.encodeCall(
                opFuse.exit,
                (
                    ExternalStateOperationFuseExitData({
                        asset: address(underlying),
                        amount: amount_,
                        balanceAccount: balanceAccount,
                        actions: new ExternalStateExecutorAction[](0)
                    })
                )
            )
        });
    }

    function _moveExecutorTokensToCustody() internal {
        address executor = _executor();
        uint256 bal = underlying.balanceOf(executor);
        vm.prank(executor);
        underlying.transfer(makeAddr("custody"), bal);
    }

    function _custodianConfirm(uint256 newValue_) internal {
        address executor = _executor();
        vm.prank(custodianA);
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, newValue_);
        (, , uint64 proposedAt, uint256 nonce) = ExternalStateExecutor(executor).pendingProposals(balanceAccount);
        bytes32 h = keccak256(
            abi.encode(executor, block.chainid, balanceAccount, newValue_, custodianA, proposedAt, nonce)
        );
        vm.prank(custodianB);
        IExternalStateExecutor(executor).confirmBalance(balanceAccount, h);
    }

    function _userDeposit(uint256 amount_) internal {
        underlying.mint(user, amount_);
        vm.startPrank(user);
        underlying.approve(address(vault), amount_);
        vault.deposit(amount_, user);
        vm.stopPrank();
        assertGt(vault.balanceOf(user), 0, "user deposit passed the pre-hook");
    }

    function _executor() internal view returns (address) {
        bytes32 slot = bytes32(
            uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) + ExternalStateTestConstants.EXECUTOR_SLOT_OFFSET
        );
        return address(uint160(uint256(vm.load(address(vault), slot))));
    }

    function _readLastTotalBalance() internal view returns (uint256) {
        return
            uint256(
                vm.load(
                    address(vault),
                    bytes32(
                        uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) +
                            ExternalStateTestConstants.LAST_TOTAL_BALANCE_SLOT_OFFSET
                    )
                )
            );
    }

    function _readLastChecked() internal view returns (uint256) {
        return
            uint256(
                vm.load(
                    address(vault),
                    bytes32(
                        uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) +
                            ExternalStateTestConstants.LAST_CHECKED_CUSTODIAN_CONFIRM_COUNT_SLOT_OFFSET
                    )
                )
            );
    }
}
