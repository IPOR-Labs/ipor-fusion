// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

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
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {DiagnosticCommandVaultHarness} from "./DiagnosticCommandRecoveryMarkTest.t.sol";

/// @title StargateRecoveryMarkerRedeemFamilyTest
/// @notice IL-9115 / C-007: REDEEM, REQUEST_SHARES and REDEEM_FROM_REQUEST (fresh and retried) arm the recovery
///         marker, observed through the balance fuse serving the cached NAV while the live read is fail-closed.
///         Removing the `markRecovery` call on any of these paths turns the matching test into a `NavSettledStale`
///         revert.
contract StargateRecoveryMarkerRedeemFamilyTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant CHAIN = 42161;
    uint256 internal constant CACHED = 100e6;
    address internal constant REMOTE_VAULT = address(0xBEEF);
    address internal constant WITHDRAW_MANAGER = address(0xCAFE);

    MockERC20 internal usdc;
    DiagnosticCommandVaultHarness internal vault;
    MockExecutor internal executor;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new DiagnosticCommandVaultHarness(address(usdc));
        StargateCrosschainCommandFuse commandFuse = new StargateCrosschainCommandFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(0), address(0), address(commandFuse), address(balanceFuse));
        executor = new MockExecutor(address(vault), address(usdc));
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        subs[1] = CrosschainSubstrateLib.remoteVaultSubstrate(CHAIN, REMOTE_VAULT);
        vault.grantSubstrates(MARKET, subs);
        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));
        vault.setCachedMarketBalance(MARKET, CACHED);
        executor.setBalanceReverts(true); // live NAV fail-closed
    }

    function _send(
        uint8 action_,
        bytes memory actionData_
    ) internal view returns (StargateCrosschainCommandFuseEnterData memory d) {
        d.commandType = StargateCrosschainCommandType.SEND_COMMAND;
        d.executor = address(executor);
        d.chainId = CHAIN;
        d.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: action_,
            minExecutionGas: 0,
            actionData: actionData_
        });
    }

    function _retry() internal view returns (StargateCrosschainCommandFuseEnterData memory d) {
        d.commandType = StargateCrosschainCommandType.RETRY_COMMAND;
        d.executor = address(executor);
        d.chainId = CHAIN;
    }

    function _expectServed() internal {
        vm.expectEmit(address(vault));
        emit CrosschainBalanceFuse.CrosschainCachedBalanceServed(
            MARKET,
            address(executor),
            MockExecutor.NavSettledStale.selector
        );
    }

    function testStargateSendRedeemServesCachedNavWhileFailClosed() public {
        _expectServed();
        uint256 value = vault.stargateCommandThenNav(
            _send(uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(REMOTE_VAULT, 1e6, 1e6))
        );
        assertEq(value, 100e18, "cached market value served");
        assertEq(executor.lastCommandChainId(), CHAIN, "command reached the executor");
    }

    function testStargateSendRequestSharesServesCachedNavWhileFailClosed() public {
        _expectServed();
        uint256 value = vault.stargateCommandThenNav(
            _send(
                uint8(BusinessAction.REQUEST_SHARES),
                CrosschainMessages.encodeRequestSharesAction(WITHDRAW_MANAGER, REMOTE_VAULT, 1e6, type(uint256).max)
            )
        );
        assertEq(value, 100e18, "cached market value served");
        assertEq(executor.lastCommandChainId(), CHAIN, "command reached the executor");
    }

    function testStargateSendRedeemFromRequestServesCachedNavWhileFailClosed() public {
        _expectServed();
        uint256 value = vault.stargateCommandThenNav(
            _send(
                uint8(BusinessAction.REDEEM_FROM_REQUEST),
                CrosschainMessages.encodeRedeemFromRequestAction(
                    WITHDRAW_MANAGER,
                    REMOTE_VAULT,
                    1e6,
                    1e6,
                    address(vault)
                )
            )
        );
        assertEq(value, 100e18, "cached market value served");
        assertEq(executor.lastCommandChainId(), CHAIN, "command reached the executor");
    }

    function _assertRetryServes(uint8 action_) internal {
        executor.setActiveCommandAction(action_);
        _expectServed();
        uint256 value = vault.stargateCommandThenNav(_retry());
        assertEq(value, 100e18, "cached market value served");
        assertEq(executor.lastRetryChainId(), CHAIN, "retry reached the executor");
    }

    function testStargateRetryOfFailedRedeemServesCachedNav() public {
        _assertRetryServes(uint8(BusinessAction.REDEEM));
    }

    function testStargateRetryOfFailedRequestSharesServesCachedNav() public {
        _assertRetryServes(uint8(BusinessAction.REQUEST_SHARES));
    }

    function testStargateRetryOfFailedRedeemFromRequestServesCachedNav() public {
        _assertRetryServes(uint8(BusinessAction.REDEEM_FROM_REQUEST));
    }

    function testStargateSendDepositStillRevertsWhileFailClosed() public {
        executor.setBalanceReverts(true);
        bytes memory dep = CrosschainMessages.encodeDepositAction(REMOTE_VAULT, 1e6, 1e6);
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.stargateCommandThenNav(_send(uint8(BusinessAction.DEPOSIT), dep));
    }
}

contract CcipRecoveryMarkerRedeemFamilyTest is Test {
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

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
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

    address internal constant REMOTE_VAULT = address(0xBEEF);
    address internal constant WITHDRAW_MANAGER = address(0xCAFE);

    function _grantRemoteVault() internal {
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        subs[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, REMOTE_VAULT);
        vault.grantSubstrates(MARKET, subs);
    }

    function _send(uint8 action_, bytes memory actionData_) internal view returns (CcipCommandFuseEnterData memory d) {
        d.commandType = CcipCommandType.SEND_COMMAND;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
        d.gasLimit = 2_000_000;
        d.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: action_,
            minExecutionGas: 0,
            actionData: actionData_
        });
    }

    function _retry(bytes32 id_) internal view returns (CcipCommandFuseEnterData memory d) {
        d.commandType = CcipCommandType.RETRY_COMMAND;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
        d.gasLimit = 2_000_000;
        d.command.commandId = id_;
    }

    function _expectServed() internal {
        vm.expectEmit(address(vault));
        emit CrosschainBalanceFuse.CrosschainCachedBalanceServed(
            MARKET,
            address(executor),
            CcipExecutorTransferLib.ObservationStale.selector
        );
    }

    function _redeemData() internal pure returns (uint8, bytes memory) {
        return (uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(REMOTE_VAULT, 1e6, 1e6));
    }

    function _requestSharesData() internal pure returns (uint8, bytes memory) {
        return (
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(WITHDRAW_MANAGER, REMOTE_VAULT, 1e6, type(uint256).max)
        );
    }

    function _redeemFromRequestData() internal view returns (uint8, bytes memory) {
        return (
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(WITHDRAW_MANAGER, REMOTE_VAULT, 1e6, 1e6, address(vault))
        );
    }

    function _assertSendServes(uint8 action_, bytes memory data_) internal {
        _grantRemoteVault();
        _expectServed();
        uint256 value = vault.ccipCommandThenNav(_send(action_, data_));
        assertEq(value, 100e18, "cached market value served");
        assertTrue(executor.activeCommand(REMOTE_CHAIN) != bytes32(0), "command reached the executor");
    }

    /// @dev The remote vault is not allowlisted on the dispatcher, so the first send is NACKed: a FAILED command.
    function _assertRetryServes(uint8 action_, bytes memory data_) internal {
        _grantRemoteVault();
        vault.ccipCommandThenNav(_send(action_, data_));
        bytes32 id = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "precondition: FAILED");
        assertEq(executor.commandAction(id), action_, "stored action");

        _expectServed();
        uint256 value = vault.ccipCommandThenNav(_retry(id));
        assertEq(value, 100e18, "cached market value served");
    }

    function testCcipSendRedeemServesCachedNavWhileFailClosed() public {
        (uint8 a, bytes memory d) = _redeemData();
        _assertSendServes(a, d);
    }

    function testCcipSendRequestSharesServesCachedNavWhileFailClosed() public {
        (uint8 a, bytes memory d) = _requestSharesData();
        _assertSendServes(a, d);
    }

    function testCcipSendRedeemFromRequestServesCachedNavWhileFailClosed() public {
        (uint8 a, bytes memory d) = _redeemFromRequestData();
        _assertSendServes(a, d);
    }

    function testCcipRetryOfFailedRedeemServesCachedNav() public {
        (uint8 a, bytes memory d) = _redeemData();
        _assertRetryServes(a, d);
    }

    function testCcipRetryOfFailedRequestSharesServesCachedNav() public {
        (uint8 a, bytes memory d) = _requestSharesData();
        _assertRetryServes(a, d);
    }

    function testCcipRetryOfFailedRedeemFromRequestServesCachedNav() public {
        (uint8 a, bytes memory d) = _redeemFromRequestData();
        _assertRetryServes(a, d);
    }

    function testCcipSendDepositStillRevertsWhileFailClosed() public {
        _grantRemoteVault();
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        vault.ccipCommandThenNav(
            _send(uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(REMOTE_VAULT, 1e6, 1e6))
        );
    }
}
