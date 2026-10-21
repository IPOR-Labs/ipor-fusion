// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipCrosschainSupplyFuse} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

/// @title CcipCommandFuseCancelDeploymentTest
/// @notice IL-8637 R1: a PlasmaVault that is the executor's MANAGER cancels an expired deployment ticket through the
///         command fuse's `CANCEL_DEPLOYMENT`, inside the factory's exclusive window (owner and manager from
///         `createdAt + DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN`, everyone else `DEPLOYMENT_CANCEL_GRACE` later).
///         Real factory and executor; the vault is the delegatecall harness used by the other fuse suites.
/// @dev Negative (re-injection): remove the `CANCEL_DEPLOYMENT` branch from the fuse -> the vault's cancel reverts
///      `CcipCommandFuseUnsupportedCommand(9)` -> `testVaultCancelsInsideTheExclusiveWindow` fails.
contract CcipCommandFuseCancelDeploymentTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant REMOTE_SELECTOR = 15971525489660198786;
    uint64 internal constant LOCAL_SELECTOR = 5009297550715157269;
    uint256 internal constant MAX_FEE = 0.01 ether;
    uint256 internal constant FEE = 0.001 ether;
    bytes32 internal constant FUSE_ENTER_TOPIC = keccak256("CrosschainCommandFuseEnter(address,address,uint8,uint256)");

    uint256 internal LOCAL_CHAIN;
    MockCcipRouter internal router;
    MockERC20 internal token;
    CcipCrosschainFactory internal factory;
    CrosschainVaultHarness internal vault;
    CcipCrosschainCommandFuse internal commandFuse;
    address internal executor;
    address internal stranger;

    function setUp() public {
        LOCAL_CHAIN = block.chainid;
        router = new MockCcipRouter();
        token = new MockERC20("USD Coin", "USDC", 6);
        factory = new CcipCrosschainFactory(address(router), address(this));
        factory.scheduleAsset(ASSET_ID, address(token), 6);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeAsset(ASSET_ID, address(token), 6);
        factory.configureCreationCodes(
            type(CcipCrosschainExecutor).creationCode, type(CcipCrosschainDispatcher).creationCode
        );
        _setFactoryRoute(REMOTE_CHAIN, REMOTE_SELECTOR);
        vm.chainId(REMOTE_CHAIN);
        _setFactoryRoute(LOCAL_CHAIN, LOCAL_SELECTOR);
        vm.chainId(LOCAL_CHAIN);
        router.setAutoDeliver(false);
        router.setFee(FEE);
        vm.deal(address(factory), 20 * FEE);

        vault = new CrosschainVaultHarness(address(token));
        commandFuse = new CcipCrosschainCommandFuse(MARKET);
        vault.setCcipFuses(address(new CcipCrosschainSupplyFuse(MARKET)), address(commandFuse));
        executor = factory.createExecutor(bytes32("il8637-r1"), ASSET_ID, address(vault), _safety());
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(executor);
        vault.grantSubstrates(MARKET, substrates);
        stranger = makeAddr("stranger");
    }

    function _setFactoryRoute(uint256 chainId_, uint64 selector_) private {
        CcipRouteConfig memory route = CcipRouteConfig({
            chainSelector: selector_,
            peer: address(factory),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 700_000,
            maxFee: MAX_FEE,
            enabled: true
        });
        factory.scheduleFactoryRoute(chainId_, route);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeFactoryRoute(chainId_, route);
    }

    function _safety() private pure returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: address(0xA11),
            rescueGuardian: address(0xB22),
            balanceProposer: address(0xA33),
            balanceApprover: address(0xB44),
            rescueDelay: 3 days,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000,
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }

    function _data(CcipCommandType type_) private view returns (CcipCommandFuseEnterData memory) {
        return CcipCommandFuseEnterData({
            commandType: type_,
            executor: executor,
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
            plasmaVaults: new address[](0),
            vaultsAllowed: false,
            vaultsReplace: false,
            command: Command({
                commandId: bytes32(0), sequence: 0, commandConfigEpoch: 0, action: 0, minExecutionGas: 0, actionData: ""
            }),
            maxFee: MAX_FEE,
            feeToken: address(0),
            gasLimit: 0
        });
    }

    /// @dev The vault sends the ticket through the fuse (`CREATE_DISPATCHER`); returns the owner / manager and the
    ///      public cancel thresholds (cancel is allowed strictly after each).
    function _requestThroughVault() private returns (bytes32 ticketHash, uint256 ownerAt, uint256 publicAt) {
        vault.enterCcipCommand(_data(CcipCommandType.CREATE_DISPATCHER));
        ticketHash = factory.pendingDeploymentTicket(executor, REMOTE_CHAIN);
        assertTrue(ticketHash != bytes32(0), "ticket pending");
        uint256 createdAt = factory.pendingDeploymentCreatedAt(executor, REMOTE_CHAIN);
        ownerAt = createdAt + factory.DEPLOYMENT_TTL() + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        publicAt = ownerAt + CrosschainConstants.DEPLOYMENT_CANCEL_GRACE;
    }

    function testVaultCancelsInsideTheExclusiveWindow() public {
        (bytes32 ticketHash, uint256 ownerAt, uint256 publicAt) = _requestThroughVault();
        vm.warp(ownerAt + 1);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.DeploymentNotExpired.selector, executor, REMOTE_CHAIN, publicAt)
        );
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);

        vm.recordLogs();
        vault.enterCcipCommand(_data(CcipCommandType.CANCEL_DEPLOYMENT));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "ticket dropped by the vault");
        assertEq(factory.cancelledDeploymentTicket(executor, REMOTE_CHAIN), ticketHash, "last cancel recorded");
        assertTrue(factory.isCancelledDeploymentTicket(executor, REMOTE_CHAIN, ticketHash), "late ACK stays acceptable");
        bool cancelled;
        bool fuseEnter;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == CcipCrosschainFactory.DeploymentCancelled.selector) {
                cancelled = true;
            }
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == FUSE_ENTER_TOPIC) {
                (, address loggedExecutor, uint8 commandType, uint256 chainId) =
                    abi.decode(logs[i].data, (address, address, uint8, uint256));
                assertEq(loggedExecutor, executor);
                assertEq(commandType, uint8(CcipCommandType.CANCEL_DEPLOYMENT));
                assertEq(chainId, REMOTE_CHAIN);
                fuseEnter = true;
            }
        }
        assertTrue(cancelled, "DeploymentCancelled from the factory");
        assertTrue(fuseEnter, "CrosschainCommandFuseEnter from the vault");

        // The pair is free again: the vault can send a new ticket at once.
        vault.enterCcipCommand(_data(CcipCommandType.CREATE_DISPATCHER));
        assertTrue(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN) != bytes32(0), "new ticket pending");
    }

    function testVaultCannotCancelBeforeTtlPlusMargin() public {
        (, uint256 ownerAt,) = _requestThroughVault();
        vm.warp(ownerAt);
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.DeploymentNotExpired.selector, executor, REMOTE_CHAIN, ownerAt)
        );
        vault.enterCcipCommand(_data(CcipCommandType.CANCEL_DEPLOYMENT));
    }

    function testVaultCancelWithoutPendingTicketReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.NoPendingDeployment.selector, executor, REMOTE_CHAIN)
        );
        vault.enterCcipCommand(_data(CcipCommandType.CANCEL_DEPLOYMENT));
    }

    function testCancelDeploymentIsTheNinthCommandType() public pure {
        assertEq(uint8(CcipCommandType.CANCEL_DEPLOYMENT), 9, "appended after CANCEL_COMMAND, existing values unchanged");
        assertEq(uint8(CcipCommandType.CANCEL_COMMAND), 8);
    }
}
