// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipObservation} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {
    CrosschainConstants,
    BusinessAction,
    CommandStatus
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainVaultActionLib} from "../../contracts/crosschain/lib/CrosschainVaultActionLib.sol";
import {
    CrosschainMessages,
    UpdateVaults,
    Command,
    OutboundTransfer
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

import {ValueNeutralToken} from "./CcipValueNeutralVersionTest.t.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockFaultyVault} from "./mocks/MockFaultyVault.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @notice Runs `CrosschainVaultActionLib.sweepShares` in a host that plays the dispatcher (`address(this)`), so the
///         gas pre-check and the per-vault outcomes can be driven with explicit gas limits (IL-8784).
contract VaultSweepHarness {
    // solhint-disable-next-line var-name-mixedcase
    address public ASSET;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function sweep(
        address vault_
    ) external returns (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) {
        return CrosschainVaultActionLib.sweepShares(vault_);
    }
}

/// @title VaultSweepLibTest
/// @notice IL-8784: unit tests of the shared `sweepShares` helper against mock vaults. Both dispatchers delegate to it.
contract VaultSweepLibTest is Test {
    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    ValueNeutralToken internal token;
    MockFaultyVault internal vault;
    VaultSweepHarness internal host;

    function setUp() public {
        token = new ValueNeutralToken();
        vault = new MockFaultyVault(IERC20(address(token)), "V", "V");
        host = new VaultSweepHarness(address(token));
        token.mint(address(this), 100e18);
        token.approve(address(vault), 100e18);
        vault.deposit(60e18, address(host));
    }

    function testShouldRedeemTheWholePositionAndMeasureAssets() public {
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSwept(address(vault), 60e18, 60e18);
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweep(address(vault));
        assertEq(redeemed, 60e18, "redeemed");
        assertEq(assetsLD, 60e18, "assets measured");
        assertEq(left, 0, "nothing left");
        assertEq(reason, 0, "reason none");
        assertEq(err, bytes4(0), "no error");
        assertEq(token.balanceOf(address(host)), 60e18, "assets on the host");
    }

    function testShouldDoNothingWithoutShares() public {
        MockFaultyVault empty = new MockFaultyVault(IERC20(address(token)), "E", "E");
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, ) = host.sweep(address(empty));
        assertEq(redeemed + assetsLD + left + reason, 0, "no-op");
    }

    function testShouldSkipTheRedeemForDustShares() public {
        MockFaultyVault dustVault = new MockFaultyVault(IERC20(address(token)), "D", "D");
        token.approve(address(dustVault), 1);
        dustVault.deposit(1, address(host));
        dustVault.setRedeemFaults(true, false, false, false); // a redeem call would revert: it must not be made
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(address(dustVault), 1, 4, bytes4(0), true);
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweep(address(dustVault));
        assertEq(redeemed + assetsLD, 0, "nothing redeemed");
        assertEq(left, 1, "dust reported");
        assertEq(reason, 4, "dust skipped");
        assertEq(err, bytes4(0), "redeem never called");
    }

    /// @dev The bound is 0.01 asset unit (1e16 for the 18-decimal test token): exactly at it is dust, one above is not.
    function testShouldTreatExactlyOneHundredthOfAnAssetUnitAsDust() public {
        MockFaultyVault atBound = new MockFaultyVault(IERC20(address(token)), "B", "B");
        token.approve(address(atBound), 1e16);
        atBound.deposit(1e16, address(host));
        (, , , uint8 reason, ) = host.sweep(address(atBound));
        assertEq(reason, 4, "at the bound: dust");

        MockFaultyVault above = new MockFaultyVault(IERC20(address(token)), "A", "A");
        token.approve(address(above), 1e16 + 1);
        above.deposit(1e16 + 1, address(host));
        (uint256 redeemed, , , uint8 reasonAbove, ) = host.sweep(address(above));
        assertEq(reasonAbove, 0, "above the bound: normal sweep");
        assertEq(redeemed, 1e16 + 1, "redeemed");
    }

    /// @dev A failing `convertToAssets` view is never dust: the capped redeem path runs.
    function testShouldNotTreatAnUnreadableValueAsDust() public {
        MockFaultyVault dustVault = new MockFaultyVault(IERC20(address(token)), "D", "D");
        token.approve(address(dustVault), 1);
        dustVault.deposit(1, address(host));
        dustVault.setFaults(false, true, false); // convertToAssets reverts
        (uint256 redeemed, , uint256 left, uint8 reason, ) = host.sweep(address(dustVault));
        assertEq(reason, 0, "normal path");
        assertEq(redeemed, 1, "redeem ran");
        assertEq(left, 0);
    }

    function testShouldReportAnUnreadableBalance() public {
        vault.setFaults(true, false, false);
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(address(vault), 0, 1, bytes4(0), true);
        (, , uint256 left, uint8 reason, ) = host.sweep(address(vault));
        assertEq(left, 0, "unknown balance reported as 0");
        assertEq(reason, 1, "unreadable");
    }

    function testShouldReportARevertingRedeemWithItsSelector() public {
        vault.setRedeemFaults(true, false, false, false);
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(address(vault), 60e18, 2, MockFaultyVault.RedeemBroken.selector, true);
        (uint256 redeemed, , uint256 left, uint8 reason, bytes4 err) = host.sweep(address(vault));
        assertEq(redeemed, 0, "nothing redeemed");
        assertEq(left, 60e18, "position intact");
        assertEq(reason, 2, "reverted");
        assertEq(err, MockFaultyVault.RedeemBroken.selector, "selector surfaced");
    }

    function testShouldReportAPartialRedeemWhenMaxRedeemIsBelowTheBalance() public {
        vault.setMaxRedeemFaults(false, true, 25e18);
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSwept(address(vault), 25e18, 25e18);
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(address(vault), 35e18, 3, bytes4(0), true);
        (uint256 redeemed, , uint256 left, uint8 reason, ) = host.sweep(address(vault));
        assertEq(redeemed, 25e18, "capped redeem");
        assertEq(left, 35e18, "rest stays");
        assertEq(reason, 3, "partial");
    }

    function testShouldReportAZeroMaxRedeemAsPartialWithoutCallingRedeem() public {
        vault.setMaxRedeemFaults(false, true, 0);
        vault.setRedeemFaults(true, false, false, false); // would revert if it were called
        (, , uint256 left, uint8 reason, bytes4 err) = host.sweep(address(vault));
        assertEq(left, 60e18, "restricted vault: nothing movable");
        assertEq(reason, 3, "partial, not a revert");
        assertEq(err, bytes4(0), "redeem never called");
    }

    function testShouldFallBackToTheBalanceWhenMaxRedeemReverts() public {
        vault.setMaxRedeemFaults(true, false, 0);
        (uint256 redeemed, , uint256 left, uint8 reason, ) = host.sweep(address(vault));
        assertEq(redeemed, 60e18, "balance used");
        assertEq(left, 0);
        assertEq(reason, 0);
    }

    function testShouldIgnoreEmptyReturndataFromASuccessfulRedeem() public {
        vault.setRedeemFaults(false, false, true, false);
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, ) = host.sweep(address(vault));
        assertEq(redeemed, 60e18, "shares burned although redeem returned nothing");
        assertEq(assetsLD, 60e18);
        assertEq(left, 0);
        assertEq(reason, 0);
    }

    function testShouldSurviveAReturndataBomb() public {
        vault.setRedeemFaults(false, false, false, true);
        (, , uint256 left, uint8 reason, ) = host.sweep(address(vault));
        assertEq(left, 60e18, "position intact");
        assertEq(reason, 2, "reverted");
    }

    /// @dev A gas-burning redeem is cut off at `VAULT_SWEEP_GAS`: the sweep returns, with plenty of gas left to
    ///      finish, instead of consuming everything it was given. Dropping the cap makes this test run out of gas.
    function testShouldBoundAGasBurningRedeemToTheSweepCap() public {
        vault.setRedeemFaults(false, true, false, false);
        uint256 gasBefore = gasleft();
        (, , uint256 left, uint8 reason, bytes4 err) = host.sweep{gas: 5_000_000}(address(vault));
        uint256 used = gasBefore - gasleft();
        assertEq(left, 60e18, "position intact");
        assertEq(reason, 2, "out of gas inside the cap is a revert");
        assertEq(err, bytes4(0), "no revert data");
        assertGe(used, CrosschainConstants.VAULT_SWEEP_GAS, "the burner consumed its whole cap");
        assertLt(used, CrosschainConstants.VAULT_SWEEP_GAS + 600_000, "and not more than the cap plus overhead");
    }

    /// @dev D-065: with less gas than the cap needs the sweep forwards `gasleft() - VAULT_SWEEP_RESERVE_GAS` instead
    ///      of reverting. A cheap redeem still succeeds on the reduced gas.
    function testShouldForwardLessThanTheCapWhenTheCallerGasIsShort() public {
        (uint256 redeemed, , uint256 left, uint8 reason, ) = host.sweep{gas: 2_200_000}(address(vault));
        assertEq(redeemed, 60e18, "cheap redeem fits the reduced gas");
        assertEq(left, 0, "swept");
        assertEq(reason, 0, "clean");
    }

    /// @dev D-065: a redeem that burns all it is given, on a reduced forward, is reported as GAS_LIMITED (5), not as a
    ///      plain revert (2), and never reverts the sweep.
    function testShouldReportGasLimitedWhenAReducedForwardIsBurned() public {
        vault.setRedeemFaults(false, true, false, false);
        (, , uint256 left, uint8 reason, ) = host.sweep{gas: 1_200_000}(address(vault));
        assertEq(left, 60e18, "position intact");
        assertEq(reason, 5, "gas limited");
    }

    /// @dev D-065: when not even the minimum can be forwarded the redeem is skipped (reason 5), no revert.
    function testShouldSkipTheRedeemWhenTheMinimumGasCannotBeForwarded() public {
        (, , uint256 left, uint8 reason, bytes4 err) = host.sweep{gas: 440_000}(address(vault));
        assertEq(left, 60e18, "position intact");
        assertEq(reason, 5, "gas limited");
        assertEq(err, bytes4(0), "no vault revert data");
    }
}

/// @title CcipVaultRemovalSweepTest
/// @notice IL-8784 on the CCIP dispatcher: removing a vault from the allowlist redeems its position into idle,
///         credits `trackedIdle` and ALWAYS untracks it (D-028), including at the 32-vault cap.
contract CcipVaultRemovalSweepTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    MockCcipRouter internal router;
    ValueNeutralToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    MockFaultyVault internal vaultA;
    MockFaultyVault internal vaultB;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new ValueNeutralToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 3_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            RESCUE_ADMIN,
            GUARDIAN,
            RESCUE_DELAY
        );
        vaultA = new MockFaultyVault(IERC20(address(token)), "A", "A");
        vaultB = new MockFaultyVault(IERC20(address(token)), "B", "B");
        address[] memory vaults = new address[](2);
        vaults[0] = address(vaultA);
        vaults[1] = address(vaultB);
        vm.prank(factory);
        dispatcher.configureVaults(vaults, true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 3_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        vm.warp(1_700_000_000);
        vm.roll(1_000);
    }

    // ------------------------------------------------------------------ helpers

    function _bridge(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
    }

    /// @dev Gives the dispatcher a live position without going through the command lane (idle is not debited).
    function _position(MockFaultyVault vault_, uint256 amount_) private {
        token.mint(address(this), amount_);
        token.approve(address(vault_), amount_);
        vault_.deposit(amount_, address(dispatcher));
    }

    function _update(address[] memory vaults_, bool allowed_, bool replace_) private returns (bytes32 id) {
        executor.updateVaults(REMOTE_CHAIN, vaults_, allowed_, replace_, 0, address(0), 3_000_000);
        return executor.activeCommand(REMOTE_CHAIN);
    }

    function _remove(address vault_) private returns (bytes32 id) {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        return _update(vaults, false, false);
    }

    function _allowMany(uint256 count_) private returns (address[] memory added) {
        added = new address[](count_);
        for (uint256 i; i < count_; ++i) {
            added[i] = address(new MockRemoteVault(IERC20(address(token)), "M", "M"));
        }
        _update(added, true, false);
    }

    function _count(Vm.Log[] memory logs_, bytes32 topic0_) private view returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(dispatcher) && logs_[i].topics[0] == topic0_) ++n;
        }
    }

    // ------------------------------------------------------------------ clean sweep

    function testShouldSweepCleanlyAndUntrackOnRemoval() public {
        _bridge(100e18);
        _position(vaultA, 50e18);
        uint64 epochBefore = dispatcher.commandConfigEpoch();

        vm.recordLogs();
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 50e18, 50e18);
        bytes32 id = _remove(address(vaultA));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(id, bytes32(0), "UPDATE_VAULTS acked"); // acked: no active command left
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "epoch advanced");
        assertEq(
            _count(logs, keccak256("TrackedVaultSweepResidual(address,uint256,uint8,bytes4,bool)")),
            0,
            "no residual"
        );
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "off the allowlist");
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "position redeemed");
        assertEq(dispatcher.trackedIdle(), 150e18, "measured assets credited to idle");
        assertEq(token.balanceOf(address(dispatcher)), 150e18, "assets on the dispatcher");
        assertEq(dispatcher.accountedBalance(), 150e18, "NAV unchanged by the move into idle");
    }

    function testShouldSkipTheRedeemForADonatedWeiAndFreeTheSlot() public {
        _position(vaultA, 1);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 1, 4, bytes4(0), true);
        _remove(address(vaultA));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "dust holder untracked");
        assertEq(dispatcher.trackedVaultsLength(), 1, "slot freed");
        assertEq(vaultA.balanceOf(address(dispatcher)), 1, "the wei stays: redeem was never called");
    }

    // ------------------------------------------------------------------ exact lane gas (D-061)

    /// @dev Holds an UPDATE_VAULTS removal of `vault_` so it can be delivered with an exact gas limit.
    function _holdRemove(address vault_) private returns (uint256 held) {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        router.setAutoDeliver(false);
        executor.updateVaults(REMOTE_CHAIN, vaults, false, false, 0, address(0), 3_000_000);
        router.setAutoDeliver(true);
        held = router.heldCount() - 1;
    }

    function _deliverExactAndRevert(uint256 held_, uint256 gas_) private returns (bool ok) {
        uint256 snap = vm.snapshotState();
        (ok, ) = address(router).call(abi.encodeCall(MockCcipRouter.deliverHeldExact, (held_, gas_)));
        vm.revertToState(snap);
    }

    /// @dev The usual 3,000,000 lane limit: a 1-wei donation of shares no longer blocks the removal (it used to
    ///      cost a full capped redeem and fail the delivery).
    function testShouldDeliverARemovalWithADonatedWeiAtTheThreeMillionLaneLimit() public {
        _position(vaultA, 1);
        uint256 held = _holdRemove(address(vaultA));
        (bool ok, ) = address(router).call(abi.encodeCall(MockCcipRouter.deliverHeldExact, (held, 3_000_000)));
        assertTrue(ok, "delivered at exactly 3M");
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "off the allowlist");
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 1, "wei untouched");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "acked");
    }

    /// @dev D-065: a removal that must redeem a real position has NO sweep gas threshold of its own. At the 3M lane
    ///      limit the redeem runs (position swept into idle, NAV unchanged), and at the smallest gas the command itself
    ///      accepts (the IL-8625 budget) the delivery still succeeds and the vault is untracked: whatever the redeem
    ///      could not do is a reported residual, never a revert. Reaches the redeem path: with the dust check forced
    ///      to `true` the position would stay on the dispatcher and the first block fails.
    function testShouldSweepARealPositionAtTheThreeMillionLaneLimitAndNeverRevertForSweepGas() public {
        _bridge(100e18);
        _position(vaultA, 50e18);
        uint256 held = _holdRemove(address(vaultA));

        uint256 snap = vm.snapshotState();
        (bool ok, ) = address(router).call(abi.encodeCall(MockCcipRouter.deliverHeldExact, (held, 3_000_000)));
        assertTrue(ok, "delivered at exactly 3M");
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "redeem path reached: position swept");
        assertEq(dispatcher.trackedIdle(), 150e18, "assets credited to idle");
        assertEq(dispatcher.accountedBalance(), 150e18, "NAV unchanged");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "acked");
        vm.revertToState(snap);

        // Smallest gas the command accepts: bisect on revert / no revert of the delivery.
        uint256 lo = 0;
        uint256 hi = 3_000_000;
        assertTrue(_deliverExactAndRevert(held, hi), "3M delivers");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_deliverExactAndRevert(held, mid)) hi = mid;
            else lo = mid;
        }
        assertGt(hi, CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, "the edge is the command budget, not the sweep");
        (ok, ) = address(router).call(abi.encodeCall(MockCcipRouter.deliverHeldExact, (held, hi)));
        assertTrue(ok, "delivered at the command minimum");
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked at the minimum");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "acked at the minimum");
    }

    /// @dev Value just above the dust bound (0.01 token for an 18-decimal asset) still takes the redeem path.
    function testShouldNotTreatValueAboveTheDustBoundAsDust() public {
        _bridge(100e18);
        _position(vaultA, 1e16 + 1);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 1e16 + 1, 1e16 + 1);
        _remove(address(vaultA));
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "redeemed");
    }

    function testShouldNotEmitAnythingForARemovedVaultWithoutShares() public {
        vm.recordLogs();
        _remove(address(vaultA));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, keccak256("TrackedVaultSwept(address,uint256,uint256)")), 0, "no sweep event");
        assertEq(
            _count(logs, keccak256("TrackedVaultSweepResidual(address,uint256,uint8,bytes4,bool)")),
            0,
            "no residual"
        );
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }

    function testShouldSweepWhenMaxRedeemReverts() public {
        _position(vaultA, 50e18);
        vaultA.setMaxRedeemFaults(true, false, 0);
        _remove(address(vaultA));
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "redeemed through the balance fallback");
        assertEq(dispatcher.trackedIdle(), 50e18, "idle credited");
    }

    function testShouldSweepWhenRedeemReturnsNothing() public {
        _position(vaultA, 50e18);
        vaultA.setRedeemFaults(false, false, true, false);
        _remove(address(vaultA));
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "redeemed");
        assertEq(dispatcher.trackedIdle(), 50e18, "idle credited from the measured delta");
    }

    // ------------------------------------------------------------------ legitimate failures: residual + untrack (D-028 B)

    function testShouldReportARevertingRedeemAndStillUntrack() public {
        _bridge(100e18);
        _position(vaultA, 50e18);
        vaultA.setRedeemFaults(true, false, false, false);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, 2, MockFaultyVault.RedeemBroken.selector, true);
        bytes32 id = _remove(address(vaultA));

        assertEq(id, bytes32(0), "the command still succeeds"); // acked: no active command left
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked although the redeem failed");
        assertEq(dispatcher.trackedVaultsLength(), 1, "slot freed");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "the shares stay on the dispatcher");
        assertEq(dispatcher.trackedIdle(), 100e18, "idle unchanged");
        assertEq(dispatcher.accountedBalance(), 100e18, "the residual is outside NAV until re-allowlisted");
    }

    function testShouldReportAPartialRedeemAndStillUntrack() public {
        _position(vaultA, 50e18);
        vaultA.setMaxRedeemFaults(false, true, 20e18);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 20e18, 20e18);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 30e18, 3, bytes4(0), true);
        _remove(address(vaultA));

        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(dispatcher.trackedIdle(), 20e18, "only the redeemed part is idle");
        assertEq(vaultA.balanceOf(address(dispatcher)), 30e18, "residual stays");
    }

    function testShouldReportAnUnreadableVaultAndStillUntrack() public {
        _position(vaultA, 50e18);
        vaultA.setFaults(true, false, false);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 0, 1, bytes4(0), true);
        _remove(address(vaultA));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }

    // ------------------------------------------------------------------ gas

    /// @dev A redeem that burns every gas it is given is cut off at `VAULT_SWEEP_GAS`: the command still succeeds and
    ///      the whole delivery stays far below an uncapped burn. Dropping the cap burns the 1/64-reserved remainder of
    ///      the test's gas and fails the command.
    function testShouldNotLetAGasBurningRedeemBreakTheCommand() public {
        _position(vaultA, 50e18);
        vaultA.setRedeemFaults(false, true, false, false);

        uint256 gasBefore = gasleft();
        bytes32 id = _remove(address(vaultA));
        uint256 used = gasBefore - gasleft();

        assertEq(id, bytes32(0), "command succeeded"); // acked: no active command left
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "residual stays");
        assertLt(used, 4_000_000, "bounded by the sweep cap, not by the available gas");
    }

    function testShouldNotLetAReturndataBombBreakTheCommand() public {
        _position(vaultA, 50e18);
        vaultA.setRedeemFaults(false, false, false, true);
        bytes32 id = _remove(address(vaultA));
        assertEq(id, bytes32(0), "command succeeded"); // acked: no active command left
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }

    // ------------------------------------------------------------------ slots (IL-8629 / IL-8784)

    /// @dev Without untrack-after-failure the failing vault keeps its slot and the 33rd vault cannot be added.
    function testShouldFreeASlotForAThirtyThirdVaultAfterAFailedSweep() public {
        _position(vaultA, 50e18);
        vaultA.setRedeemFaults(true, false, false, false);
        _allowMany(30); // A + B + 30 = 32 tracked
        assertEq(dispatcher.trackedVaultsLength(), 32, "at the cap");

        MockRemoteVault extra = new MockRemoteVault(IERC20(address(token)), "X", "X");
        address[] memory one = new address[](1);
        one[0] = address(extra);
        uint256 snapshot = vm.snapshotState();
        bytes32 rejected = _update(one, true, false);
        assertEq(
            uint8(executor.commandStatus(rejected)),
            uint8(CommandStatus.FAILED),
            "33rd vault rejected at the cap"
        );
        vm.revertToState(snapshot);

        _remove(address(vaultA)); // the redeem fails, the slot is freed
        assertEq(dispatcher.trackedVaultsLength(), 31, "slot freed");
        bytes32 accepted = _update(one, true, false);
        assertEq(accepted, bytes32(0), "now accepted"); // acked: no active command left
        assertTrue(dispatcher.isTrackedVault(address(extra)), "tracked");
        assertEq(dispatcher.trackedVaultsLength(), 32, "back at the cap");
    }

    /// @dev IL-8629: at the cap a replace that swaps one vault for another must remove before it adds.
    function testShouldReplaceAtTheCapWithAnEmptyVault() public {
        address[] memory added = _allowMany(30);
        assertEq(dispatcher.trackedVaultsLength(), 32, "at the cap");

        MockRemoteVault fresh = new MockRemoteVault(IERC20(address(token)), "F", "F");
        address[] memory next = new address[](32);
        next[0] = address(vaultA);
        for (uint256 i; i < 30; ++i) {
            next[i + 1] = added[i];
        }
        next[31] = address(fresh); // vaultB leaves, `fresh` enters
        bytes32 id = _update(next, true, true);

        assertEq(id, bytes32(0), "replace at the cap succeeds"); // acked: no active command left
        assertFalse(dispatcher.isTrackedVault(address(vaultB)), "B left");
        assertTrue(dispatcher.isTrackedVault(address(fresh)), "fresh entered");
        assertEq(dispatcher.trackedVaultsLength(), 32, "cap respected");
    }

    function testShouldSweepEveryReplacedOutVaultInOneCommand() public {
        _bridge(10e18);
        _position(vaultA, 30e18);
        _position(vaultB, 40e18);
        _update(new address[](0), true, true);
        assertEq(dispatcher.trackedVaultsLength(), 0, "both removed");
        assertEq(dispatcher.trackedIdle(), 80e18, "both positions credited to idle");
        assertEq(dispatcher.accountedBalance(), 80e18, "NAV intact");
    }

    // ------------------------------------------------------------------ re-adding

    /// @dev The tracked set follows the allowlist on CCIP: a re-allowlisted vault with a residual is priced again.
    function testShouldPriceTheResidualAgainWhenTheVaultIsAllowlistedAgain() public {
        _bridge(100e18);
        _position(vaultA, 50e18);
        vaultA.setRedeemFaults(true, false, false, false);
        _remove(address(vaultA));
        assertEq(dispatcher.accountedBalance(), 100e18, "residual outside NAV");

        vaultA.setRedeemFaults(false, false, false, false);
        address[] memory one = new address[](1);
        one[0] = address(vaultA);
        _update(one, true, false);
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "tracked again");
        assertEq(dispatcher.accountedBalance(), 150e18, "the residual is back in NAV");
        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.unpricedCount, 0, "priced");
    }

    // ------------------------------------------------------------------ IL-8844: residual share allowance (D-074)

    /// @dev Removal with a reverting redeem leaves the vault neither allowlisted nor tracked, so a rescue `approve` on
    ///      it is schedulable. Re-allowlisting before the delay elapses makes execute refuse it.
    function _removeWithResidual() private {
        _bridge(100e18);
        _position(vaultA, 50e18);
        vaultA.setRedeemFaults(true, false, false, false);
        _remove(address(vaultA));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "neither allowlisted nor tracked");
        vaultA.setRedeemFaults(false, false, false, false);
    }

    function _reAdd() private {
        address[] memory one = new address[](1);
        one[0] = address(vaultA);
        _update(one, true, false);
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "tracked again");
    }

    function testShouldRefuseAResidualApproveAtExecuteOnceTheVaultIsAllowlistedAgain() public {
        _removeWithResidual();
        address spender = address(0xBAD);
        bytes memory cd = abi.encodeCall(IERC20.approve, (spender, type(uint256).max));
        vm.prank(RESCUE_ADMIN);
        uint256 id = dispatcher.scheduleRescue(address(vaultA), 0, cd);

        _reAdd();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vaultA)));
        dispatcher.executeRescue(id, cd);
        assertEq(vaultA.allowance(address(dispatcher), spender), 0, "no allowance was granted");
    }

    function testShouldKeepAResidualAllowanceExecutedWhileTheVaultWasOut() public {
        _removeWithResidual();
        address spender = address(0xBAD);
        bytes memory cd = abi.encodeCall(IERC20.approve, (spender, type(uint256).max));
        vm.prank(RESCUE_ADMIN);
        uint256 id = dispatcher.scheduleRescue(address(vaultA), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeRescue(id, cd); // the vault is still out: the fence does not apply

        _reAdd();
        assertEq(
            vaultA.allowance(address(dispatcher), spender),
            type(uint256).max,
            "the allowance survives the re-add"
        );

        bytes memory revoke = abi.encodeCall(IERC20.approve, (spender, 0));
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vaultA)));
        dispatcher.scheduleRescue(address(vaultA), 0, revoke);
    }

    function testShouldClearAResidualAllowanceRevokedBeforeTheReAdd() public {
        _removeWithResidual();
        address spender = address(0xBAD);
        bytes memory grant = abi.encodeCall(IERC20.approve, (spender, type(uint256).max));
        vm.prank(RESCUE_ADMIN);
        uint256 id = dispatcher.scheduleRescue(address(vaultA), 0, grant);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeRescue(id, grant);
        assertEq(vaultA.allowance(address(dispatcher), spender), type(uint256).max, "granted while out");

        bytes memory revoke = abi.encodeCall(IERC20.approve, (spender, 0));
        vm.prank(RESCUE_ADMIN);
        uint256 revokeId = dispatcher.scheduleRescue(address(vaultA), 0, revoke);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeRescue(revokeId, revoke);

        _reAdd();
        assertEq(vaultA.allowance(address(dispatcher), spender), 0, "runbook: revoke first, then re-add");
    }
}

/// @title StargateVaultRemovalSweepTest
/// @notice IL-8784 on the Stargate dispatcher: UPDATE_VAULTS sweeps and untracks removed vaults, frees their slots
///         (IL-8644) and re-allowlisting a vault that still holds shares resumes tracking immediately.
contract StargateVaultRemovalSweepTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");

    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockFaultyVault internal vault;
    StargateCrosschainDispatcher internal dispatcher;
    uint256 internal nonce;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vault = new MockFaultyVault(IERC20(address(usdc)), "Vault", "VLT");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(0xF),
            admin,
            guardian,
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _deliver(bytes memory envelope_) private {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

    function _setVaults(address[] memory vaults_) private {
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256(abi.encode("uv", ++nonce)),
                    sequence: dispatcher.nextCommandSequence(),
                    newConfigEpoch: dispatcher.commandConfigEpoch() + 1,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults_
                })
            )
        );
    }

    function _one(address v_) private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = v_;
    }

    function _compose(uint256 amountLD_) private {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory composeMsg = LzComposeBuilder.build(
            address(dispatcher),
            EXECUTOR_EID,
            amountLD_,
            CrosschainMessages.encodeOutboundTransfer(
                OutboundTransfer({transferId: keccak256(abi.encode("c", ++nonce))})
            )
        );
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    function _deposit(address v_, uint256 amountSD_) private returns (bytes32 id) {
        id = keccak256(abi.encode("dep", ++nonce));
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: id,
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(v_, amountSD_, 0)
                })
            )
        );
    }

    function _tracked(address v_) private view returns (bool) {
        return dispatcher.isTrackedVault(v_);
    }

    // ------------------------------------------------------------------ tests

    function testShouldSweepAndUntrackARemovedVault() public {
        _setVaults(_one(address(vault)));
        _compose(100e6);
        _deposit(address(vault), 50e6);
        assertTrue(_tracked(address(vault)), "tracked after the deposit");
        assertEq(dispatcher.trackedIdle(), 50e6, "idle after the deposit");

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vault), 50e6, 50e6);
        _setVaults(new address[](0));

        assertFalse(dispatcher.isAllowedVault(address(vault)), "off the allowlist");
        assertFalse(_tracked(address(vault)), "untracked");
        assertEq(vault.balanceOf(address(dispatcher)), 0, "redeemed");
        assertEq(dispatcher.trackedIdle(), 100e6, "assets credited to idle");
        assertEq(dispatcher.getTrackedVaults().length, 0, "set empty");
    }

    /// @dev A 1-wei share donation (6-decimal asset: the dust bound is 10,000 units) skips the redeem even
    ///      when `redeem` would revert, and the vault is untracked with reason 4.
    function testShouldSkipTheRedeemForADonatedWeiAndUntrack() public {
        usdc.mint(address(this), 1);
        usdc.approve(address(vault), 1);
        vault.deposit(1, address(dispatcher));
        _setVaults(_one(address(vault))); // allowlisting tracks a vault the dispatcher already holds shares of
        assertTrue(_tracked(address(vault)), "tracked through its donated share");
        vault.setRedeemFaults(true, false, false, false);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 1, 4, bytes4(0), true);
        _setVaults(new address[](0));

        assertFalse(_tracked(address(vault)), "untracked");
        assertEq(vault.balanceOf(address(dispatcher)), 1, "redeem never called");
    }

    function testShouldReportARevertingRedeemAndStillUntrack() public {
        _setVaults(_one(address(vault)));
        _compose(100e6);
        _deposit(address(vault), 50e6);
        vault.setRedeemFaults(true, false, false, false);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 50e6, 2, MockFaultyVault.RedeemBroken.selector, true);
        _setVaults(new address[](0));

        assertEq(dispatcher.commandConfigEpoch(), 2, "the UPDATE_VAULTS still applied");
        assertFalse(_tracked(address(vault)), "untracked although the redeem failed");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "shares stay");
        assertEq(dispatcher.trackedIdle(), 50e6, "idle unchanged");
    }

    function testShouldReportAPartialRedeemAndStillUntrack() public {
        _setVaults(_one(address(vault)));
        _compose(100e6);
        _deposit(address(vault), 50e6);
        vault.setMaxRedeemFaults(false, true, 20e6);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vault), 20e6, 20e6);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 30e6, 3, bytes4(0), true);
        _setVaults(new address[](0));

        assertFalse(_tracked(address(vault)), "untracked");
        assertEq(dispatcher.trackedIdle(), 70e6, "only the redeemed part is idle");
    }

    function testShouldNotLetAGasBurningRedeemBreakUpdateVaults() public {
        _setVaults(_one(address(vault)));
        _compose(100e6);
        _deposit(address(vault), 50e6);
        vault.setRedeemFaults(false, true, false, false);

        uint256 gasBefore = gasleft();
        _setVaults(new address[](0));
        uint256 used = gasBefore - gasleft();

        assertEq(dispatcher.commandConfigEpoch(), 2, "the UPDATE_VAULTS applied");
        assertFalse(_tracked(address(vault)), "untracked");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "shares stay");
        assertLt(used, 4_000_000, "bounded by the sweep cap");
    }

    /// @dev IL-8644: a removed vault must free its slot, so a deposit into a 33rd distinct vault succeeds. Without the
    ///      untrack after a failed sweep the removed vault keeps its slot and the deposit reverts `VaultsCapReached`.
    function testShouldFreeTheSlotOfARemovedVaultForAThirtyThirdDeposit() public {
        address[] memory all = new address[](32);
        all[0] = address(vault);
        for (uint256 i = 1; i < 32; ++i) {
            all[i] = address(new MockRemoteVault(IERC20(address(usdc)), "M", "M"));
        }
        _setVaults(all);
        _compose(100e6);
        for (uint256 i; i < 32; ++i) {
            _deposit(all[i], 1e6);
        }
        assertEq(dispatcher.getTrackedVaults().length, 32, "at the tracked cap");
        vault.setRedeemFaults(true, false, false, false);

        MockRemoteVault extra = new MockRemoteVault(IERC20(address(usdc)), "X", "X");
        address[] memory next = new address[](32);
        next[0] = address(extra);
        for (uint256 i = 1; i < 32; ++i) {
            next[i] = all[i];
        }
        _setVaults(next); // `vault` leaves, its redeem fails

        assertEq(dispatcher.getTrackedVaults().length, 31, "slot freed");
        bytes32 id = _deposit(address(extra), 1e6);
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "33rd distinct vault deposited");
        assertTrue(_tracked(address(extra)), "tracked");
        assertEq(dispatcher.getTrackedVaults().length, 32, "back at the cap");
    }

    /// @dev Re-allowlisting a vault that still holds a residual resumes tracking at once (no new deposit needed).
    function testShouldResumeTrackingWhenAResidualVaultIsAllowlistedAgain() public {
        _setVaults(_one(address(vault)));
        _compose(100e6);
        _deposit(address(vault), 50e6);
        vault.setRedeemFaults(true, false, false, false);
        _setVaults(new address[](0));
        assertFalse(_tracked(address(vault)), "untracked");

        vault.setRedeemFaults(false, false, false, false);
        _setVaults(_one(address(vault)));
        assertTrue(_tracked(address(vault)), "tracked again, so the residual is valued");
        assertEq(dispatcher.getTrackedVaults().length, 1, "exactly once");

        _setVaults(_one(address(vault))); // idempotent: still one entry
        assertEq(dispatcher.getTrackedVaults().length, 1, "no duplicate");
    }

    /// @dev IL-8849 (D-073): the re-track pass needs a working `balanceOf`. A residual vault whose read reverts is
    ///      allowlisted but skipped silently (no event); the next UPDATE_VAULTS after the read works tracks it.
    function testShouldNotRetrackAResidualVaultWhileItsBalanceOfReverts() public {
        _setVaults(_one(address(vault)));
        _compose(100e6);
        _deposit(address(vault), 50e6);
        vault.setRedeemFaults(true, false, false, false);
        vm.expectEmit(address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 50e6, 2, MockFaultyVault.RedeemBroken.selector, true);
        _setVaults(new address[](0));
        assertFalse(_tracked(address(vault)), "residual untracked");

        vault.setFaults(true, false, false); // balanceOf reverts
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        _setVaults(_one(address(vault)));
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "the update is ACKed");
        assertTrue(dispatcher.isAllowedVault(address(vault)), "allowlisted");
        assertFalse(_tracked(address(vault)), "not tracked: the read failed");
        assertEq(dispatcher.getTrackedVaults().length, 0, "tracked set stays empty");

        vault.setFaults(false, false, false);
        _setVaults(_one(address(vault)));
        assertTrue(_tracked(address(vault)), "tracked once balanceOf works");
        assertEq(dispatcher.getTrackedVaults().length, 1, "exactly once");
    }

    function testShouldNotTrackAnAllowlistedVaultWithoutShares() public {
        _setVaults(_one(address(vault)));
        assertFalse(_tracked(address(vault)), "no position, no tracking");
    }

    // ------------------------------------------------------------------ IL-8844: residual share allowance (D-074)

    /// @dev Removal with a reverting redeem leaves the vault neither allowlisted nor tracked, so a rescue `approve` on
    ///      it is schedulable. Re-allowlisting before the delay elapses makes execute refuse it.
    function _removeWithResidualSg() private {
        _setVaults(_one(address(vault)));
        _compose(100e6);
        _deposit(address(vault), 50e6);
        vault.setRedeemFaults(true, false, false, false);
        _setVaults(new address[](0));
        assertFalse(_tracked(address(vault)), "untracked");
        assertFalse(dispatcher.isAllowedVault(address(vault)), "not allowlisted");
        vault.setRedeemFaults(false, false, false, false);
    }

    function _reAddSg() private {
        _setVaults(_one(address(vault)));
        assertTrue(_tracked(address(vault)), "tracked again");
    }

    function testShouldRefuseAResidualApproveAtExecuteOnceTheVaultIsAllowlistedAgain() public {
        _removeWithResidualSg();
        address spender = address(0xBAD);
        bytes memory cd = abi.encodeCall(IERC20.approve, (spender, type(uint256).max));
        vm.prank(admin);
        uint256 id = dispatcher.scheduleRescue(address(vault), 0, cd);

        _reAddSg();
        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vault)));
        dispatcher.executeRescue(id, cd);
        assertEq(vault.allowance(address(dispatcher), spender), 0, "no allowance was granted");
    }

    function testShouldKeepAResidualAllowanceExecutedWhileTheVaultWasOut() public {
        _removeWithResidualSg();
        address spender = address(0xBAD);
        bytes memory cd = abi.encodeCall(IERC20.approve, (spender, type(uint256).max));
        vm.prank(admin);
        uint256 id = dispatcher.scheduleRescue(address(vault), 0, cd);
        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        dispatcher.executeRescue(id, cd); // the vault is still out: the fence does not apply

        _reAddSg();
        assertEq(vault.allowance(address(dispatcher), spender), type(uint256).max, "the allowance survives the re-add");

        bytes memory revoke = abi.encodeCall(IERC20.approve, (spender, 0));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vault)));
        dispatcher.scheduleRescue(address(vault), 0, revoke);
    }

    function testShouldClearAResidualAllowanceRevokedBeforeTheReAdd() public {
        _removeWithResidualSg();
        address spender = address(0xBAD);
        bytes memory grant = abi.encodeCall(IERC20.approve, (spender, type(uint256).max));
        vm.prank(admin);
        uint256 id = dispatcher.scheduleRescue(address(vault), 0, grant);
        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        dispatcher.executeRescue(id, grant);
        assertEq(vault.allowance(address(dispatcher), spender), type(uint256).max, "granted while out");

        bytes memory revoke = abi.encodeCall(IERC20.approve, (spender, 0));
        vm.prank(admin);
        uint256 revokeId = dispatcher.scheduleRescue(address(vault), 0, revoke);
        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        dispatcher.executeRescue(revokeId, revoke);

        _reAddSg();
        assertEq(vault.allowance(address(dispatcher), spender), 0, "runbook: revoke first, then re-add");
    }
}

/// @notice IL-8839 (D-071): the re-track pass (reads and writes) runs BEFORE the sweeps, so after a gas-limited sweep
///         only the removal's own bookkeeping remains and one removal never NACKs because the re-track reads ran out
///         of gas. Storage is cooled (`vm.cool`, forge 1.8.5) so the reads are priced cold, as on a real chain.
contract StargateVaultRemovalLaneGasTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");
    uint256 internal constant WIDE_LANE = 4_000_000;

    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockFaultyVault internal vault;
    StargateCrosschainDispatcher internal dispatcher;
    uint256 internal nonce;
    address[] internal empties;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        _build(6);
    }

    // ------------------------------------------------------------------ helpers

    function _build(uint8 assetDecimals_) private {
        usdc = new MockERC20("USD Coin", "USDC", assetDecimals_);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vault = new MockFaultyVault(IERC20(address(usdc)), "Vault", "VLT");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(0xF),
            admin,
            guardian,
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);
    }

    function _updateVaults(
        address[] memory vaults_,
        uint64 minExecutionGas_
    ) private returns (bytes32 id, bytes memory envelope) {
        id = keccak256(abi.encode("uv", ++nonce));
        envelope = CrosschainMessages.encodeUpdateVaults(
            UpdateVaults({
                commandId: id,
                sequence: dispatcher.nextCommandSequence(),
                newConfigEpoch: dispatcher.commandConfigEpoch() + 1,
                minExecutionGas: minExecutionGas_,
                vaults: vaults_
            })
        );
    }

    function _setVaults(address[] memory vaults_) private {
        (, bytes memory envelope) = _updateVaults(vaults_, DEFAULT_COMMAND_BUDGET);
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope
        );
    }

    /// @dev Delivers an UPDATE_VAULTS with exactly `lane_` gas and the budget the executor would stamp for that lane,
    ///      with the dispatcher and every vault in `cold_` cooled first.
    function _removeAtLane(
        address[] memory vaults_,
        uint256 lane_,
        address[] memory cold_
    ) private returns (bytes32 id) {
        (, bytes memory probe) = _updateVaults(vaults_, 0);
        (, bytes memory payload) = CrosschainMessages.decodeEnvelope(probe);
        uint64 budget = CrosschainMessages.commandGasBudget(
            lane_,
            CrosschainMessages.payloadWords(payload.length),
            true
        );
        bytes memory envelope;
        (id, envelope) = _updateVaults(vaults_, budget);
        vm.cool(address(dispatcher));
        for (uint256 i; i < cold_.length; ++i) {
            vm.cool(cold_[i]);
        }
        endpoint.deliverLz{gas: lane_}(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope
        );
    }

    function _compose(uint256 amountLD_) private {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory composeMsg = LzComposeBuilder.build(
            address(dispatcher),
            EXECUTOR_EID,
            amountLD_,
            CrosschainMessages.encodeOutboundTransfer(
                OutboundTransfer({transferId: keccak256(abi.encode("c", ++nonce))})
            )
        );
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    function _deposit(address v_, uint256 amountSD_) private {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256(abi.encode("dep", ++nonce)),
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(v_, amountSD_, 0)
                })
            )
        );
    }

    /// @dev Allowlist = `vault` + `emptyCount_` empty vaults, 50e6 deposited into `vault` (redeem burns all gas).
    ///      Returns the allowlist after the removal (the empties only) and every vault of the scenario (cold set).
    function _scenario(uint256 emptyCount_) private returns (address[] memory keep, address[] memory all) {
        all = new address[](emptyCount_ + 1);
        keep = new address[](emptyCount_);
        all[0] = address(vault);
        for (uint256 i; i < emptyCount_; ++i) {
            address e = address(new MockRemoteVault(IERC20(address(usdc)), "E", "E"));
            empties.push(e);
            all[i + 1] = e;
            keep[i] = e;
        }
        _setVaults(all);
        _compose(100e6);
        _deposit(address(vault), 50e6);
        assertTrue(dispatcher.isTrackedVault(address(vault)), "position tracked");
        vault.setRedeemFaults(false, true, false, false);
    }

    function _assertRemovedWithBurnedSweep(bytes32 id, uint64 epochBefore) private view {
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "ACKed, not a NACK");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "epoch advanced");
        assertFalse(dispatcher.isAllowedVault(address(vault)), "off the allowlist");
        assertFalse(dispatcher.isTrackedVault(address(vault)), "untracked");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "burned redeem leaves the shares");
    }

    function _removalAtLane(uint256 lane_, uint256 emptyCount_, uint8 reason_) private {
        (address[] memory keep, address[] memory all) = _scenario(emptyCount_);
        uint64 epochBefore = dispatcher.commandConfigEpoch();

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 50e6, reason_, bytes4(0), true);
        bytes32 id = _removeAtLane(keep, lane_, all);

        _assertRemovedWithBurnedSweep(id, epochBefore);
        assertEq(dispatcher.getTrackedVaults().length, 0, "tracked set empty");
        assertEq(dispatcher.trackedIdle(), 50e6, "nothing swept into idle");
    }

    // ------------------------------------------------------------------ tests

    /// @dev Control: with two empty vaults the removal also passes on the old order, so the 31-vault failure below is
    ///      caused by the re-track reads after the burned sweep, not by the scenario itself.
    function testShouldAckOneRemovalWithABurnedSweepAndTwoEmptyVaultsAtFourMillion() public {
        _removalAtLane(WIDE_LANE, 2, 2); // roomy: the full 2M forward is burned (reason 2)
    }

    function testShouldAckOneRemovalWithABurnedSweepAndThirtyOneEmptyVaultsAtFourMillion() public {
        _removalAtLane(WIDE_LANE, 31, 5); // tight: the forward is gas-limited (reason 5)
    }

    /// @dev Ten allowlisted vaults hold a donated share after the allowlist was set, so the removal command must
    ///      re-track all ten (cold reads and new tracking slots) AND sweep the burned position. Re-tracking before the
    ///      sweep (B) fits; buffering the reads and writing after the sweep (A) does not.
    function testShouldRetrackTenDonatedVaultsAndRemoveOneWithABurnedSweepAtFourMillion() public {
        (address[] memory keep, address[] memory all) = _scenario(31);
        for (uint256 i; i < 10; ++i) {
            usdc.mint(address(this), 1);
            usdc.approve(empties[i], 1);
            MockRemoteVault(empties[i]).deposit(1, address(dispatcher));
            assertFalse(dispatcher.isTrackedVault(empties[i]), "donation alone does not track");
        }
        uint64 epochBefore = dispatcher.commandConfigEpoch();

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 50e6, 5, bytes4(0), true);
        bytes32 id = _removeAtLane(keep, WIDE_LANE, all);

        _assertRemovedWithBurnedSweep(id, epochBefore);
        assertEq(dispatcher.getTrackedVaults().length, 10, "the ten donated vaults are tracked");
        for (uint256 i; i < 10; ++i) {
            assertTrue(dispatcher.isTrackedVault(empties[i]), "donated vault re-tracked");
        }
    }

    /// @dev LD != SD (18-decimal asset, 6 shared decimals, rate 1e12) and a share price above 1: the sweep credits
    ///      `floor(assetsLD / 1e12)` to `trackedIdle`; the sub-1e12 remainder is surplus a rescue may take, one more
    ///      unit of the shared precision may not.
    function testShouldCreditTheFlooredSweepWhenLocalDecimalsExceedShared() public {
        _build(18);
        address[] memory one = new address[](1);
        one[0] = address(vault);
        _setVaults(one);
        _compose(100e18);
        _deposit(address(vault), 50e6);
        assertEq(dispatcher.trackedIdle(), 50e6, "idle after the deposit (SD)");
        usdc.mint(address(vault), 123_456_789_123); // donation lifts the share price above 1

        uint256 shares = vault.balanceOf(address(dispatcher));
        uint256 assetsLD = vault.previewRedeem(shares);
        uint256 remainder = assetsLD % 1e12;
        assertGt(remainder, 0, "the redeemed amount is not a multiple of the conversion rate");
        assertGt(assetsLD, 50e18, "share price above 1");

        _setVaults(new address[](0));

        assertFalse(dispatcher.isTrackedVault(address(vault)), "untracked");
        assertEq(vault.balanceOf(address(dispatcher)), 0, "fully redeemed");
        assertEq(dispatcher.trackedIdle(), 50e6 + assetsLD / 1e12, "credit is the floored shared amount");
        assertEq(usdc.balanceOf(address(dispatcher)), 50e18 + assetsLD, "balance holds the full redeemed amount");

        // One shared unit above the surplus would cut into tracked value.
        bytes memory tooMuch = abi.encodeCall(IERC20.transfer, (admin, remainder + 1e12));
        vm.prank(admin);
        uint256 badId = dispatcher.scheduleRescue(address(usdc), 0, tooMuch);
        bytes memory exact = abi.encodeCall(IERC20.transfer, (admin, remainder));
        vm.prank(admin);
        uint256 goodId = dispatcher.scheduleRescue(address(usdc), 0, exact);
        vm.warp(block.timestamp + 3 days);

        uint256 balance = usdc.balanceOf(address(dispatcher));
        uint256 trackedLD = (50e6 + assetsLD / 1e12) * 1e12;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueLedgerInvariantViolation.selector,
                balance - remainder - 1e12,
                trackedLD
            )
        );
        dispatcher.executeRescue(badId, tooMuch);

        vm.prank(admin);
        dispatcher.executeRescue(goodId, exact);
        assertEq(usdc.balanceOf(admin), remainder, "the remainder was rescued");
        assertEq(usdc.balanceOf(address(dispatcher)), trackedLD, "tracked value untouched");
    }
}

/// @notice IL-8839 (V2): lane sizing of one removal with a burned sweep, measured on COMMITTED state. The dispatcher,
///         the allowlist, the tracked position and the burn fault are installed in `setUp` (separate transactions), so
///         the removal's allowlist replace re-adds the kept vaults as ~100-gas restores of committed slots, as on a
///         real chain, instead of fresh ~40k writes. The command is delivered through `deliverLz{gas: lane}` with the
///         budget the executor stamps for that lane (`commandGasBudget`), and storage is cooled first. K kept
///         vaults are measured by removing `31 - K` of the 31 installed empty vaults together with `vault` (so for
///         K < 31 the replace pops a 32-vault list and slightly overstates the cost: K is a lower bound).
contract StargateVaultRemovalCommittedLaneTest is Test {
    using OptionsBuilder for bytes;

    /// @dev Measured on forge 1.8.5, 2026-10-20, IL-8839 T61.
    uint256 internal constant K_AT_MIN_LANE = 31; // all 31 kept vaults ACK at the 2.5M lane (K = 31, no K + 1)
    /// @dev Measured on forge 1.8.5, 2026-10-20, IL-8839 T61. Smallest lane (10k steps) with 31 kept vaults; it is the
    ///      floor of what `commandGasBudget` accepts (CommandLaneGasTooLow below 2,450,286), so the removal never
    ///      needs more than the minimum lane.
    uint256 internal constant LANE_FOR_31_KEPT = 2_460_000;
    /// @dev Measured on forge 1.8.5, 2026-10-20, IL-8839 T61. Adversarial delivery: the command is stamped for the
    ///      2.5M lane, the delivery gas is cut to the smallest value (1k steps) that still ACKs. Margin to 2.5M is
    ///      about 98k gas (4 percent); the per kept vault marginal cost is (EDGE_31 - EDGE_0) / 31, about 9.9k.
    uint256 internal constant EDGE_GAS_31_KEPT = 2_402_000;
    /// @dev Measured on forge 1.8.5, 2026-10-20, IL-8839 T61 (same method, 0 kept vaults).
    uint256 internal constant EDGE_GAS_0_KEPT = 2_095_000;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");
    uint256 internal constant MIN_LANE = 2_500_000;
    uint256 internal constant LANE_STEP = 10_000;
    uint256 internal constant EMPTIES = 31;

    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockFaultyVault internal vault;
    StargateCrosschainDispatcher internal dispatcher;
    uint256 internal nonce;
    address[] internal empties;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vault = new MockFaultyVault(IERC20(address(usdc)), "Vault", "VLT");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(0xF),
            admin,
            guardian,
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);

        address[] memory all = new address[](EMPTIES + 1);
        all[0] = address(vault);
        for (uint256 i; i < EMPTIES; ++i) {
            address e = address(new MockRemoteVault(IERC20(address(usdc)), "E", "E"));
            empties.push(e);
            all[i + 1] = e;
        }
        (, bytes memory envelope) = _updateVaults(all, DEFAULT_COMMAND_BUDGET);
        _deliver(envelope);
        _compose(100e6);
        _deposit(address(vault), 50e6);
        vault.setRedeemFaults(false, true, false, false);
    }

    // ------------------------------------------------------------------ helpers

    function _deliver(bytes memory envelope_) private {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

    function _updateVaults(
        address[] memory vaults_,
        uint64 minExecutionGas_
    ) private returns (bytes32 id, bytes memory envelope) {
        id = keccak256(abi.encode("uv", ++nonce));
        envelope = CrosschainMessages.encodeUpdateVaults(
            UpdateVaults({
                commandId: id,
                sequence: dispatcher.nextCommandSequence(),
                newConfigEpoch: dispatcher.commandConfigEpoch() + 1,
                minExecutionGas: minExecutionGas_,
                vaults: vaults_
            })
        );
    }

    function _compose(uint256 amountLD_) private {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory composeMsg = LzComposeBuilder.build(
            address(dispatcher),
            EXECUTOR_EID,
            amountLD_,
            CrosschainMessages.encodeOutboundTransfer(
                OutboundTransfer({transferId: keccak256(abi.encode("c", ++nonce))})
            )
        );
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    function _deposit(address v_, uint256 amountSD_) private {
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256(abi.encode("dep", ++nonce)),
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(v_, amountSD_, 0)
                })
            )
        );
    }

    /// @dev Delivers the removal of `vault` keeping the first `kept_` empties, with exactly `lane_` gas and the budget
    ///      the executor stamps for that lane, after cooling the dispatcher and every vault. `delivered` is false
    ///      when the delivery itself reverted (the lane cannot even run the command).
    function _attempt(uint256 kept_, uint256 lane_, uint256 gas_) private returns (bytes32 id, bool delivered) {
        address[] memory keep = new address[](kept_);
        for (uint256 i; i < kept_; ++i) {
            keep[i] = empties[i];
        }
        (, bytes memory probe) = _updateVaults(keep, 0);
        (, bytes memory payload) = CrosschainMessages.decodeEnvelope(probe);
        uint64 budget = CrosschainMessages.commandGasBudget(
            lane_,
            CrosschainMessages.payloadWords(payload.length),
            true
        );
        bytes memory envelope;
        (id, envelope) = _updateVaults(keep, budget);
        vm.cool(address(dispatcher));
        vm.cool(address(vault));
        for (uint256 i; i < empties.length; ++i) {
            vm.cool(empties[i]);
        }
        (delivered, ) = address(endpoint).call{gas: gas_}(
            abi.encodeCall(
                MockLzEndpoint.deliverLz,
                (address(dispatcher), EXECUTOR_EID, bytes32(uint256(uint160(address(dispatcher)))), GUID, envelope)
            )
        );
    }

    /// @dev True when one burned removal ACKs at this lane (SUCCEEDED and `vault` untracked). State is rolled back.
    function _acksAt(uint256 kept_, uint256 lane_, uint256 gas_) private returns (bool acked) {
        uint256 snap = vm.snapshotState();
        (bytes32 id, bool delivered) = _attempt(kept_, lane_, gas_);
        acked =
            delivered &&
            dispatcher.commandStatus(id) == CommandStatus.SUCCEEDED &&
            !dispatcher.isTrackedVault(address(vault));
        vm.revertToState(snap);
    }

    function _acks(uint256 kept_, uint256 lane_) private returns (bool) {
        return _acksAt(kept_, lane_, lane_);
    }

    /// @dev True when the delivery of gas `gas_` is accepted by the dispatcher (not reverted before the self-call).
    function _accepted(uint256 kept_, uint256 lane_, uint256 gas_) private returns (bool delivered) {
        uint256 snap = vm.snapshotState();
        (, delivered) = _attempt(kept_, lane_, gas_);
        vm.revertToState(snap);
    }

    /// @dev Smallest delivery gas (1k steps) the dispatcher accepts for a command stamped for `lane_` (the edge).
    function _acceptEdge(uint256 kept_, uint256 lane_) private returns (uint256) {
        uint256 lo = 1_000; // units of 1k, rejected
        uint256 hi = lane_ / 1_000; // accepted
        assertTrue(_accepted(kept_, lane_, hi * 1_000), "accepted at the lane");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_accepted(kept_, lane_, mid * 1_000)) hi = mid;
            else lo = mid;
        }
        return hi * 1_000;
    }

    /// @dev Smallest delivery gas (1k steps) that ACKs a command stamped for `lane_`.
    function _ackEdge(uint256 kept_, uint256 lane_) private returns (uint256) {
        uint256 lo = 1_000;
        uint256 hi = lane_ / 1_000;
        assertTrue(_acks(kept_, lane_), "ACKs at the lane");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_acksAt(kept_, lane_, mid * 1_000)) hi = mid;
            else lo = mid;
        }
        return hi * 1_000;
    }

    /// @dev Smallest lane (multiple of 10k) that ACKs with `kept_` kept vaults.
    function _minLane(uint256 kept_) private returns (uint256) {
        uint256 lo = 245; // 2,450,000: below the command budget formula's own floor (CommandLaneGasTooLow)
        uint256 hi = 500; // 5,000,000, must ACK
        assertTrue(_acks(kept_, hi * LANE_STEP), "5M lane ACKs");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_acks(kept_, mid * LANE_STEP)) hi = mid;
            else lo = mid;
        }
        return hi * LANE_STEP;
    }

    /// @dev Largest kept count (0..31) that ACKs at `lane_`.
    function _maxKept(uint256 lane_) private returns (uint256) {
        assertTrue(_acks(0, lane_), "0 kept ACKs");
        if (_acks(EMPTIES, lane_)) return EMPTIES;
        uint256 lo; // ACKs
        uint256 hi = EMPTIES; // does not ACK
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_acks(mid, lane_)) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function _assertBurnedRemovalAcked(bytes32 id, uint64 epochBefore) private view {
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "ACKed, not a NACK");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "epoch advanced");
        assertFalse(dispatcher.isAllowedVault(address(vault)), "off the allowlist");
        assertFalse(dispatcher.isTrackedVault(address(vault)), "untracked");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "burned redeem leaves the shares");
    }

    // ------------------------------------------------------------------ tests

    /// @dev Measures and logs the committed-state numbers; pins them to the named constants.
    function testShouldMeasureTheLaneRuleOfOneBurnedRemovalOnCommittedState() public {
        uint256 k = _maxKept(MIN_LANE);
        uint256 l31 = _minLane(EMPTIES);
        uint256 l0 = _minLane(0);
        emit log_named_uint("K: largest kept count that ACKs at the 2.5M minimum lane", k);
        emit log_named_uint("L31: smallest lane (10k steps) that ACKs with 31 kept vaults", l31);
        emit log_named_uint("L0: smallest lane (10k steps) that ACKs with 0 kept vaults", l0);
        emit log_named_uint("per kept vault marginal lane cost (gas, (L31 - L0) / 31)", (l31 - l0) / EMPTIES);
        emit log_named_uint(
            "command budget at the 2.5M lane with 31 kept",
            CrosschainMessages.commandGasBudget(MIN_LANE, CrosschainMessages.payloadWords(32 * 32 + 5 * 32), true)
        );

        uint256 edge31 = _ackEdge(EMPTIES, MIN_LANE);
        uint256 edge0 = _ackEdge(0, MIN_LANE);
        uint256 accept31 = _acceptEdge(EMPTIES, MIN_LANE);
        emit log_named_uint("EDGE: smallest delivery gas that ACKs, command stamped for 2.5M, 31 kept", edge31);
        emit log_named_uint("EDGE: smallest delivery gas that ACKs, command stamped for 2.5M, 0 kept", edge0);
        emit log_named_uint("EDGE: smallest delivery gas the dispatcher accepts (31 kept)", accept31);
        emit log_named_uint("EDGE: per kept vault marginal gas, (edge31 - edge0) / 31", (edge31 - edge0) / EMPTIES);

        assertEq(edge31, EDGE_GAS_31_KEPT, "ACK edge with 31 kept");
        assertEq(edge0, EDGE_GAS_0_KEPT, "ACK edge with 0 kept");
        assertLt(edge31, MIN_LANE, "31 kept fit the minimum lane");
        assertEq(k, K_AT_MIN_LANE, "K at the minimum lane");
        assertEq(l31, LANE_FOR_31_KEPT, "lane for 31 kept vaults");
        assertEq(k, EMPTIES, "no K + 1 exists");
    }

    /// @dev At the 2.5M minimum lane K kept vaults ACK with the burned sweep reported as a gas-limited residual.
    function testShouldAckABurnedRemovalWithKKeptVaultsAtTheMinimumLane() public {
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 50e6, 5, bytes4(0), true);
        (bytes32 id, bool delivered) = _attempt(K_AT_MIN_LANE, MIN_LANE, MIN_LANE);
        assertTrue(delivered, "delivered");
        _assertBurnedRemovalAcked(id, epochBefore);
        assertEq(dispatcher.trackedIdle(), 50e6, "nothing swept into idle");
    }

    /// @dev 31 kept vaults, command stamped for the 2.5M lane, delivered 1k below the ACK edge: the command is
    ///      accepted, runs out of gas inside the self-call and is NACKed (FAILED); everything rolls back and `vault`
    ///      stays allowlisted and tracked.
    function testShouldNackABurnedRemovalDeliveredJustBelowTheAckEdge() public {
        (bytes32 id, bool delivered) = _attempt(EMPTIES, MIN_LANE, EDGE_GAS_31_KEPT - 1_000);
        assertTrue(delivered, "accepted by the dispatcher");
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.FAILED), "NACKed");
        assertTrue(dispatcher.isAllowedVault(address(vault)), "rolled back: still allowlisted");
        assertTrue(dispatcher.isTrackedVault(address(vault)), "rolled back: still tracked");
    }

    /// @dev The same delivery at the ACK edge ACKs.
    function testShouldAckABurnedRemovalDeliveredAtTheAckEdge() public {
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 50e6, 5, bytes4(0), true);
        (bytes32 id, bool delivered) = _attempt(EMPTIES, MIN_LANE, EDGE_GAS_31_KEPT);
        assertTrue(delivered, "delivered");
        _assertBurnedRemovalAcked(id, epochBefore);
    }

    /// @dev 31 kept vaults need the measured lane `LANE_FOR_31_KEPT`.
    function testShouldAckABurnedRemovalWithThirtyOneKeptVaultsAtTheMeasuredLane() public {
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vault), 50e6, 5, bytes4(0), true);
        (bytes32 id, bool delivered) = _attempt(EMPTIES, LANE_FOR_31_KEPT, LANE_FOR_31_KEPT);
        assertTrue(delivered, "delivered");
        _assertBurnedRemovalAcked(id, epochBefore);
        assertEq(dispatcher.getTrackedVaults().length, 0, "tracked set empty");
    }
}
