// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {MockTtlExecutor} from "./mocks/MockTtlExecutor.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {ICrosschainFactory, ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title FactoryDeploymentTtlFloorTest
/// @notice Drives the REAL `StargateCrosschainFactory` with a test-only executor creation code
///         (`MockTtlExecutor`) whose `DEPLOYMENT_TTL()` is caller-chosen and unbounded, so the factory's own
///         floor at `requestDispatcher` can be exercised without weakening the canonical
///         `StargateCrosschainExecutor` constructor bound (IL-8049). The factory deploys under the default
///         settings; a failed deploy reverts `setUp` and turns the suite red, it never skips.
/// @dev Deliberately does NOT call `FactoryTestBase._factorySetUp`: that helper latches the canonical
///      executor creation code, which cannot construct with a TTL below `MIN_DEPLOYMENT_TTL`. `setUp` below
///      replicates the same scaffolding with `MockTtlExecutor` as the latched executor code instead.
contract FactoryDeploymentTtlFloorTest is FactoryTestBase {
    address internal manager = address(0x2222);

    function setUp() public {
        vm.chainId(LOCAL_CHAIN);
        vm.warp(365 days);
        endpoint = new MockLzEndpoint();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);

        factory = ICrosschainFactory(this.deployFactoryExt(CrosschainConstants.MIN_CONFIG_DELAY));
        factory.configureCreationCodes(
            type(MockTtlExecutor).creationCode,
            type(StargateCrosschainDispatcher).creationCode
        );
        factoryReady = true;

        _enableUsdc();
        factory.schedulePathConfig(REMOTE_CHAIN, REMOTE_EID, _factoryPathOptions(REMOTE_EID));
        _warpConfigDelay();
        factory.executePathConfig(REMOTE_CHAIN);
        vm.deal(address(factory), 100 ether);
        // IL-8565: the factory's own sends are capped by `maxNativeFee`; admit the mock's fee.
        StargateCrosschainFactory(payable(address(factory))).setMaxNativeFee(REMOTE_CHAIN, type(uint256).max);
    }

    function _paramsWithTtl(uint256 deploymentTtl_) internal view returns (ExecutorInitParams memory) {
        return
            ExecutorInitParams({
                assetId: ASSET_ID,
                manager: manager,
                admin: admin,
                rescueGuardian: guardian,
                rescueDelay: 3 days,
                balanceProposer: proposer,
                balanceApprover: approver,
                stalenessMax: 1 hours,
                bigChangeBps: 1000,
                minUpdateInterval: 10 minutes,
                deploymentTtl: deploymentTtl_,
                transferStalenessMax: 2 hours
            });
    }

    function _deployMock(bytes32 salt_, uint256 deploymentTtl_) internal returns (MockTtlExecutor mock) {
        mock = MockTtlExecutor(factory.createExecutor(salt_, _paramsWithTtl(deploymentTtl_)));
    }

    function _factory() internal view returns (StargateCrosschainFactory) {
        return StargateCrosschainFactory(payable(address(factory)));
    }

    // ---------------------------------------------------------------------
    // T1 — TTL 0 is rejected before any state changes or fee is paid
    // ---------------------------------------------------------------------

    function testShouldRejectDispatcherRequestBelowMinDeploymentTtl() public requiresFactory {
        MockTtlExecutor mock = _deployMock(keccak256("t1"), 0);

        uint256 sentBefore = endpoint.sentCount();
        uint256 balanceBefore = address(factory).balance;
        uint256 requestCountBefore = _factory().requestCount();
        uint256 pendingBefore = _factory().pendingCountByChain(REMOTE_CHAIN);

        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidDeploymentTtl.selector,
                uint256(0),
                CrosschainConstants.MIN_DEPLOYMENT_TTL,
                CrosschainConstants.MAX_DEPLOYMENT_TTL
            )
        );
        mock.request(REMOTE_CHAIN, admin, guardian, 3 days);

        assertEq(endpoint.sentCount(), sentBefore, "no message sent for a rejected request");
        assertEq(address(factory).balance, balanceBefore, "no fee paid for a rejected request");
        assertEq(_factory().requestCount(), requestCountBefore, "no request id allocated for a rejected request");
        assertEq(_factory().pendingCountByChain(REMOTE_CHAIN), pendingBefore, "no pending ticket recorded");
    }

    // ---------------------------------------------------------------------
    // T2 — one second below the floor is rejected too (pins the `<` direction)
    // ---------------------------------------------------------------------

    function testShouldRejectDispatcherRequestOneSecondBelowFloor() public requiresFactory {
        uint256 ttl = CrosschainConstants.MIN_DEPLOYMENT_TTL - 1;
        MockTtlExecutor mock = _deployMock(keccak256("t2"), ttl);

        uint256 sentBefore = endpoint.sentCount();
        uint256 balanceBefore = address(factory).balance;

        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidDeploymentTtl.selector,
                ttl,
                CrosschainConstants.MIN_DEPLOYMENT_TTL,
                CrosschainConstants.MAX_DEPLOYMENT_TTL
            )
        );
        mock.request(REMOTE_CHAIN, admin, guardian, 3 days);

        assertEq(endpoint.sentCount(), sentBefore, "no message sent one second below the floor");
        assertEq(address(factory).balance, balanceBefore, "no fee paid one second below the floor");
    }

    // ---------------------------------------------------------------------
    // T3 — exactly at the floor is admitted; the cancel gate still holds until the TTL elapses. Passes
    // both before and after the fix: it pins the boundary that must stay functional.
    // ---------------------------------------------------------------------

    function testShouldAdmitDispatcherRequestAtExactMinDeploymentTtl() public requiresFactory {
        uint256 ttl = CrosschainConstants.MIN_DEPLOYMENT_TTL;
        MockTtlExecutor mock = _deployMock(keccak256("t3"), ttl);

        uint256 sentBefore = endpoint.sentCount();
        uint256 balanceBefore = address(factory).balance;
        uint256 fee = endpoint.messagingFee();
        uint256 createdAt = block.timestamp;

        uint256 requestId = mock.request(REMOTE_CHAIN, admin, guardian, 3 days);

        assertEq(endpoint.sentCount(), sentBefore + 1, "ticket sent for a TTL at the floor");
        assertEq(address(factory).balance, balanceBefore - fee, "exactly one fee debited");
        assertEq(_factory().pendingCountByChain(REMOTE_CHAIN), 1, "one pending ticket recorded");

        uint256 executableAt = createdAt + ttl + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.DeploymentTtlNotElapsed.selector,
                requestId,
                block.timestamp,
                executableAt
            )
        );
        mock.cancel(requestId);

        vm.warp(executableAt);
        mock.cancel(requestId);
        assertEq(_factory().pendingCountByChain(REMOTE_CHAIN), 0, "pending ticket released once the TTL elapses");
    }

    // ---------------------------------------------------------------------
    // T4 — a same-block request/cancel loop with TTL 0 must not drain the factory's native budget
    // ---------------------------------------------------------------------

    function testShouldNotDrainFactoryBudgetThroughSameBlockRequestCancelLoop() public requiresFactory {
        MockTtlExecutor mock = _deployMock(keccak256("t4"), 0);

        uint256 sentBefore = endpoint.sentCount();
        uint256 balanceBefore = address(factory).balance;

        try mock.loop(REMOTE_CHAIN, admin, guardian, 3 days, 5) {
            // Pre-fix, all 5 iterations succeed; the assertions below then fail, which is the point.
        } catch {
            // Post-fix, iteration 1's `request` reverts `InvalidDeploymentTtl` before `++requestCount` and
            // before the send, so no ticket is created and no fee leaves. `mock.loop(...)` is one external
            // call, so a revert in any iteration also unwinds every earlier one.
        }

        assertEq(address(factory).balance, balanceBefore, "factory native budget must not move");
        assertEq(endpoint.sentCount(), sentBefore, "no ticket may be sent through the loop");
    }
}
