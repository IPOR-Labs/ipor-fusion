// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {DiagnosticCommandVaultHarness} from "./DiagnosticCommandRecoveryMarkTest.t.sol";
import {CrosschainRecoveryContextTestLib} from "./mocks/CrosschainRecoveryContextTestLib.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockPausableRemoteVault, MockAssetSwitchRemoteVault} from "./mocks/MockRetryFollowUpVaults.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandFuseEnterData,
    StargateCrosschainCommandType
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainRecoveryLib} from "../../contracts/fuses/crosschain/lib/CrosschainRecoveryLib.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @notice Two command-fuse calls in ONE transaction with the transient markers kept between them (the shape of one
///         `PlasmaVault.execute` batch); `DiagnosticCommandVaultHarness` adds the command + NAV refresh shape.
contract RetryBatchVaultHarness is DiagnosticCommandVaultHarness {
    using Address for address;

    constructor(address underlying_) DiagnosticCommandVaultHarness(underlying_) {}

    function ccipTwo(CcipCommandFuseEnterData memory first_, CcipCommandFuseEnterData memory second_) external {
        ccipCommandFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainCommandFuse.enter, (first_)));
        ccipCommandFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainCommandFuse.enter, (second_)));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }

    function stargateTwo(
        StargateCrosschainCommandFuseEnterData memory first_,
        StargateCrosschainCommandFuseEnterData memory second_
    ) external {
        commandFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainCommandFuse.enter, (first_)));
        commandFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainCommandFuse.enter, (second_)));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }
}

/// @title StargateRetryCommandFollowUpTest
/// @notice IL-8600 follow-up on a REAL Stargate executor + dispatcher driven through the REAL command fuse (the
///         executor's MANAGER is the vault harness):
///         - a retried DEPOSIT re-checks its target vault against the REMOTE_VAULT substrates (it was checked only at
///           the first send, so a substrate revoked in between did not stop the retry);
///         - a retried config update is gated like a fresh one (refused on a blocked chain, no recovery marker);
///         - a retried DEPOSIT cannot share a batch with a recovery action (IL-8600 property no other test pins).
contract StargateRetryCommandFollowUpTest is StargateTwoSidedBase {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;

    RetryBatchVaultHarness internal vault;
    MockERC20 internal underlying;

    function setUp() public {
        // The executor's MANAGER is immutable: make it the vault harness before the base deploys the executor.
        underlying = new MockERC20("Underlying", "UND", 6);
        vault = new RetryBatchVaultHarness(address(underlying));
        manager = address(vault);
        _twoSidedSetUp();
        _bringUpBothSides();

        StargateCrosschainCommandFuse fuse = new StargateCrosschainCommandFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(0), address(0), address(fuse), address(balanceFuse));
        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8);
        oracle.setPrice(address(underlying), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));
    }

    /// @dev Replaces the market substrates (`grantMarketSubstrates` revokes everything not in the new list).
    function _grant(address remoteVault_, bool withVault_) internal {
        bytes32[] memory substrates = new bytes32[](withVault_ ? 2 : 1);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        if (withVault_) substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, remoteVault_);
        vault.grantSubstrates(MARKET, substrates);
    }

    function _data(StargateCrosschainCommandType type_)
        internal
        view
        returns (StargateCrosschainCommandFuseEnterData memory data)
    {
        data.commandType = type_;
        data.executor = address(executor);
        data.chainId = REMOTE_CHAIN;
    }

    function _updateVaults(address remoteVault_)
        internal
        view
        returns (StargateCrosschainCommandFuseEnterData memory data)
    {
        data = _data(StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS);
        data.plasmaVaults = new address[](1);
        data.plasmaVaults[0] = remoteVault_;
    }

    function _deposit(address remoteVault_, uint256 amountSD_)
        internal
        view
        returns (StargateCrosschainCommandFuseEnterData memory data)
    {
        data = _data(StargateCrosschainCommandType.SEND_COMMAND);
        data.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.DEPOSIT),
            minExecutionGas: 0,
            actionData: CrosschainMessages.encodeDepositAction(remoteVault_, amountSD_, 0)
        });
    }

    function _status() internal view returns (bool active, CommandStatus status) {
        (active,,, status,,,) = executor.activeCommand(REMOTE_CHAIN);
    }

    function _propose(uint256 settledLD_) internal returns (uint256 proposalId) {
        BalanceObservation memory observation = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(observation);
        proposalId = executor.proposalCount();
    }

    function _attest(uint256 settledLD_) internal {
        uint256 proposalId = _propose(settledLD_);
        vm.prank(approver);
        executor.approveBalance(proposalId);
    }

    /// @dev Allowlisted, granted vault; 1e6 idle on the dispatcher, attested; the vault refuses deposits, so the
    ///      DEPOSIT is NACKed and stays FAILED in the command slot.
    function _failedDepositInto(MockPausableRemoteVault remoteVault_) internal {
        _grant(address(remoteVault_), true);
        vault.enterCommand(_updateVaults(address(remoteVault_)));
        _relayAll();
        _bridgeToDispatcher(1e6);
        _attest(1e6);
        remoteVault_.setPaused(true);
        vault.enterCommand(_deposit(address(remoteVault_), 1e6));
        _relayAll();
        (bool active, CommandStatus status) = _status();
        assertTrue(active, "lane held");
        assertEq(uint8(status), uint8(CommandStatus.FAILED), "precondition: FAILED DEPOSIT");
    }

    /// @dev A granted vault that reports a foreign asset: the allowlist add is NACKed and stays FAILED.
    function _failedAllowlistAdd() internal returns (MockAssetSwitchRemoteVault remoteVault) {
        remoteVault = new MockAssetSwitchRemoteVault(IERC20(address(usdc)));
        remoteVault.setReportedAsset(address(0xDEAD));
        _grant(address(remoteVault), true);
        vault.stargateCommandThenNav(_updateVaults(address(remoteVault)));
        _relayAll();
        (, CommandStatus status) = _status();
        assertEq(uint8(status), uint8(CommandStatus.FAILED), "precondition: FAILED allowlist add");
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), 0, "a config update has no business action");
    }

    function testShouldRecordTheTargetOfAStoredDepositOnly() public {
        MockPausableRemoteVault remoteVault = new MockPausableRemoteVault(IERC20(address(usdc)));
        _grant(address(remoteVault), true);
        vault.enterCommand(_updateVaults(address(remoteVault)));
        assertEq(executor.activeCommandTarget(REMOTE_CHAIN), address(0), "config update: no target");
        _relayAll();

        vault.enterCommand(_deposit(address(remoteVault), 1e6));
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), uint8(BusinessAction.DEPOSIT));
        assertEq(executor.activeCommandTarget(REMOTE_CHAIN), address(remoteVault), "DEPOSIT target recorded");
    }

    function testShouldRefuseRetryOfDepositIntoVaultRevokedAfterTheFailure() public {
        MockPausableRemoteVault remoteVault = new MockPausableRemoteVault(IERC20(address(usdc)));
        _failedDepositInto(remoteVault);
        _grant(address(remoteVault), false); // FUSE_MANAGER revokes the REMOTE_VAULT substrate
        remoteVault.setPaused(false); // the vault takes deposits again

        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, REMOTE_CHAIN, address(remoteVault)
            )
        );
        vault.enterCommand(_data(StargateCrosschainCommandType.RETRY_COMMAND));

        // CANCEL_COMMAND frees the lane; nothing reaches the revoked vault.
        vault.enterCommand(_data(StargateCrosschainCommandType.CANCEL_COMMAND));
        _relayAll();
        (bool active,) = _status();
        assertFalse(active, "lane freed by CANCEL");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 0, "nothing invested into the revoked vault");
    }

    function testShouldRetryDepositWhileItsVaultIsStillGranted() public {
        MockPausableRemoteVault remoteVault = new MockPausableRemoteVault(IERC20(address(usdc)));
        _failedDepositInto(remoteVault);
        remoteVault.setPaused(false);

        vm.expectCall(address(executor), abi.encodeWithSelector(executor.getBalance.selector), 1);
        vault.enterCommand(_data(StargateCrosschainCommandType.RETRY_COMMAND));
        _relayAll();

        assertEq(remoteVault.balanceOf(address(dispatcher)), 1e6, "retried DEPOSIT landed");
        (bool active,) = _status();
        assertFalse(active, "ACK freed the lane");
    }

    function testShouldRefuseRetryOfConfigUpdateOnBlockedChain() public {
        _bridgeToDispatcher(1e6);
        _attest(1e6);
        MockAssetSwitchRemoteVault remoteVault = _failedAllowlistAdd();

        // The approver rejects a pending proposal: real circuit breaker, chain blocked.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint256 proposalId = _propose(1e6);
        vm.prank(approver);
        executor.rejectAndBlockProposal(proposalId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "chain blocked");

        remoteVault.setReportedAsset(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseChainBlocked.selector,
                address(executor),
                REMOTE_CHAIN
            )
        );
        vault.enterCommand(_data(StargateCrosschainCommandType.RETRY_COMMAND));

        // CANCEL_COMMAND still frees the lane on the blocked chain; the allowlist is untouched.
        vault.enterCommand(_data(StargateCrosschainCommandType.CANCEL_COMMAND));
        _relayAll();
        (bool active,) = _status();
        assertFalse(active, "lane freed by CANCEL");
        assertFalse(dispatcher.isAllowedVault(address(remoteVault)), "allowlist untouched");
    }

    function testShouldRevertRetriedConfigUpdateOnNavRefreshWhileFailClosed() public {
        MockAssetSwitchRemoteVault remoteVault = _failedAllowlistAdd(); // NAV healthy: nothing booked yet

        // Value lands remotely without an approved observation: live NAV is fail-closed.
        _bridgeToDispatcher(1e6);
        vault.setCachedMarketBalance(MARKET, 1e6);
        remoteVault.setReportedAsset(address(0));

        // Like a fresh config command, the retry is not recovery-marked: the batch reverts on the NAV refresh.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        vault.stargateCommandThenNav(_data(StargateCrosschainCommandType.RETRY_COMMAND));
    }

    function testShouldNotLetARetriedDepositShareABatchWithARecovery() public {
        MockPausableRemoteVault remoteVault = new MockPausableRemoteVault(IERC20(address(usdc)));
        _grant(address(remoteVault), true);
        vault.enterCommand(_updateVaults(address(remoteVault)));
        _relayAll();
        vault.enterCommand(_deposit(address(remoteVault), 1e6)); // nothing idle on the dispatcher: NACK (ZeroAmount)
        _relayAll();
        (, CommandStatus status) = _status();
        assertEq(uint8(status), uint8(CommandStatus.FAILED), "precondition: FAILED DEPOSIT");

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateTwo(
            _data(StargateCrosschainCommandType.RETRY_COMMAND), _data(StargateCrosschainCommandType.CANCEL_COMMAND)
        );
    }
}

/// @title CcipRetryCommandFollowUpTest
/// @notice The same IL-8600 follow-up on a REAL CCIP executor + dispatcher behind the mock router (synchronous
///         delivery), driven through the REAL command fuse. Freshness 1 h and cadence 1 min, as in the last
///         mainnet configuration, so a fail-closed NAV is a REAL stale observation, not a mocked revert.
contract CcipRetryCommandFollowUpTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;
    address internal constant PROPOSER = address(0xA33);
    address internal constant APPROVER = address(0xB44);

    MockERC20 internal token;
    MockCcipRouter internal router;
    RetryBatchVaultHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.warp(1_760_000_000);
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        vault = new RetryBatchVaultHarness(address(token));
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(vault),
            address(token),
            keccak256("USDC"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: PROPOSER,
                balanceApprover: APPROVER,
                rescueDelay: 3 days,
                balanceStalenessMax: 1 hours,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 minutes,
                transferStalenessMax: 1 days
            })
        );
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            CcipRouteConfig({
                chainSelector: EXECUTOR_SELECTOR,
                peer: address(executor),
                feeToken: address(0),
                messageGasLimit: 2_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 0,
                enabled: true
            }),
            address(0xA11),
            address(0xB22),
            3 days
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
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);

        CcipCrosschainCommandFuse commandFuse = new CcipCrosschainCommandFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(0), address(0), address(0), address(balanceFuse));
        vault.setCcipFuses(address(0), address(commandFuse));
        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(token), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));
        _grant(address(0), false);
    }

    /// @dev Replaces the market substrates (`grantMarketSubstrates` revokes everything not in the new list).
    function _grant(address remoteVault_, bool withVault_) internal {
        bytes32[] memory substrates = new bytes32[](withVault_ ? 2 : 1);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        if (withVault_) substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, remoteVault_);
        vault.grantSubstrates(MARKET, substrates);
    }

    function _data(CcipCommandType type_, bytes32 commandId_)
        internal
        view
        returns (CcipCommandFuseEnterData memory data)
    {
        data.commandType = type_;
        data.executor = address(executor);
        data.chainId = REMOTE_CHAIN;
        data.gasLimit = 2_000_000;
        data.command.commandId = commandId_;
    }

    function _updateVaults(address remoteVault_) internal view returns (CcipCommandFuseEnterData memory data) {
        data = _data(CcipCommandType.UPDATE_VAULTS, bytes32(0));
        data.plasmaVaults = new address[](1);
        data.plasmaVaults[0] = remoteVault_;
        data.vaultsAllowed = true;
    }

    function _deposit(address remoteVault_, uint256 amount_)
        internal
        view
        returns (CcipCommandFuseEnterData memory data)
    {
        data = _data(CcipCommandType.SEND_COMMAND, bytes32(0));
        data.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.DEPOSIT),
            minExecutionGas: 0,
            actionData: CrosschainMessages.encodeDepositAction(remoteVault_, amount_, 0)
        });
    }

    function _bridge(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        vm.prank(address(vault));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
    }

    function _propose(uint256 balance_) internal returns (uint256) {
        uint64 version = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        bytes32 positionSetHash = dispatcher.trackedPositionSetHash();
        vm.prank(PROPOSER);
        return executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            version,
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            positionSetHash
        );
    }

    function _attest(uint256 balance_) internal {
        uint256 proposalId = _propose(balance_);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    function _failedActive() internal view returns (bytes32 id) {
        id = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(id != bytes32(0), "lane held");
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "precondition: FAILED");
    }

    /// @dev Allowlisted, granted vault; 100e6 idle on the dispatcher, attested; the vault refuses deposits, so the
    ///      DEPOSIT is NACKed and stays FAILED in the command slot.
    function _failedDepositInto(MockPausableRemoteVault remoteVault_) internal returns (bytes32 id) {
        _grant(address(remoteVault_), true);
        vault.enterCcipCommand(_updateVaults(address(remoteVault_)));
        vm.warp(block.timestamp + 1);
        _bridge(100e6);
        vm.warp(block.timestamp + 1);
        _attest(100e6);
        remoteVault_.setPaused(true);
        vault.enterCcipCommand(_deposit(address(remoteVault_), 50e6));
        id = _failedActive();
    }

    function testShouldRefuseRetryOfDepositIntoVaultRevokedAfterTheFailure() public {
        MockPausableRemoteVault remoteVault = new MockPausableRemoteVault(IERC20(address(token)));
        bytes32 id = _failedDepositInto(remoteVault);
        _grant(address(remoteVault), false); // FUSE_MANAGER revokes the REMOTE_VAULT substrate
        remoteVault.setPaused(false); // the vault takes deposits again

        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, REMOTE_CHAIN, address(remoteVault)
            )
        );
        vault.enterCcipCommand(_data(CcipCommandType.RETRY_COMMAND, id));

        vault.enterCcipCommand(_data(CcipCommandType.CANCEL_COMMAND, id));
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.CANCELLED), "lane freed by CANCEL");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 0, "nothing invested into the revoked vault");
    }

    function testShouldRetryDepositWhileItsVaultIsStillGranted() public {
        MockPausableRemoteVault remoteVault = new MockPausableRemoteVault(IERC20(address(token)));
        bytes32 id = _failedDepositInto(remoteVault);
        assertEq(executor.commandDepositTarget(id), address(remoteVault), "stored DEPOSIT target");
        assertEq(executor.commandDepositTarget(bytes32(uint256(1))), address(0), "unknown id: no target");
        remoteVault.setPaused(false);

        vault.enterCcipCommand(_data(CcipCommandType.RETRY_COMMAND, id));

        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "retried DEPOSIT succeeded");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 50e6, "retried DEPOSIT landed");
    }

    function testShouldGateRetriedDepositOnARealStaleObservation() public {
        MockPausableRemoteVault remoteVault = new MockPausableRemoteVault(IERC20(address(token)));
        bytes32 id = _failedDepositInto(remoteVault);
        remoteVault.setPaused(false);

        // Two hours later the observation is older than the 1 h freshness window: NAV is fail-closed for real.
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        vault.enterCcipCommand(_data(CcipCommandType.RETRY_COMMAND, id));

        // A fresh attestation reopens NAV; the same retry passes inside the command's 24 h TTL.
        _attest(100e6);
        vault.enterCcipCommand(_data(CcipCommandType.RETRY_COMMAND, id));
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.SUCCEEDED));
        assertEq(remoteVault.balanceOf(address(dispatcher)), 50e6);
    }

    function testShouldRefuseRetryOfConfigUpdateOnBlockedChain() public {
        MockAssetSwitchRemoteVault remoteVault = new MockAssetSwitchRemoteVault(IERC20(address(token)));
        remoteVault.setReportedAsset(address(0xDEAD));
        _grant(address(remoteVault), true);
        vm.warp(block.timestamp + 1);
        _bridge(100e6);
        vm.warp(block.timestamp + 1);
        _attest(100e6);
        vault.enterCcipCommand(_updateVaults(address(remoteVault))); // NACK: InvalidVault
        bytes32 id = _failedActive();
        assertEq(executor.commandAction(id), 0, "a config update has no business action");

        vm.warp(block.timestamp + 2 minutes);
        uint256 proposalId = _propose(100e6);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(proposalId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "chain blocked");

        remoteVault.setReportedAsset(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainCommandFuse.CommandFuseChainBlocked.selector, address(executor), REMOTE_CHAIN
            )
        );
        vault.enterCcipCommand(_data(CcipCommandType.RETRY_COMMAND, id));

        vault.enterCcipCommand(_data(CcipCommandType.CANCEL_COMMAND, id));
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.CANCELLED), "lane freed by CANCEL");
        assertFalse(dispatcher.isAllowedVault(address(remoteVault)), "allowlist untouched");
    }

    function testShouldRevertRetriedConfigUpdateOnNavRefreshWhileFailClosed() public {
        MockAssetSwitchRemoteVault remoteVault = new MockAssetSwitchRemoteVault(IERC20(address(token)));
        remoteVault.setReportedAsset(address(0xDEAD));
        _grant(address(remoteVault), true);
        vault.ccipCommandThenNav(_updateVaults(address(remoteVault))); // NAV healthy (nothing booked): NACK
        bytes32 id = _failedActive();

        // Value lands remotely without an approved observation: live NAV is fail-closed.
        _bridge(100e6);
        vault.setCachedMarketBalance(MARKET, 100e6);
        remoteVault.setReportedAsset(address(0));

        // Like a fresh config command, the retry is not recovery-marked: the batch reverts on the NAV refresh.
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        vault.ccipCommandThenNav(_data(CcipCommandType.RETRY_COMMAND, id));
    }

    function testShouldNotLetARetriedDepositShareABatchWithARecovery() public {
        MockPausableRemoteVault remoteVault = new MockPausableRemoteVault(IERC20(address(token)));
        _grant(address(remoteVault), true);
        vault.enterCcipCommand(_updateVaults(address(remoteVault)));
        vault.enterCcipCommand(_deposit(address(remoteVault), 1e6)); // nothing idle: NACK (ZeroBusinessAmount)
        bytes32 id = _failedActive();

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipTwo(_data(CcipCommandType.RETRY_COMMAND, id), _data(CcipCommandType.CANCEL_COMMAND, id));
    }
}
