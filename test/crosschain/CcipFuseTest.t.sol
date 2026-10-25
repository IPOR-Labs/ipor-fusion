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
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

contract CcipFuseTest is Test {
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

        supplyFuse = new CcipCrosschainSupplyFuse(MARKET);
        commandFuse = new CcipCrosschainCommandFuse(MARKET);
        vault.setCcipFuses(address(supplyFuse), address(commandFuse));
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(MARKET, substrates);
    }

    function testShouldUseUnchangedExecutorSubstrateForCcipLifecycle() public {
        token.mint(address(vault), 100e6);
        vault.enterCcipSupply(
            CcipSupplyFuseEnterData({
                executor: address(executor),
                asset: address(token),
                dstChainId: REMOTE_CHAIN,
                amount: 100e6,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 2_000_000,
                minDelivered: 0
            })
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6);
        assertEq(dispatcher.trackedIdle(), 100e6);

        vault.exitCcipSupply(
            CcipSupplyFuseExitData({
                executor: address(executor),
                dstChainId: REMOTE_CHAIN,
                amount: 100e6,
                minReturn: 100e6,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 2_000_000
            })
        );
        assertEq(executor.idleLedger(), 100e6);
        assertEq(dispatcher.trackedIdle(), 0);
    }

    function testShouldCancelPendingRecallThroughCommandFuse() public {
        token.mint(address(vault), 100e6);
        vault.enterCcipSupply(
            CcipSupplyFuseEnterData({
                executor: address(executor),
                asset: address(token),
                dstChainId: REMOTE_CHAIN,
                amount: 100e6,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 2_000_000,
                minDelivered: 0
            })
        );
        uint64 stateVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        address balanceProposer = executor.BALANCE_PROPOSER();
        address balanceApprover = executor.BALANCE_APPROVER();
        bytes32 positionSetHash = dispatcher.trackedPositionSetHash();
        vm.prank(balanceProposer);
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            100e6,
            stateVersion,
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            positionSetHash
        );
        vm.prank(balanceApprover);
        executor.approveBalance(proposalId);
        router.setAutoDeliver(false);
        vault.exitCcipSupply(
            CcipSupplyFuseExitData({
                executor: address(executor),
                dstChainId: REMOTE_CHAIN,
                amount: 40e6,
                minReturn: 40e6,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 2_000_000
            })
        );
        assertTrue(executor.activeReturn(REMOTE_CHAIN) != bytes32(0));

        address[] memory noVaults = new address[](0);
        vault.enterCcipCommand(
            CcipCommandFuseEnterData({
                commandType: CcipCommandType.CANCEL_RETURN,
                executor: address(executor),
                chainId: REMOTE_CHAIN,
                route: CcipRouteConfig({
                    chainSelector: 0,
                    peer: address(0),
                    feeToken: address(0),
                    messageGasLimit: 0,
                    tokenGasLimit: 0,
                    maxFee: 0,
                    enabled: false
                }),
                plasmaVaults: noVaults,
                vaultsAllowed: false,
                vaultsReplace: false,
                command: Command({
                    commandId: bytes32(0),
                    sequence: 0,
                    commandConfigEpoch: 0,
                    action: 0,
                    minExecutionGas: 0,
                    actionData: ""
                }),
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 0
            })
        );

        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "command fuse clears local recall slot");
        assertEq(executor.getBalance(), 100e6, "cancel does not mutate NAV");
    }

    // ---------------------------------------------------------------------
    // IL-8474: `CrosschainCommandFuseEnter` is emitted by the vault (delegatecall context). `vm.expectEmit`
    // is unusable through the harness's delegatecall, so the logs are recorded and decoded by hand.
    // ---------------------------------------------------------------------

    bytes32 internal constant FUSE_ENTER_TOPIC = keccak256("CrosschainCommandFuseEnter(address,address,uint8,uint256)");

    function _emptyRoute() private pure returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: 0,
                peer: address(0),
                feeToken: address(0),
                messageGasLimit: 0,
                tokenGasLimit: 0,
                maxFee: 0,
                enabled: false
            });
    }

    function _assertFuseEnterLogged(Vm.Log[] memory logs_, CcipCommandType commandType_) private view {
        uint256 matches;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] != FUSE_ENTER_TOPIC) continue;
            assertEq(logs_[i].emitter, address(vault), "emitted by the vault");
            (address version, address exec, uint8 commandType, uint256 chainId) = abi.decode(
                logs_[i].data,
                (address, address, uint8, uint256)
            );
            assertEq(version, address(commandFuse), "fuse version");
            assertEq(exec, address(executor), "executor");
            assertEq(commandType, uint8(commandType_), "command type");
            assertEq(chainId, REMOTE_CHAIN, "chain id");
            ++matches;
        }
        assertEq(matches, 1, "exactly one CrosschainCommandFuseEnter");
    }

    function testShouldEmitCrosschainCommandFuseEnterOnUpdateVaults() public {
        vm.recordLogs();
        vault.enterCcipCommand(
            CcipCommandFuseEnterData({
                commandType: CcipCommandType.UPDATE_VAULTS,
                executor: address(executor),
                chainId: REMOTE_CHAIN,
                route: _emptyRoute(),
                plasmaVaults: new address[](0),
                vaultsAllowed: false,
                vaultsReplace: false,
                command: Command({
                    commandId: bytes32(0),
                    sequence: 0,
                    commandConfigEpoch: 0,
                    action: 0,
                    minExecutionGas: 0,
                    actionData: ""
                }),
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 2_000_000
            })
        );
        _assertFuseEnterLogged(vm.getRecordedLogs(), CcipCommandType.UPDATE_VAULTS);
    }

    function testShouldEmitCrosschainCommandFuseEnterOnSendCommand() public {
        address remoteVault = address(0xBEEF);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, remoteVault);
        vault.grantSubstrates(MARKET, substrates);

        vm.recordLogs();
        vault.enterCcipCommand(
            CcipCommandFuseEnterData({
                commandType: CcipCommandType.SEND_COMMAND,
                executor: address(executor),
                chainId: REMOTE_CHAIN,
                route: _emptyRoute(),
                plasmaVaults: new address[](0),
                vaultsAllowed: false,
                vaultsReplace: false,
                command: Command({
                    commandId: bytes32(0),
                    sequence: 0,
                    commandConfigEpoch: 0,
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: 0,
                    actionData: CrosschainMessages.encodeDepositAction(remoteVault, 1e6, 1e6)
                }),
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 2_000_000
            })
        );
        _assertFuseEnterLogged(vm.getRecordedLogs(), CcipCommandType.SEND_COMMAND);
    }

    function testShouldRevertWhenAlphaPassesGasLimitBelowRoutePolicyThroughSupplyFuse() public {
        token.mint(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(CcipSendLib.CcipGasLimitBelowRoutePolicy.selector, 100_000, 2_000_000));
        vault.enterCcipSupply(
            CcipSupplyFuseEnterData({
                executor: address(executor),
                asset: address(token),
                dstChainId: REMOTE_CHAIN,
                amount: 100e6,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 100_000,
                minDelivered: 0
            })
        );
    }

    /// @dev IL-9003: with a settled remote balance and no balance attestation the real executor's `getBalance()`
    ///      reverts `ObservationStale`; the supply fuse's NAV read must stop a second enter before any value moves.
    ///      `sendAssetToDispatcher` has no such check, so removing the fuse's `getBalance()` read makes this fail.
    function testShouldBlockNewCcipRemoteSupplyWhenNavBlocked() public {
        token.mint(address(vault), 200e6);
        CcipSupplyFuseEnterData memory data = CcipSupplyFuseEnterData({
            executor: address(executor),
            asset: address(token),
            dstChainId: REMOTE_CHAIN,
            amount: 100e6,
            maxFee: 0,
            feeToken: address(0),
            gasLimit: 2_000_000,
            minDelivered: 0
        });
        vault.enterCcipSupply(data);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "first supply settled");

        // NAV is now fail-closed: settled balance but no approved attestation.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();

        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 executorBefore = token.balanceOf(address(executor));
        uint256 settledBefore = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 idleBefore = dispatcher.trackedIdle();

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ObservationStale.selector, REMOTE_CHAIN));
        vault.enterCcipSupply(data);

        assertEq(token.balanceOf(address(vault)), vaultBefore, "vault balance unchanged");
        assertEq(token.balanceOf(address(executor)), executorBefore, "executor balance unchanged");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "settled unchanged");
        assertEq(dispatcher.trackedIdle(), idleBefore, "nothing reached the dispatcher");
    }
}
