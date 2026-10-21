// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipChainRescue, ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title RescueUnregisteredChainTest
/// @notice Regression cover for `rescue_paths_accept_unregistered_chain_ids` (IL-8113): the rescue writers
///         on both transports wrote per-chain accounting state keyed by a caller-supplied chain id with no
///         `hasDispatcher` check. A mis-typed / mis-packed chain id could pre-seed `settledRemoteBalance` +
///         freshness stamp + anchor, or an irreversible frontier advance + `chainBlocked`, on a chain whose
///         dispatcher is not live yet — surfacing as phantom NAV or a whole-vault freeze the moment that
///         chain is registered. Fixed by gating the rescue writers whose chain id comes from the CALLER on
///         `hasDispatcher[chainId]`, at both schedule and execute time, on both transports. The record-keyed
///         rescue writers are deliberately left ungated — Stargate's `DROP_FROM_NAV`,
///         `DELIVERED_TO_SETTLED`, `DROP_RETURN_METADATA_INCLUDED` and `ABANDON_COMMAND_*`, and CCIP's
///         `executeForceResolveOutbound` — because their chain comes from a record or command slot that only
///         a registered chain can have; `testForceResolveOutboundOnRegisteredChainNeedsNoFlag` pins that.
contract StargateRescueUnregisteredChainTest is CrosschainTestBase {
    using stdStorage for StdStorage;

    /// @dev Mis-pack target: `REMOTE_CHAIN << 1` — one bit too far when packing `(chainId << 64) |
    ///      version`, decodes to an unrelated chain id (84322 for `REMOTE_CHAIN` = 42161).
    uint256 internal constant PHANTOM_CHAIN = uint256(REMOTE_CHAIN) << 1;

    function setUp() public {
        _baseSetUp();
    }

    function testScheduleForceSetSettledOnChainWithoutDispatcherReverts() public {
        _registerRemote();
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, REMOTE_CHAIN));
        executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, 100e6, observedVersion, _markFsObs(), false);
        assertEq(executor.pendingRescueCount(), 0, "no rescue should have been queued");
    }

    function testScheduleFrontierRepairOnChainWithoutDispatcherReverts() public {
        _registerRemote();
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(1));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, REMOTE_CHAIN));
        executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "frontier must not move");
    }

    /// @notice The finding's headline: a mis-packed id decodes to an unrelated, unregistered chain and
    ///         must be rejected before the 6 h frontier-repair timelock is even spent.
    function testMisPackedFrontierRepairIdIsRejectedBeforeTheTimelock() public {
        _readyDispatcher(); // REMOTE_CHAIN frontier == 0
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 65) | uint256(2));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, PHANTOM_CHAIN));
        executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "registered chain frontier untouched");
        assertEq(executor.acknowledgedRemoteStateVersion(PHANTOM_CHAIN), 0, "phantom chain must not advance");
        assertFalse(executor.chainBlocked(PHANTOM_CHAIN), "phantom chain must not be blocked");
    }

    /// @notice Exercises the LIBRARY-side guard in `forceSetSettled`: simulates a future deregistration
    ///         between schedule and execute. No writer on `HEAD` ever clears `hasDispatcher` back to
    ///         `false` (registration is irreversible today — the fix has no other way to reach this
    ///         library guard through the public API), so this scenario cannot occur through any code path
    ///         that exists today. The guard is still worth its bytes as the writer's own precondition: it
    ///         is what survives a future second caller of the library or a future deregistration path,
    ///         either of which would otherwise silently defeat the schedule-time guard alone.
    function testExecuteForceSetSettledRevertsWhenDispatcherFlagIsClearedAfterSchedule() public {
        _readyDispatcher();
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 100e6, observedVersion, _markFsObs(), false
        );
        uint64 observedAtBefore = executor.lastApprovedObservedAt(REMOTE_CHAIN);

        stdstore.target(address(executor)).sig("hasDispatcher(uint256)").with_key(REMOTE_CHAIN).checked_write(false);
        assertFalse(executor.isDispatcherReady(REMOTE_CHAIN), "stdstore write must have landed");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, REMOTE_CHAIN));
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 100e6, observedVersion, fsObs, false);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled bucket must stay untouched");
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), observedAtBefore, "freshness stamp must not move");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "chain must not be (un)blocked by the failed write");
    }

    /// @notice Exercises the LIBRARY-side guard in `applyForceResolve`'s ADVANCE branch, the same
    ///         simulated-deregistration scenario as above — see that test's NatSpec for why this state is
    ///         unreachable through the public API today and why the guard is kept regardless.
    function testExecuteFrontierRepairRevertsWhenDispatcherFlagIsClearedAfterSchedule() public {
        _readyDispatcher(); // frontier == 0
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(1));
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);

        stdstore.target(address(executor)).sig("hasDispatcher(uint256)").with_key(REMOTE_CHAIN).checked_write(false);
        assertFalse(executor.isDispatcherReady(REMOTE_CHAIN), "stdstore write must have landed");

        vm.warp(block.timestamp + 6 hours);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, REMOTE_CHAIN));
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ADVANCE_STATE_FRONTIER);

        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "frontier must not advance");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "chain must not be blocked by the failed write");
    }

    /// @notice Control: the guard must not bite a registered chain. Passes with and without the fix.
    function testRegisteredChainRescuesStillWork() public {
        _readyDispatcher();

        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 settledId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 100e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(settledId, REMOTE_CHAIN, 100e6, observedVersion, fsObs, false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), _toSDForAssertion(100e6), "settled must be set");

        uint64 newVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN) + 1;
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(newVersion));
        vm.prank(admin);
        uint256 frontierId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(admin);
        executor.executeForceResolveTransfer(frontierId, id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), newVersion, "frontier must advance");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "frontier repair blocks the chain");
    }

    /// @notice Control for the un-guarded, record-keyed branches: documents that `DROP_FROM_NAV` on a
    ///         registered chain's real outbound record is unchanged by this fix.
    function testForceResolveOutboundOnRegisteredChainNeedsNoFlag() public {
        _readyAndFundIdle40();
        (bytes32 transferId,,) = _sendAsset(10e6, 1);

        vm.prank(admin);
        uint256 rescueId =
            executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, transferId, ResolveOutcome.DROP_FROM_NAV);

        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "in-flight bucket must be dropped");
    }

    /// @dev USDC is 6 decimals local == 6 decimals shared in this fixture (ASSET_ID pool decimals == 6),
    ///      so shared-decimals equals local-decimals here; kept as a named helper rather than a bare
    ///      literal so a future decimals change to the fixture is not silently wrong here too.
    function _toSDForAssertion(uint256 amountLD_) private pure returns (uint256) {
        return amountLD_;
    }
}

contract CcipRescueUnregisteredChainTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    RescueTestToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new RescueTestToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router), factory, address(this), address(token), keccak256("USDC"), 18, _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
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
            address(0xB22),
            RESCUE_DELAY
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        // Route is configured (`routeValidator.setRoute` / `registerExecutorRoute` above), but the
        // dispatcher is deliberately NOT marked ready here — "route known, dispatcher not ready" is the
        // true shape of the finding (assessment §1.4). `_markReady()` opts a test into the registered
        // fixture instead.
    }

    function _markReady() private {
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: RESCUE_ADMIN,
            rescueGuardian: address(0xB22),
            balanceProposer: address(this),
            balanceApprover: APPROVER,
            rescueDelay: RESCUE_DELAY,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }

    function testScheduleForceSetSettledOnChainWithoutDispatcherReverts() public {
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.DispatcherNotReady.selector, REMOTE_CHAIN));
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, 100e18);
    }

    function testScheduleAdvanceFrontierOnChainWithoutDispatcherReverts() public {
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.DispatcherNotReady.selector, REMOTE_CHAIN));
        executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, 1);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 0, "frontier must not move");
    }

    function testScheduleAbandonCommandOnChainWithoutDispatcherReverts() public {
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.DispatcherNotReady.selector, REMOTE_CHAIN));
        executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, 1);
    }

    /// @notice Exercises the resident execute-time guard: simulates a future deregistration between
    ///         schedule and execute. See the Stargate contract's matching test NatSpec for why this state
    ///         is unreachable through the public API today (registration is irreversible: `markDispatcherReady`
    ///         is the only writer of `hasDispatcher` and it only ever sets `true`) and why the guard is kept
    ///         regardless — it is the writer's own precondition, and covers a future second caller or a
    ///         future deregistration path.
    function testExecuteChainRescueRevertsWhenDispatcherFlagIsClearedAfterSchedule() public {
        _markReady();
        uint256 arg = (block.timestamp << 128) | 100e18;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        stdstore.target(address(executor)).sig("hasDispatcher(uint256)").with_key(REMOTE_CHAIN).checked_write(false);
        assertFalse(executor.hasDispatcher(REMOTE_CHAIN), "stdstore write must have landed");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.DispatcherNotReady.selector, REMOTE_CHAIN));
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled bucket must stay untouched");
    }

    /// @notice Control: the guard must not bite a registered chain. Passes with and without the fix.
    function testRegisteredChainRescuesStillWork() public {
        _markReady();

        uint256 arg = (block.timestamp << 128) | 100e18;
        vm.prank(RESCUE_ADMIN);
        uint256 settledId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(settledId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "settled must be set");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "settled overwrite must unblock");

        uint64 newVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN) + 1;
        vm.prank(RESCUE_ADMIN);
        uint256 frontierId =
            executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(frontierId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), newVersion, "frontier must advance");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "frontier repair blocks the chain");
    }
}

contract RescueTestToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}
