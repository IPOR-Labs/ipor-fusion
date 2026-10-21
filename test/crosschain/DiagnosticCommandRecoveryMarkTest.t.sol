// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandType,
    StargateCrosschainCommandFuseEnterData
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {CrosschainRecoveryContextTestLib} from "./mocks/CrosschainRecoveryContextTestLib.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @notice Vault stand-in that runs ONE command-fuse call and then the NAV refresh in the same transaction, the
///         shape of `PlasmaVault.execute` (the recovery marker is still set when the balance fuse reads).
contract DiagnosticCommandVaultHarness is CrosschainVaultHarness {
    using Address for address;

    constructor(address underlying_) CrosschainVaultHarness(underlying_) {}

    function stargateCommandThenNav(StargateCrosschainCommandFuseEnterData memory data_)
        external
        returns (uint256 value)
    {
        commandFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainCommandFuse.enter, (data_)));
        value = _nav();
    }

    function ccipCommandThenNav(CcipCommandFuseEnterData memory data_) external returns (uint256 value) {
        ccipCommandFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainCommandFuse.enter, (data_)));
        value = _nav();
    }

    function _nav() private returns (uint256 value) {
        bytes memory ret = balanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf()"));
        value = abi.decode(ret, (uint256));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }
}

/// @title StargateDiagnosticCommandRecoveryMarkTest
/// @notice IL-8612 / TP-M-34: a value-neutral command that is not recovery-marked reverts in a batch of its own
///         while the market's live NAV is fail-closed. Stargate `CANCEL_DISPATCHER_REQUEST` is now marked;
///         config-changing commands stay blocked.
contract StargateDiagnosticCommandRecoveryMarkTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant CACHED = 50e6;

    MockERC20 internal usdc;
    DiagnosticCommandVaultHarness internal vault;
    MockExecutor internal executor;
    StargateCrosschainCommandFuse internal commandFuse;
    CrosschainBalanceFuse internal balanceFuse;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new DiagnosticCommandVaultHarness(address(usdc));
        commandFuse = new StargateCrosschainCommandFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(0), address(0), address(commandFuse), address(balanceFuse));
        executor = new MockExecutor(address(vault), address(usdc));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(MARKET, subs);
        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));
        vault.setCachedMarketBalance(MARKET, CACHED);
        executor.setBalanceReverts(true); // live NAV fail-closed
    }

    function _cmd(StargateCrosschainCommandType type_)
        internal
        view
        returns (StargateCrosschainCommandFuseEnterData memory d)
    {
        d.commandType = type_;
        d.executor = address(executor);
        d.chainId = 42161;
        d.requestId = 7;
    }

    function testCancelDispatcherRequestShouldSucceedWhileNavIsFailClosed() public {
        uint256 value = vault.stargateCommandThenNav(_cmd(StargateCrosschainCommandType.CANCEL_DISPATCHER_REQUEST));

        assertEq(executor.lastCancelRequestId(), 7, "the cancel reached the executor");
        assertEq(value, 50e18, "the cached market value was served instead of reverting");
    }

    function testConfigCommandShouldStillRevertWhileNavIsFailClosed() public {
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.stargateCommandThenNav(_cmd(StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS));

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.stargateCommandThenNav(_cmd(StargateCrosschainCommandType.CREATE_DISPATCHER));
    }
}

/// @title CcipDiagnosticCommandRecoveryMarkTest
/// @notice Same for CCIP `REFRESH_BALANCE` (`requestRemoteBalance`), against a real executor whose live NAV is
///         fail-closed (a settled bucket with no approved observation: `ObservationStale`).
contract CcipDiagnosticCommandRecoveryMarkTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;

    MockERC20 internal token;
    MockCcipRouter internal router;
    DiagnosticCommandVaultHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    CcipCrosschainCommandFuse internal commandFuse;
    address internal ccipFactory;

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        ccipFactory = factory;
        vault = new DiagnosticCommandVaultHarness(address(token));
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
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
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

        commandFuse = new CcipCrosschainCommandFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(0), address(0), address(0), address(balanceFuse));
        vault.setCcipFuses(address(0), address(commandFuse));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(MARKET, subs);
        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(token), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));

        // 100e6 settles on the remote chain with no approved observation: live NAV is fail-closed.
        token.mint(address(executor), 100e6);
        vm.prank(address(vault));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e6, 0, address(0), 2_000_000);
        vault.setCachedMarketBalance(MARKET, 100e6);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function _data(CcipCommandType type_) internal view returns (CcipCommandFuseEnterData memory d) {
        d.commandType = type_;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
        d.gasLimit = 2_000_000;
        d.command = Command({commandId: bytes32(0), sequence: 0, commandConfigEpoch: 0, action: 0, minExecutionGas: 0, actionData: ""});
    }

    function testRefreshBalanceShouldSucceedWhileNavIsFailClosed() public {
        uint256 value = vault.ccipCommandThenNav(_data(CcipCommandType.REFRESH_BALANCE));

        assertEq(value, 100e18, "the cached market value was served instead of reverting");
    }

    /// @dev A second dispatcher chain that is blocked and tracks value (stdstore: the bit and a settled bucket), while
    ///      the first chain is stale so that `getBalance()` surfaces `ObservationStale` BEFORE reaching it.
    function _blockSecondChainWithValue() internal returns (uint256 otherChain) {
        otherChain = 10;
        vm.prank(ccipFactory);
        executor.markDispatcherReady(otherChain);
        stdstore.target(address(executor)).sig("settledRemoteBalance(uint256)").with_key(otherChain).checked_write(
            uint256(5e6)
        );
        stdstore.target(address(executor)).sig("chainBlocked(uint256)").with_key(otherChain).checked_write(true);
        assertTrue(executor.chainBlocked(otherChain), "second chain blocked");
    }

    /// @dev IL-8611 follow-up: a staleness selector surfaces before a blocked chain with value. In a multi-executor
    ///      market the recovery batch must still revert `ChainBlocked`, because `getBalanceUnchecked()` refuses.
    function testRefreshBalanceShouldRevertWhenStalenessSurfacesBeforeABlockedChainWithValueOnCcip() public {
        uint256 otherChain = _blockSecondChainWithValue();
        MockExecutor sibling = new MockExecutor(address(vault), address(token));
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(sibling));
        vault.grantSubstrates(MARKET, subs);

        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, otherChain));
        executor.getBalanceUnchecked();

        CcipCommandFuseEnterData memory d = _data(CcipCommandType.REFRESH_BALANCE);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, otherChain));
        vault.ccipCommandThenNav(d);
    }

    /// @dev A blocked chain with EMPTY books does not make the unchecked view revert, matching `getBalance()`.
    function testGetBalanceUncheckedShouldNotRevertForABlockedChainWithEmptyBooksOnCcip() public {
        vm.prank(ccipFactory);
        executor.markDispatcherReady(10);
        stdstore.target(address(executor)).sig("chainBlocked(uint256)").with_key(uint256(10)).checked_write(true);
        assertTrue(executor.chainBlocked(10), "empty chain blocked");

        assertEq(executor.getBalanceUnchecked(), 100e6, "booked balance of the first chain only");
    }

    /// @dev IL-8611 follow-up: the unchecked view refuses to serve a blocked chain that tracks value
    ///      (known-inconsistent books until a rescue completes), even though it skips the staleness gates.
    function testGetBalanceUncheckedShouldRevertChainBlockedWhileAChainIsBlockedOnCcip() public {
        vm.warp(block.timestamp + 1); // the observation must postdate the value-moving send
        uint64 stateVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(address(0xA33));
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            100e6,
            stateVersion,
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 30 minutes),
            bytes32(0)
        );
        vm.prank(address(0xB44));
        executor.rejectBalanceAndBlock(proposalId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "chain blocked");

        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalanceUnchecked();
    }

    /// @dev IL-8611: the unchecked view returns the booked value exactly where `getBalance()` fails closed on
    ///      staleness.
    function testGetBalanceUncheckedShouldReturnTheBookedValueWhereGetBalanceRevertsOnCcip() public view {
        assertEq(executor.getBalanceUnchecked(), 100e6);
    }

    function testConfigCommandShouldStillRevertWhileNavIsFailClosed() public {
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.UPDATE_VAULTS);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        vault.ccipCommandThenNav(d);
    }
}
