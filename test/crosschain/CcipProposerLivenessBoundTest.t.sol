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

contract ProposerLivenessToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipProposerLivenessBoundTest
/// @notice IL-9596 (Olympix M06): pins the intended fail-closed design for a compromised or unavailable
///         `BALANCE_PROPOSER`. The proposer key can supersede every pending proposal before the approver acts,
///         so no new attestation lands and the NAV ages out. It can never write `settled` (only the approver
///         approves) and it can never make the NAV serve a stale value: after `BALANCE_STALENESS_MAX`
///         `getBalance` reverts `ObservationStale`. The exit is the timelocked `FORCE_SET_SETTLED`.
///         Pinning test: it passes on the base commit 8692fbe5; no behaviour changed.
contract CcipProposerLivenessBoundTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    ProposerLivenessToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new ProposerLivenessToken();
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

    /// @dev Anchors the bucket (authenticated settlement) and refreshes the observation clock.
    function _anchoredAt100() internal {
        _bridge(100e18);
        vm.warp(block.timestamp + 2 hours);
        _attest(100e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "precondition: anchored bucket");
    }

    function testProposerAloneCannotApproveOrWriteSettled() public {
        _anchoredAt100();
        vm.warp(block.timestamp + 2 hours);
        uint256 pid = _propose(110e18);

        // address(this) is the BALANCE_PROPOSER; only the approver may approve.
        vm.expectRevert(CcipCrosschainExecutor.OnlyBalanceApprover.selector);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "settled unchanged");
    }

    /// @notice The finding: a proposer that supersedes every proposal before approval keeps the approver from
    ///         ever landing one. Settled and the readable NAV never move until the staleness bound, and the
    ///         NAV then fails closed - it is never a stale value.
    function testSupersedeLoopOnlyAgesNavOutAndNeverServesStaleValue() public {
        _anchoredAt100();
        uint64 approvedAt = executor.lastApprovedObservedAt(REMOTE_CHAIN);
        uint256 previous;

        for (uint256 i = 1; i <= 7; i++) {
            vm.warp(block.timestamp + 1 days);
            uint256 pid = _propose(100e18);
            if (previous != 0) {
                // SUPERSEDED: the approver can no longer act on the replaced proposal.
                vm.prank(APPROVER);
                vm.expectRevert(abi.encodeWithSignature("ProposalNotActive(uint256)", previous));
                executor.approveBalance(previous);
            }
            previous = pid;
            assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "settled never moves");
            assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), approvedAt, "no approval lands");
        }

        // The last day inside the bound still serves the (unchanged) attested value ...
        assertEq(block.timestamp, uint256(approvedAt) + 7 days, "at the staleness bound exactly");
        assertEq(executor.getBalance(), 100e18, "still the last approved value at the bound");

        // ... and one second later the NAV fails closed instead of serving a stale number.
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice The approver can still land the active proposal before it is superseded; the proposer cannot
    ///         stop an approval that is already in flight (it only wins the race for the next one).
    function testApproverStillLandsActiveProposalBeforeSupersede() public {
        _anchoredAt100();
        vm.warp(block.timestamp + 2 hours);
        uint256 pid = _propose(105e18);
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 105e18, "approval landed");
    }

    /// @notice Exit path: the timelocked FORCE_SET_SETTLED restores a readable NAV without the proposer key.
    function testForceSetSettledRestoresNavAfterStalenessCausedBySupersedeLoop() public {
        _anchoredAt100();
        for (uint256 i = 1; i <= 7; i++) {
            vm.warp(block.timestamp + 1 days);
            _propose(100e18);
        }
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();

        _forceSetSettled(100e18);

        assertEq(executor.getBalance(), 100e18, "NAV readable again after the timelocked rescue");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
    }
}
