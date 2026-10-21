// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipObservation} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";

contract RefreshRegressionToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipAttestationRefreshRegressionTest
/// @notice IL-8589 (Ackee TP-M-11), fixed by IL-8257: a `BALANCE_REPORT` or `COMMAND_ACK` landing between
///         `proposeBalance` and `approveBalance` must NOT void the proposal, because only the value-moving
///         `TRANSFER_SETTLED` / `RETURN_TRANSFER` responses bump the dispatcher `stateVersion`. A value-moving
///         response still voids it, which proves the fix is targeted and the version check is intact.
contract CcipAttestationRefreshRegressionTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    RefreshRegressionToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new RefreshRegressionToken();
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
            messageGasLimit: 2_000_000,
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
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
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

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
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
            });
    }

    // ------------------------------------------------------------------ helpers

    function _frontier() private view returns (uint64) {
        return executor.lastRemoteStateVersion(REMOTE_CHAIN);
    }

    function _propose(uint256 balance_, uint64 version_) private returns (uint256) {
        CcipObservation memory obs = dispatcher.observation();
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        return
            executor.proposeBalance(
                REMOTE_CHAIN,
                balance_,
                version_,
                uint64(block.number),
                uint64(block.timestamp),
                uint64(block.timestamp + 1 days),
                obs.trackedPositionSetHash
            );
    }

    /// @dev 100e18 bridged and settled (dispatcher version 1 == frontier 1), attested once, cadence elapsed.
    function _baseline() private {
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        assertEq(_frontier(), 1, "frontier after the settle");
        assertEq(dispatcher.stateVersion(), 1, "dispatcher version after the settle");
        uint256 id = _propose(100e18, 1);
        vm.prank(APPROVER);
        executor.approveBalance(id);
        assertEq(executor.getBalance(), 100e18, "NAV baseline");
        vm.warp(block.timestamp + 1 hours); // attestation cadence limiter
    }

    function _approveExpectingSuccess(uint256 id_) private {
        vm.prank(APPROVER);
        executor.approveBalance(id_);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "settled updated by the approval");
        assertEq(executor.getBalance(), 100e18, "NAV");
    }

    // ------------------------------------------------------------------ tests

    /// @notice A BALANCE_REPORT (requestRemoteBalance) between propose and approve leaves the proposal valid.
    function testShouldKeepProposalValidWhenBalanceReportLandsBetweenProposeAndApprove() public {
        _baseline();
        uint64 version = dispatcher.stateVersion();
        uint256 id = _propose(100e18, version);

        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000); // report delivered synchronously
        assertEq(dispatcher.stateVersion(), version, "BALANCE_REQUEST did not bump the dispatcher version");
        assertEq(_frontier(), version, "the report did not move lastRemoteStateVersion");

        _approveExpectingSuccess(id);
        assertEq(_frontier(), version, "frontier unchanged after approval");
    }

    /// @notice A value-neutral COMMAND_ACK (UPDATE_VAULTS) between propose and approve leaves it valid.
    function testShouldKeepProposalValidWhenCommandAckLandsBetweenProposeAndApprove() public {
        _baseline();
        uint64 version = dispatcher.stateVersion();
        uint256 id = _propose(100e18, version);

        MockRemoteVault vault = new MockRemoteVault(token, "Remote", "rUSDC");
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "the command was acknowledged");
        assertEq(dispatcher.stateVersion(), version, "a successful command did not bump the version");
        assertEq(_frontier(), version, "the ACK did not move lastRemoteStateVersion");

        _approveExpectingSuccess(id);
        assertEq(_frontier(), version, "frontier unchanged after approval");
    }

    /// @notice A TRANSFER_SETTLED between propose and approve DOES void the proposal: the fix is targeted.
    function testShouldVoidProposalWhenValueMovingResponseLandsBetweenProposeAndApprove() public {
        _baseline();
        uint64 version = dispatcher.stateVersion();
        uint256 id = _propose(100e18, version);

        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 2_000_000); // delivered + settled
        assertEq(dispatcher.stateVersion(), version + 1, "TRANSFER_SETTLED bumped the version");
        assertEq(_frontier(), version + 1, "the frontier followed");

        vm.prank(APPROVER);
        // The value-moving settle bumps the accounting epoch and voids the pending proposal (IL-8269), so it is
        // no longer active; the version check in `approve` is the second line of defence behind it.
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalNotActive.selector, id));
        executor.approveBalance(id);
    }
}
