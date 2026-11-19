// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

contract ApproverBlockToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipApproverBlockBoundTest
/// @notice IL-9616 (Olympix M26): pins the intended asymmetry of the CCIP attestation roles. Writing a value
///         needs two keys (proposer + approver); closing the NAV needs one (`rejectBalanceAndBlock`, approver
///         only, no expiry check). The block is lifted only by the timelocked `FORCE_SET_SETTLED`; a later
///         propose/approve round never lifts it, and the proposer alone can never block.
///         Pinning test: it passes on the base commit 8692fbe5; no behaviour changed.
contract CcipApproverBlockBoundTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    ApproverBlockToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new ApproverBlockToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _safety()
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
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _safety() internal view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
                anchorBandBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    function _propose(uint256 balance_) internal returns (uint256 proposalId) {
        proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    function _attest(uint256 balance_) internal {
        uint256 proposalId = _propose(balance_);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    /// @dev Bridge and settle `amount_`, which credits `settledRemoteBalance` through an AUTHENTICATED
    ///      TRANSFER_SETTLED — the legitimate way off a zero baseline.
    function _bridge(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    function _forceSetSettled(uint256 newSettledLD_) internal {
        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        uint256 arg = _fssArg(newSettledLD_);
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }

    /// @dev `FORCE_SET_SETTLED` argument observed at the executor's current frontier (IL-8294).
    function _fssArg(uint256 newSettledLD_) internal view returns (uint256) {
        return
            (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) | (block.timestamp << 128) | newSettledLD_;
    }

    function _anchored() internal {
        _bridge(100e18);
        vm.warp(block.timestamp + 2 hours);
        _attest(100e18);
    }

    function testApproverBlockFreezesNavWithoutMovingSettled() public {
        _anchored();
        vm.warp(block.timestamp + 2 hours);
        uint256 pid = _propose(1e18);

        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(pid);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "one approver key closed the NAV");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "settled untouched by the block");
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice Reject does not require a live proposal window: an already-expired pending proposal is enough.
    function testApproverBlockWorksOnExpiredProposal() public {
        _anchored();
        vm.warp(block.timestamp + 2 hours);
        uint256 pid = _propose(100e18);

        vm.warp(block.timestamp + 2 days); // past the proposal expiry (1 day)
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(pid);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "expired proposal still blocks");
    }

    /// @notice Writing a value needs both roles; the proposer alone can neither approve nor block.
    function testProposerAloneCannotBlockOrApprove() public {
        _anchored();
        vm.warp(block.timestamp + 2 hours);
        uint256 pid = _propose(100e18);

        vm.expectRevert(CcipCrosschainExecutor.OnlyBalanceApprover.selector);
        executor.rejectBalanceAndBlock(pid);
        vm.expectRevert(CcipCrosschainExecutor.OnlyBalanceApprover.selector);
        executor.approveBalance(pid);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "no block without the approver key");
    }

    /// @notice The block survives a fresh propose/approve round; only the timelocked rescue lifts it, and the
    ///         approver can block again afterwards (the exposure is availability, repeatable).
    function testOnlyTimelockedForceSetLiftsBlockAndApproverCanBlockAgain() public {
        _anchored();
        vm.warp(block.timestamp + 2 hours);
        uint256 pid = _propose(100e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(pid);

        vm.warp(block.timestamp + 2 hours);
        _attest(100e18);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "approve does not lift the block");

        // Schedule the rescue: still blocked for the whole timelock.
        vm.warp(block.timestamp + 1);
        uint256 arg = _fssArg(100e18);
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY - 1);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "blocked until the timelock elapses");

        vm.warp(block.timestamp + 1);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "timelocked rescue lifted the block");
        assertEq(executor.getBalance(), 100e18, "NAV readable again");

        // Repeatable: the same single key closes the NAV again.
        vm.warp(block.timestamp + 2 hours);
        uint256 again = _propose(100e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(again);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "blocked again by the same key");
    }
}
