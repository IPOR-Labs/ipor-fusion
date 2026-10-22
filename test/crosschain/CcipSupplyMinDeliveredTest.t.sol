// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipSendLib} from "../../contracts/crosschain/ccip/lib/CcipSendLib.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {
    CcipCrosschainSupplyFuse,
    CcipSupplyFuseEnterData,
    CcipSupplyFuseExitData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

/// @notice IL-8581 (TP-M-03): a CCIP token pool may deliver less than was sent. Settlement reports the shortfall and
///         a missed `minDelivered` floor without reverting or blocking the chain.
contract CcipSupplyMinDeliveredTest is Test {
    event SettledCreditShortfall(uint256 chainId, bytes32 operationId, uint256 amountSD, uint256 receivedSD);
    event SettledBelowMinDelivered(uint256 chainId, bytes32 operationId, uint256 minDeliveredSD, uint256 receivedSD);
    event CcipSupplyFuseEnter(address version, address executor, uint256 chainId, uint256 amount, uint256 minDelivered);

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;

    MockERC20 internal token;
    MockCcipRouter internal router;
    CrosschainVaultHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    CcipCrosschainSupplyFuse internal supplyFuse;
    CcipCrosschainCommandFuse internal commandFuse;
    address internal factory;

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        vault = new CrosschainVaultHarness(address(token));
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
                bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
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
                messageGasLimit: 500_000,
                tokenGasLimit: 500_000,
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
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);

        supplyFuse = new CcipCrosschainSupplyFuse(MARKET);
        commandFuse = new CcipCrosschainCommandFuse(MARKET);
        vault.setCcipFuses(address(supplyFuse), address(commandFuse));
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(MARKET, substrates);
    }

    function _enter(uint256 amount_, uint256 minDelivered_) private {
        vault.enterCcipSupply(
            CcipSupplyFuseEnterData({
                executor: address(executor),
                asset: address(token),
                dstChainId: REMOTE_CHAIN,
                amount: amount_,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 500_000,
                minDelivered: minDelivered_
            })
        );
    }

    function testShouldEmitShortfallWhenPoolDeliversLess() public {
        token.mint(address(vault), 100e6);
        router.setPoolHaircutBps(1_000); // 10% withheld by the pool -> 90e6 delivered
        vm.recordLogs();
        _enter(100e6, 0);
        Scan memory scan = _scan(vm.getRecordedLogs());
        assertEq(scan.shortfallCount, 1, "one shortfall event");
        assertEq(scan.belowCount, 0, "no floor set, no below-min event");
        assertEq(scan.shortfallChainId, REMOTE_CHAIN);
        assertEq(scan.shortfallOpId, scan.settledOpId, "shortfall carries the settled operation id");
        assertEq(scan.shortfallAmountSD, 100e6);
        assertEq(scan.shortfallReceivedSD, 90e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e6, "credit booked = received");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN));
    }

    function testShouldEmitBelowMinDeliveredWhenFloorMissed() public {
        token.mint(address(vault), 100e6);
        router.setPoolHaircutBps(1_000);
        vm.recordLogs();
        _enter(100e6, 95e6);
        Scan memory scan = _scan(vm.getRecordedLogs());
        assertEq(scan.shortfallCount, 1, "one shortfall event");
        assertEq(scan.belowCount, 1, "one below-min event");
        assertEq(scan.shortfallChainId, REMOTE_CHAIN);
        assertEq(scan.shortfallOpId, scan.settledOpId);
        assertEq(scan.shortfallAmountSD, 100e6);
        assertEq(scan.shortfallReceivedSD, 90e6);
        assertEq(scan.belowChainId, REMOTE_CHAIN);
        assertEq(scan.belowOpId, scan.settledOpId);
        assertEq(scan.belowMinSD, 95e6);
        assertEq(scan.belowReceivedSD, 90e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e6, "credit booked = received");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN));
    }

    function testShouldNotEmitBelowMinWhenFloorMet() public {
        token.mint(address(vault), 100e6);
        router.setPoolHaircutBps(1_000);
        vm.recordLogs();
        _enter(100e6, 90e6);
        Scan memory scan = _scan(vm.getRecordedLogs());
        assertEq(scan.shortfallCount, 1, "one shortfall event");
        assertEq(scan.shortfallOpId, scan.settledOpId);
        assertEq(scan.shortfallAmountSD, 100e6);
        assertEq(scan.shortfallReceivedSD, 90e6);
        assertEq(scan.belowCount, 0, "floor met, no below-min event");
    }

    function testShouldNotEmitShortfallOnFullDelivery() public {
        token.mint(address(vault), 100e6);
        vm.recordLogs();
        _enter(100e6, 100e6);
        Scan memory scan = _scan(vm.getRecordedLogs());
        assertEq(scan.shortfallCount, 0, "no shortfall");
        assertEq(scan.belowCount, 0, "no below-min");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6);
    }

    function testShouldRevertWhenMinDeliveredAboveAmount() public {
        token.mint(address(vault), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.InvalidMinDelivered.selector, 100e6 + 1, 100e6)
        );
        _enter(100e6, 100e6 + 1);
    }

    /// @notice The floor is otherwise unreadable (private `Outbound` record, no getter), so the fuse event carries
    ///         it: monitoring can verify the keeper set the intended floor before a shortfall happens.
    function testShouldEmitTheMinDeliveredFloorOnEnter() public {
        token.mint(address(vault), 100e6);
        vm.expectEmit(address(vault)); // the fuse runs by delegatecall, so the vault is the emitter
        emit CcipSupplyFuseEnter(address(supplyFuse), address(executor), REMOTE_CHAIN, 100e6, 95e6);
        _enter(100e6, 95e6);
    }

    function testShouldAcceptZeroMinDelivered() public {
        token.mint(address(vault), 100e6);
        _enter(100e6, 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6);
    }

    /// @notice A transfer force-resolved with `creditToSettled = false` still owes its remote credit when a late
    ///         receipt arrives; the late-credit path must report the same shortfall events.
    function testShouldEmitShortfallOnLateCreditAfterForceResolve() public {
        token.mint(address(vault), 100e6);
        router.setPoolHaircutBps(1_000);
        router.setAutoDeliver(false); // the OUTBOUND_TRANSFER message never reaches the dispatcher
        vm.recordLogs();
        _enter(100e6, 95e6);
        bytes32 operationId = _sentOperationId(vm.getRecordedLogs());

        vm.prank(address(0xA11));
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        executor.executeForceResolveOutbound(rescueId, operationId, false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "dropped, not yet credited");

        vm.recordLogs();
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("late-settle"),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(CcipMsgType.TRANSFER_SETTLED, abi.encode(operationId, 90e6, 90e6, 1)),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
        Scan memory scan = _scan(vm.getRecordedLogs());
        assertEq(scan.settledOpId, operationId, "late credit settled the force-resolved op");
        assertEq(scan.shortfallCount, 1, "one shortfall event");
        assertEq(scan.belowCount, 1, "one below-min event");
        assertEq(scan.shortfallChainId, REMOTE_CHAIN);
        assertEq(scan.shortfallOpId, operationId);
        assertEq(scan.shortfallAmountSD, 100e6);
        assertEq(scan.shortfallReceivedSD, 90e6);
        assertEq(scan.belowChainId, REMOTE_CHAIN);
        assertEq(scan.belowOpId, operationId);
        assertEq(scan.belowMinSD, 95e6);
        assertEq(scan.belowReceivedSD, 90e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e6, "late credit books what arrived");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN));
    }

    struct Scan {
        uint256 shortfallCount;
        uint256 belowCount;
        bytes32 settledOpId;
        uint256 shortfallChainId;
        bytes32 shortfallOpId;
        uint256 shortfallAmountSD;
        uint256 shortfallReceivedSD;
        uint256 belowChainId;
        bytes32 belowOpId;
        uint256 belowMinSD;
        uint256 belowReceivedSD;
    }

    function _sentOperationId(Vm.Log[] memory logs_) private view returns (bytes32 operationId) {
        for (uint256 i; i < logs_.length; ++i) {
            if (
                logs_[i].emitter == address(executor)
                    && logs_[i].topics[0] == CcipCrosschainExecutor.AssetSent.selector
            ) {
                (, operationId, , ) = abi.decode(logs_[i].data, (uint256, bytes32, bytes32, uint256));
                return operationId;
            }
        }
        revert("AssetSent not emitted");
    }

    function _scan(Vm.Log[] memory logs_) private view returns (Scan memory r) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter != address(executor)) continue;
            bytes32 topic = logs_[i].topics[0];
            if (topic == SettledCreditShortfall.selector) {
                ++r.shortfallCount;
                (r.shortfallChainId, r.shortfallOpId, r.shortfallAmountSD, r.shortfallReceivedSD) = abi.decode(
                    logs_[i].data,
                    (uint256, bytes32, uint256, uint256)
                );
            } else if (topic == SettledBelowMinDelivered.selector) {
                ++r.belowCount;
                (r.belowChainId, r.belowOpId, r.belowMinSD, r.belowReceivedSD) = abi.decode(
                    logs_[i].data,
                    (uint256, bytes32, uint256, uint256)
                );
            } else if (topic == CcipCrosschainExecutor.AssetSettled.selector) {
                (, r.settledOpId, ) = abi.decode(logs_[i].data, (uint256, bytes32, uint256));
            }
        }
    }
}
