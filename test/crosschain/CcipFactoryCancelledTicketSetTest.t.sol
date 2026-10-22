// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

/// @title CcipFactoryCancelledTicketSetTest
/// @notice IL-8637 R2: every cancelled ticket hash is kept (`isCancelledDeploymentTicket`), so a later cancel of a
///         different ticket no longer orphans an earlier ticket's late DEPLOYMENT_ACK. Same harness as
///         `CcipFactoryDeploymentRecoveryTest` (one factory, hand-built ACK / NACK, a reverted delivery stays
///         executable and is delivered again later).
/// @dev Negative (re-injection): match the late ACK against `cancelledDeploymentTicket` (last cancel only) instead of
///      the set -> `testLateAckOfFirstTicketSurvivesSecondCancel`, `testLateAckAfterThreeCancelsNeedsNoOwnerReset` and
///      `testLateAckWaitsForNewerTicketThenLands` revert `UnknownDeploymentAck` -> fail.
contract CcipFactoryCancelledTicketSetTest is Test {
    MockCcipRouter internal router;
    MockERC20 internal token;
    CcipCrosschainFactory internal factory;

    bytes32 internal constant ASSET_ID = keccak256("USDC");
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant REMOTE_SELECTOR = 15971525489660198786;
    uint64 internal constant LOCAL_SELECTOR = 5009297550715157269;
    uint256 internal constant MAX_FEE = 0.01 ether;
    uint256 internal constant FEE = 0.001 ether;
    uint256 internal LOCAL_CHAIN;
    address internal manager;

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
        vm.deal(address(factory), 50 * FEE);
        manager = makeAddr("manager");
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

    function _executor(bytes32 salt_) private returns (address) {
        return factory.createExecutor(
            salt_,
            ASSET_ID,
            manager,
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
    }

    function _list(address vault_) private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = vault_;
    }

    function _request(address executor_, address vault_) private returns (bytes32 ticketHash) {
        vm.prank(manager);
        factory.requestDispatcher(executor_, REMOTE_CHAIN, _list(vault_), MAX_FEE);
        ticketHash = factory.pendingDeploymentTicket(executor_, REMOTE_CHAIN);
    }

    function _requestAndOwnerCancel(address executor_, address vault_) private returns (bytes32 ticketHash) {
        ticketHash = _request(executor_, vault_);
        vm.warp(
            uint256(factory.pendingDeploymentCreatedAt(executor_, REMOTE_CHAIN)) + factory.DEPLOYMENT_TTL()
                + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1
        );
        factory.cancelExpiredDeployment(executor_, REMOTE_CHAIN);
        assertTrue(factory.isCancelledDeploymentTicket(executor_, REMOTE_CHAIN, ticketHash), "kept in the set");
    }

    function _deliver(CcipMsgType msgType_, bytes memory data_, bytes32 messageId_) private {
        vm.prank(address(router));
        factory.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: messageId_,
                sourceChainSelector: REMOTE_SELECTOR,
                sender: abi.encode(address(factory)),
                data: CcipMessages.encode(msgType_, data_),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    function _ack(address executor_, bytes32 hash_) private pure returns (bytes memory) {
        return abi.encode(executor_, REMOTE_CHAIN, hash_);
    }

    function _unknown(address executor_, bytes32 hash_) private pure returns (bytes memory) {
        return abi.encodeWithSelector(CcipCrosschainFactory.UnknownDeploymentAck.selector, executor_, REMOTE_CHAIN, hash_);
    }

    /// @notice The R2 sequence: T1 cancelled, T2 sent and cancelled too (its NACK(1) is stuck as well); T1's ACK is
    ///         still accepted and completes the pair.
    function testLateAckOfFirstTicketSurvivesSecondCancel() public {
        address executor = _executor("r2-a");
        bytes32 h1 = _requestAndOwnerCancel(executor, address(0xA001));
        bytes32 h2 = _requestAndOwnerCancel(executor, address(0xB002));
        assertEq(factory.cancelledDeploymentTicket(executor, REMOTE_CHAIN), h2, "last-cancel getter = T2");

        vm.expectEmit(address(factory));
        emit CcipCrosschainFactory.DeploymentLateAcked(executor, REMOTE_CHAIN, h1);
        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(executor, h1), "ack-T1");

        assertTrue(CcipCrosschainExecutor(payable(executor)).hasDispatcher(REMOTE_CHAIN), "ready");
        assertFalse(factory.isCancelledDeploymentTicket(executor, REMOTE_CHAIN, h1), "T1 entry consumed");
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 0, "attempts cleared");
    }

    /// @notice Three cancelled tickets used all attempts; T1's ACK still lands, no owner reset needed.
    function testLateAckAfterThreeCancelsNeedsNoOwnerReset() public {
        address executor = _executor("r2-b");
        bytes32 h1 = _requestAndOwnerCancel(executor, address(0xA001));
        _requestAndOwnerCancel(executor, address(0xB002));
        _requestAndOwnerCancel(executor, address(0xC003));
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 3, "attempts exhausted");

        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(executor, h1), "ack-T1");
        assertTrue(CcipCrosschainExecutor(payable(executor)).hasDispatcher(REMOTE_CHAIN), "ready without reset");
    }

    /// @notice A late ACK is still refused while a newer ticket is pending; once that ticket is NACKed (occupied
    ///         address), re-executing the FAILED ACK of the earliest cancelled ticket completes the pair.
    function testLateAckWaitsForNewerTicketThenLands() public {
        address executor = _executor("r2-c");
        bytes32 h1 = _requestAndOwnerCancel(executor, address(0xA001));
        _requestAndOwnerCancel(executor, address(0xB002));
        bytes32 h3 = _request(executor, address(0xC003));

        vm.expectRevert(_unknown(executor, h1));
        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(executor, h1), "ack-T1");

        _deliver(CcipMsgType.DEPLOYMENT_NACK, abi.encode(executor, REMOTE_CHAIN, h3, uint8(1)), "nack-T3");
        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(executor, h1), "ack-T1");
        assertTrue(CcipCrosschainExecutor(payable(executor)).hasDispatcher(REMOTE_CHAIN), "ready");
    }

    /// @notice Only one cancelled ticket can complete the pair: after the first late ACK every other cancelled hash
    ///         is refused by the `hasDispatcher` guard, and the accepted one cannot be replayed.
    function testOnlyOneCancelledTicketCompletesThePair() public {
        address executor = _executor("r2-d");
        bytes32 h1 = _requestAndOwnerCancel(executor, address(0xA001));
        bytes32 h2 = _requestAndOwnerCancel(executor, address(0xB002));

        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(executor, h2), "ack-T2");
        assertTrue(CcipCrosschainExecutor(payable(executor)).hasDispatcher(REMOTE_CHAIN));
        assertTrue(factory.isCancelledDeploymentTicket(executor, REMOTE_CHAIN, h1), "stale entry, inert");

        vm.expectRevert(_unknown(executor, h1));
        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(executor, h1), "ack-T1");
        vm.expectRevert(_unknown(executor, h2));
        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(executor, h2), "ack-T2-replay");
    }

    /// @notice A hash that was never cancelled stays rejected, and the set is per executor.
    function testUnknownHashAndOtherExecutorStayRejected() public {
        address executor = _executor("r2-e");
        address other = _executor("r2-f");
        bytes32 h1 = _requestAndOwnerCancel(executor, address(0xA001));

        vm.expectRevert(_unknown(executor, bytes32(uint256(h1) ^ 1)));
        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(executor, bytes32(uint256(h1) ^ 1)), "ack-unknown");
        vm.expectRevert(_unknown(other, h1));
        _deliver(CcipMsgType.DEPLOYMENT_ACK, _ack(other, h1), "ack-other");
        assertFalse(CcipCrosschainExecutor(payable(other)).hasDispatcher(REMOTE_CHAIN));
    }
}
