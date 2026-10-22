// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title CcipProposalInvalidationTest
/// @notice IL-8472 (B-12), CCIP half. An accounting-epoch bump (or a newer proposal) voids the active balance
///         proposal; the void is announced with `ProposalInvalidated` and the stored status becomes
///         SUPERSEDED (4). The executor exposes `accountingEpoch` and `activeProposalId`; it has no
///         `proposals(id)` getter (EIP-170 headroom), so the status is read from storage:
///         `_attestationState` is slot 31, its `proposals` mapping is member 4 and `status` is word 5 of
///         `CcipBalanceProposal`.
contract CcipProposalInvalidationTest is Test {
    event ProposalInvalidated(uint256 chainId, uint256 proposalId, uint64 newEpoch);

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant RESCUE_GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant ATTESTATION_SLOT = 32;
    bytes32 internal constant PROPOSAL_INVALIDATED_TOPIC = keccak256("ProposalInvalidated(uint256,uint256,uint64)");
    bytes32 internal constant ASSET_SENT_TOPIC = keccak256("AssetSent(uint256,bytes32,bytes32,uint256)");

    MockCcipRouter internal router;
    MockERC20 internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.warp(365 days);
        router = new MockCcipRouter();
        token = new MockERC20("USD Coin", "USDC", 6);
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: RESCUE_GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: 3 days,
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
            6,
            block.chainid,
            back,
            RESCUE_ADMIN,
            RESCUE_GUARDIAN,
            3 days
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
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _propose() internal returns (uint256) {
        return executor.proposeBalance(
            REMOTE_CHAIN,
            0,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    /// @dev `status` of `CcipBalanceProposal` (word 5 of the struct), read from storage.
    function _status(uint256 pid_) internal view returns (uint8) {
        bytes32 base = keccak256(abi.encode(pid_, ATTESTATION_SLOT + 4));
        return uint8(uint256(vm.load(address(executor), bytes32(uint256(base) + 5))));
    }

    function _countInvalidated(Vm.Log[] memory logs_) internal view returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == PROPOSAL_INVALIDATED_TOPIC) ++count;
        }
    }

    /// @dev Sends 100e6 out with the router paused, so the outbound stays unresolved; returns its operation id.
    function _sendOutboundUnresolved() internal returns (bytes32 operationId) {
        router.setAutoDeliver(false);
        token.mint(address(executor), 100e6);
        vm.recordLogs();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e6, 0, address(0), 500_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == ASSET_SENT_TOPIC) {
                (, operationId,,) = abi.decode(logs[i].data, (uint256, bytes32, bytes32, uint256));
            }
        }
        assertTrue(operationId != bytes32(0), "operation id captured");
    }

    function testShouldExposeAccountingEpochAndActiveProposalId() public {
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), 0, "epoch starts at 0");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "no active proposal");
        uint256 pid = _propose();
        assertEq(pid, 1, "first id");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), pid, "active proposal id");
        assertEq(_status(pid), 1, "PENDING");
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), 0, "propose does not bump the epoch");
    }

    function testShouldEmitProposalInvalidatedAndMarkSupersededOnForceResolveOutbound() public {
        bytes32 operationId = _sendOutboundUnresolved();
        uint256 pid = _propose();
        uint64 newEpoch = executor.accountingEpoch(REMOTE_CHAIN) + 1;

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + 3 days);
        // The schedule/timelock does not touch the proposal (it is still in its approval window's shadow).
        vm.expectEmit(false, false, false, true, address(executor));
        emit ProposalInvalidated(REMOTE_CHAIN, pid, newEpoch);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, false);

        assertEq(_status(pid), 4, "status SUPERSEDED");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "no active proposal");
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), newEpoch, "epoch bumped");
        vm.prank(APPROVER);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalNotActive.selector, pid));
        executor.approveBalance(pid);
        vm.prank(APPROVER);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalNotActive.selector, pid));
        executor.rejectBalanceAndBlock(pid);
    }

    function testShouldNotEmitProposalInvalidatedOnEpochBumpWithoutActiveProposal() public {
        bytes32 operationId = _sendOutboundUnresolved();
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + 3 days);
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "no active proposal");

        vm.recordLogs();
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(executor.accountingEpoch(REMOTE_CHAIN), 1, "epoch bumped");
        assertEq(_countInvalidated(logs), 0, "nothing to invalidate, nothing emitted");
    }

    function testShouldSupersedeThePreviousActiveProposalOnNewPropose() public {
        uint256 first = _propose();

        vm.expectEmit(false, false, false, true, address(executor));
        emit ProposalInvalidated(REMOTE_CHAIN, first, 0);
        uint256 second = _propose();

        assertEq(second, first + 1, "new id");
        assertEq(_status(first), 4, "old proposal SUPERSEDED");
        assertEq(_status(second), 1, "new proposal PENDING");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), second, "new proposal active");
        vm.prank(APPROVER);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalNotActive.selector, first));
        executor.approveBalance(first);
    }

    function testShouldNotEmitProposalInvalidatedOnFirstPropose() public {
        vm.recordLogs();
        _propose();
        assertEq(_countInvalidated(vm.getRecordedLogs()), 0, "no previous proposal, nothing emitted");
    }
}
