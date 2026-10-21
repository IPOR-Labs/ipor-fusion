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
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

/// @notice IL-8579 (requestRemoteBalance metering) and IL-8580 (chainBlocked gate on DEPOSIT / vault-add).
contract CcipBalanceRequestMeteringTest is Test {
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

    uint256 internal constant EXECUTOR_CHAIN_BLOCKED_SLOT = 30; // CcipCrosschainExecutor.chainBlocked

    function _refresh() internal {
        vault.enterCcipCommand(_data(CcipCommandType.REFRESH_BALANCE));
    }

    function _data(CcipCommandType t_) internal view returns (CcipCommandFuseEnterData memory d) {
        d.commandType = t_;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
        d.gasLimit = 2_000_000;
    }

    function _block() internal {
        vm.store(
            address(executor),
            keccak256(abi.encode(REMOTE_CHAIN, EXECUTOR_CHAIN_BLOCKED_SLOT)),
            bytes32(uint256(1))
        );
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "slot constant stale");
    }

    function _grantRemoteVault(address remoteVault_) internal {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, remoteVault_);
        vault.grantSubstrates(MARKET, substrates);
    }

    function _sendCommand(uint8 action_, bytes memory actionData_)
        internal
        view
        returns (CcipCommandFuseEnterData memory d)
    {
        d = _data(CcipCommandType.SEND_COMMAND);
        d.command = Command({
            commandId: bytes32(0), sequence: 0, commandConfigEpoch: 0, action: action_, minExecutionGas: 0, actionData: actionData_
        });
    }

    function testShouldRevertSecondBalanceRequestWhileOutstanding() public {
        router.setAutoDeliver(false);
        _refresh();
        uint64 requestedAt = uint64(block.timestamp);
        vm.warp(block.timestamp + 1 hours); // past the cooldown, still outstanding
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.BalanceRequestOutstanding.selector, REMOTE_CHAIN, requestedAt)
        );
        _refresh();
    }

    function testShouldAllowBalanceRequestAfterReportArrives() public {
        router.setAutoDeliver(false);
        _refresh();
        router.deliverHeld(0); // dispatcher handles the request and queues its report
        router.deliverHeld(1); // executor handles BALANCE_REPORT
        assertFalse(executor.balanceRequestOutstanding(REMOTE_CHAIN), "flag cleared by report");
        vm.warp(block.timestamp + 10 minutes);
        _refresh();
        assertTrue(executor.balanceRequestOutstanding(REMOTE_CHAIN));
    }

    function testShouldAllowBalanceRequestAfterOutstandingExpires() public {
        router.setAutoDeliver(false);
        _refresh();
        vm.warp(block.timestamp + 7 days); // BALANCE_STALENESS_MAX
        _refresh();
        assertEq(executor.lastBalanceRequestAt(REMOTE_CHAIN), block.timestamp);
    }

    function testShouldRevertBalanceRequestWithinCooldown() public {
        _refresh(); // autoDeliver: the report clears the outstanding flag at once
        assertFalse(executor.balanceRequestOutstanding(REMOTE_CHAIN));
        uint256 next = block.timestamp + 10 minutes;
        vm.warp(block.timestamp + 10 minutes - 1);
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.BalanceRequestCooldown.selector, REMOTE_CHAIN, next)
        );
        _refresh();
        vm.warp(next);
        _refresh();
    }

    function testShouldRevertDepositCommandOnBlockedChain() public {
        address remoteVault = address(0xBEEF);
        _grantRemoteVault(remoteVault);
        _block();
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainCommandFuse.CommandFuseChainBlocked.selector, address(executor), REMOTE_CHAIN
            )
        );
        vault.enterCcipCommand(
            _sendCommand(uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(remoteVault, 1e6, 1e6))
        );
    }

    function testShouldRevertVaultAddOnBlockedChain() public {
        address remoteVault = address(0xBEEF);
        _grantRemoteVault(remoteVault);
        _block();
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.UPDATE_VAULTS);
        d.plasmaVaults = new address[](1);
        d.plasmaVaults[0] = remoteVault;
        d.vaultsAllowed = true;
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainCommandFuse.CommandFuseChainBlocked.selector, address(executor), REMOTE_CHAIN
            )
        );
        vault.enterCcipCommand(d);
    }

    function testShouldAllowRedeemCommandOnBlockedChain() public {
        address remoteVault = address(0xBEEF);
        _grantRemoteVault(remoteVault);
        _block();
        router.setAutoDeliver(false);
        vault.enterCcipCommand(
            _sendCommand(uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(remoteVault, 1e6, 1e6))
        );
        assertEq(router.heldCount(), 1, "redeem command sent to the dispatcher");
    }

    function testShouldAllowVaultRemovalOnBlockedChain() public {
        _block();
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.UPDATE_VAULTS);
        d.plasmaVaults = new address[](0);
        d.vaultsAllowed = false;
        vault.enterCcipCommand(d);
        d.vaultsAllowed = true; // empty replace-all removes vaults, cannot add one
        d.vaultsReplace = true;
        vault.enterCcipCommand(d);
    }

    function testShouldAllowRefreshBalanceOnBlockedChain() public {
        _block();
        _refresh();
        assertEq(executor.lastBalanceRequestAt(REMOTE_CHAIN), block.timestamp);
    }
}
