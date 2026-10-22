// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipSendLib} from "../../contracts/crosschain/ccip/lib/CcipSendLib.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

/// @title CcipFactoryDeploymentRecoveryTest
/// @notice IL-8486 (B-37): pins what happens to a `DEPLOYMENT_ACK` / `DEPLOYMENT_NACK` that reaches the source
///         factory only AFTER `cancelExpiredDeployment` dropped its pending ticket.
/// @dev By design (see the factory's `DeploymentTicket`): the ticket carries no nonce, so its hash is a pure
///      function of salt, executor, chains, asset, decimals, `vaults` (order included) and the rescue
///      admin / guardian / delay. A re-request with byte-identical inputs therefore has the SAME hash as the
///      cancelled one, and the late response completes it; any change yields a different hash, so the late
///      response never matches and the destination answers NACK(1) for the occupied address.
///      Harness: `MockCcipRouter.setAutoDeliver(false)` plus hand delivery, like `CcipFactoryBudgetPolicyTest`.
///      A message that reverts on the receiver stays executable (the OffRamp's FAILED state), so "the late
///      response is executed later" is modelled by delivering the SAME payload and message id again after the
///      re-request. The source-side tests build the ACK / NACK by hand (as the budget-policy suite does);
///      the destination's own answer is pinned separately in the last two tests. One factory instance plays
///      both chains via `vm.chainId`.
contract CcipFactoryDeploymentRecoveryTest is Test {
    using stdStorage for StdStorage;

    /// @dev Expiry stamped into a hand-built CREATE_DISPATCHER payload (the factory uses `DEPLOYMENT_TTL`).
    function _expiry() private view returns (uint256) {
        return block.timestamp + 7 days;
    }

    MockCcipRouter internal router;
    MockERC20 internal token;
    CcipCrosschainFactory internal factory;

    bytes32 internal constant ASSET_ID = keccak256("USDC");
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant REMOTE_SELECTOR = 15971525489660198786;
    uint64 internal constant LOCAL_SELECTOR = 5009297550715157269;
    uint256 internal LOCAL_CHAIN;
    uint256 internal constant MAX_FEE = 0.01 ether;
    uint256 internal constant FEE = 0.001 ether;

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
            type(CcipCrosschainExecutor).creationCode,
            type(CcipCrosschainDispatcher).creationCode
        );

        _setFactoryRoute(REMOTE_CHAIN, REMOTE_SELECTOR);
        // The route back to LOCAL_CHAIN is registered from the destination's view (one factory instance plays
        // both sides): a route to the factory's own chain id is refused (IL-8451).
        vm.chainId(REMOTE_CHAIN);
        _setFactoryRoute(LOCAL_CHAIN, LOCAL_SELECTOR);
        vm.chainId(LOCAL_CHAIN);

        router.setAutoDeliver(false);
        router.setFee(FEE);
        vm.deal(address(factory), 20 * FEE);

        manager = makeAddr("manager");
    }

    // ---------------------------------------------------------------------
    // Fixture helpers
    // ---------------------------------------------------------------------

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
        return
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
            });
    }

    function _createExecutor(bytes32 userSalt_) private returns (address) {
        return factory.createExecutor(userSalt_, ASSET_ID, manager, _safety());
    }

    function _vaultsA() private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = address(0xA001);
    }

    function _vaultsB() private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = address(0xB002);
    }

    function _request(address executor_, address[] memory vaults_) private returns (bytes32 ticketHash) {
        vm.prank(manager);
        factory.requestDispatcher(executor_, REMOTE_CHAIN, vaults_, MAX_FEE);
        ticketHash = factory.pendingDeploymentTicket(executor_, REMOTE_CHAIN);
    }

    /// @dev Rebuilds the source ticket from the executor's own getters, field for field as
    ///      `requestDispatcher` does; callers assert it against the stored pending hash.
    function _ticket(
        address executor_,
        address[] memory vaults_
    ) private view returns (CcipCrosschainFactory.DeploymentTicket memory) {
        CcipCrosschainExecutor exec = CcipCrosschainExecutor(payable(executor_));
        return
            CcipCrosschainFactory.DeploymentTicket({
                salt: factory.saltOf(executor_),
                executor: executor_,
                srcChainId: LOCAL_CHAIN,
                dstChainId: REMOTE_CHAIN,
                assetId: exec.ASSET_ID(),
                sharedDecimals: exec.SHARED_DECIMALS(),
                vaults: vaults_,
                rescueAdmin: exec.ADMIN(),
                rescueGuardian: exec.RESCUE_GUARDIAN(),
                rescueDelay: exec.RESCUE_DELAY()
            });
    }

    function _deliver(
        uint64 sourceChainSelector_,
        CcipMsgType msgType_,
        bytes memory data_,
        bytes32 messageId_
    ) private {
        vm.prank(address(router));
        factory.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: messageId_,
                sourceChainSelector: sourceChainSelector_,
                sender: abi.encode(address(factory)),
                data: CcipMessages.encode(msgType_, data_),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    function _ackData(address executor_, bytes32 ticketHash_) private view returns (bytes memory) {
        return abi.encode(executor_, REMOTE_CHAIN, ticketHash_);
    }

    function _nackData(address executor_, bytes32 ticketHash_) private view returns (bytes memory) {
        return abi.encode(executor_, REMOTE_CHAIN, ticketHash_, uint8(1));
    }

    /// @dev Request #1, wait past the TTL, cancel it permissionlessly. Returns its ticket hash.
    function _requestAndCancel(address executor_, address[] memory vaults_) private returns (bytes32 ticketHash) {
        ticketHash = _request(executor_, vaults_);
        assertEq(keccak256(abi.encode(_ticket(executor_, vaults_))), ticketHash, "rebuilt ticket matches");
        vm.warp(block.timestamp + factory.DEPLOYMENT_TTL() + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1);
        factory.cancelExpiredDeployment(executor_, REMOTE_CHAIN);
        assertEq(factory.pendingDeploymentTicket(executor_, REMOTE_CHAIN), bytes32(0), "pending ticket dropped");
    }

    function _unknown(address executor_, bytes32 ticketHash_) private view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                CcipCrosschainFactory.UnknownDeploymentAck.selector,
                executor_,
                REMOTE_CHAIN,
                ticketHash_
            );
    }

    // ---------------------------------------------------------------------
    // Source: late ACK / NACK after cancelExpiredDeployment
    // ---------------------------------------------------------------------

    /// @notice A late ACK matching the cancelled ticket is accepted (IL-8637): the dispatcher becomes usable,
    ///         the event fires and the cancelled record is consumed (a replay reverts).
    /// @dev Negative (re-injection): remove the `cancelledDeploymentTicket` match in the ACK branch -> the ACK
    ///      reverts `UnknownDeploymentAck` -> fails.
    function testShouldAcceptLateAckMatchingCancelledTicket() public {
        address executor = _createExecutor(bytes32("late-ack"));
        bytes32 hash1 = _requestAndCancel(executor, _vaultsA());
        CcipCrosschainExecutor exec = CcipCrosschainExecutor(payable(executor));
        assertEq(factory.cancelledDeploymentTicket(executor, REMOTE_CHAIN), hash1, "cancelled hash kept");

        bytes memory ack = _ackData(executor, hash1);
        vm.expectEmit(address(factory));
        emit CcipCrosschainFactory.DeploymentLateAcked(executor, REMOTE_CHAIN, hash1);
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, ack, "late-ack");
        assertTrue(exec.hasDispatcher(REMOTE_CHAIN), "dispatcher ready via the late ACK");
        assertTrue(exec.isDispatcherReady(REMOTE_CHAIN), "route initialized");
        assertEq(factory.cancelledDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "cancelled record consumed");
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 0, "attempts cleared by the ACK");

        // Single use: a replay finds neither a pending nor a cancelled ticket.
        vm.expectRevert(_unknown(executor, hash1));
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, ack, "late-ack-2");
    }

    /// @notice A late ACK with a hash that does not match the cancelled ticket stays rejected.
    function testShouldRejectLateAckWithNonMatchingHashAfterCancel() public {
        address executor = _createExecutor(bytes32("late-ack-bad"));
        bytes32 hash1 = _requestAndCancel(executor, _vaultsA());
        bytes32 other = bytes32(uint256(hash1) ^ 1);
        vm.expectRevert(_unknown(executor, other));
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, _ackData(executor, other), "late-ack-bad");
        assertFalse(CcipCrosschainExecutor(payable(executor)).hasDispatcher(REMOTE_CHAIN), "not ready");
        assertEq(factory.cancelledDeploymentTicket(executor, REMOTE_CHAIN), hash1, "cancelled record untouched");
    }

    /// @notice The IL-8486 path is unchanged: after a cancel and an identical re-request the ACK completes the
    ///         pending ticket through the normal branch (no late event).
    function testShouldCompleteIdenticalReRequestAfterCancelThroughNormalAck() public {
        address executor = _createExecutor(bytes32("rereq"));
        bytes32 hash1 = _requestAndCancel(executor, _vaultsA());
        bytes32 hash2 = _request(executor, _vaultsA());
        assertEq(hash2, hash1, "identical re-request has the identical ticket hash");

        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, _ackData(executor, hash1), "rereq-ack");
        CcipCrosschainExecutor exec = CcipCrosschainExecutor(payable(executor));
        assertTrue(exec.hasDispatcher(REMOTE_CHAIN), "dispatcher ready");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "pending ticket consumed");

        // The same ACK delivered again: the executor already has a dispatcher, so the `hasDispatcher` guard
        // rejects it even with the stale cancelled record present. The normal branch clears that record, so
        // it is restored by hand to pin the guard on its own.
        assertEq(factory.cancelledDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "record cleared by ACK");
        stdstore.target(address(factory)).sig("cancelledDeploymentTicket(address,uint256)").with_key(executor)
            .with_key(REMOTE_CHAIN).checked_write(hash1);
        stdstore.target(address(factory)).sig("isCancelledDeploymentTicket(address,uint256,bytes32)")
            .with_key(executor).with_key(REMOTE_CHAIN).with_key(hash1).checked_write(true);
        vm.expectRevert(_unknown(executor, hash1));
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, _ackData(executor, hash1), "rereq-ack-2");
    }

    /// @notice A late ACK is refused while a different newer ticket is pending (it would flip readiness under it).
    function testShouldRejectLateAckWhileDifferentTicketPending() public {
        address executor = _createExecutor(bytes32("late-newer"));
        bytes32 hash1 = _requestAndCancel(executor, _vaultsA());
        bytes32 hash2 = _request(executor, _vaultsB());
        assertTrue(hash2 != hash1, "different vault list, different hash");
        vm.expectRevert(_unknown(executor, hash1));
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, _ackData(executor, hash1), "late-newer");
        assertFalse(CcipCrosschainExecutor(payable(executor)).hasDispatcher(REMOTE_CHAIN), "not ready");
    }

    // ---------------------------------------------------------------------
    // IL-8637: exclusive grace for the owner / manager before third parties may cancel
    // ---------------------------------------------------------------------

    function testShouldKeepCancelExclusiveToOwnerAndManagerDuringGrace() public {
        address executor = _createExecutor(bytes32("grace"));
        uint256 t0 = block.timestamp;
        _request(executor, _vaultsA());
        uint256 ownerAt = t0 + factory.DEPLOYMENT_TTL() + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
        uint256 publicAt = ownerAt + CrosschainConstants.DEPLOYMENT_CANCEL_GRACE;
        address stranger = makeAddr("stranger");

        vm.warp(publicAt);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.DeploymentNotExpired.selector, executor, REMOTE_CHAIN, publicAt
            )
        );
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);

        vm.warp(ownerAt + 1);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.DeploymentNotExpired.selector, executor, REMOTE_CHAIN, publicAt
            )
        );
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);

        vm.prank(manager);
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN); // manager inside the grace
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "manager cancelled");

        // Owner (this test contract) inside the grace, on a fresh ticket.
        _request(executor, _vaultsA());
        vm.warp(block.timestamp + factory.DEPLOYMENT_TTL() + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1);
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "owner cancelled");

        // Third party after the grace.
        _request(executor, _vaultsA());
        vm.warp(block.timestamp + factory.DEPLOYMENT_TTL() + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN
            + CrosschainConstants.DEPLOYMENT_CANCEL_GRACE + 1);
        vm.prank(stranger);
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "third party cancelled");
    }

    /// @notice A late NACK for the cancelled ticket reverts; after an identical re-request the SAME NACK closes
    ///         it (the executor stays without a dispatcher, and a further request is possible).
    /// @dev For reason 1 the NACK is still true: another ticket occupies the destination address, so the fresh
    ///      one would be refused too. For reasons 2 and 3 nothing was deployed and the fresh ticket may well have
    ///      been; the outcome is benign only because the cancelled-ticket record still accepts its late ACK
    ///      (`DeploymentLateAcked`), but the `DeploymentNack` event is misleading (IL-8637 R3). A reason-4
    ///      (TICKET_EXPIRED) NACK is NOT replayable this way: it is refused until the fresh request's own TTL has
    ///      elapsed (`testShouldRefuseStaleExpiredNackWhileFreshReRequestIsPending`).
    ///      Negative: NACKs accepted without a pending ticket -> the first delivery does not revert -> fails.
    function testShouldRevertLateNackAfterCancelThenCloseIdenticalReRequest() public {
        address executor = _createExecutor(bytes32("late-nack"));
        bytes32 hash1 = _requestAndCancel(executor, _vaultsA());
        CcipCrosschainExecutor exec = CcipCrosschainExecutor(payable(executor));

        bytes memory nack = _nackData(executor, hash1);
        vm.expectRevert(_unknown(executor, hash1));
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_NACK, nack, "late-nack");

        bytes32 hash2 = _request(executor, _vaultsA());
        assertEq(hash2, hash1, "identical re-request has the identical ticket hash");

        vm.expectEmit(true, true, true, true, address(factory));
        emit CcipCrosschainFactory.DeploymentNack(executor, REMOTE_CHAIN, hash1, 1);
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_NACK, nack, "late-nack");

        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "re-request closed by NACK");
        assertFalse(exec.hasDispatcher(REMOTE_CHAIN), "a NACK never marks the dispatcher ready");
        // The manager can ask again straight away.
        _request(executor, _vaultsA());
    }

    /// @notice A stale ACK does not match a re-request with a different vault list (different hash): it keeps
    ///         reverting, leaves the new pending ticket untouched, and readiness never flips.
    /// @dev Negative: the ACK matched on executor + chain only (ticket hash ignored) -> the stale ACK would
    ///      complete the wrong ticket -> fails. A reordered list of the same vaults is a different hash too,
    ///      but is not separately pinned here.
    function testShouldNotMatchStaleAckAgainstReRequestWithDifferentVaults() public {
        address executor = _createExecutor(bytes32("stale-ack"));
        bytes32 hashA = _requestAndCancel(executor, _vaultsA());
        CcipCrosschainExecutor exec = CcipCrosschainExecutor(payable(executor));

        bytes32 hashB = _request(executor, _vaultsB());
        assertTrue(hashB != hashA, "different vaults -> different ticket hash");

        vm.expectRevert(_unknown(executor, hashA));
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, _ackData(executor, hashA), "stale-ack");

        assertFalse(exec.hasDispatcher(REMOTE_CHAIN), "stale ACK did not complete the re-request");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), hashB, "re-request still pending");
    }

    // ---------------------------------------------------------------------
    // Destination: what the factory answers for an orphaned dispatcher
    // ---------------------------------------------------------------------

    function _orphanTicket(
        bytes32 userSalt_,
        address[] memory vaults_
    ) private view returns (CcipCrosschainFactory.DeploymentTicket memory) {
        // A creator / salt pair no executor was created from on this EVM, so the predicted address is free.
        return
            CcipCrosschainFactory.DeploymentTicket({
                salt: keccak256(abi.encode(address(this), userSalt_, uint8(7))),
                executor: factory.computeExecutorAddress(address(this), userSalt_),
                srcChainId: LOCAL_CHAIN,
                dstChainId: REMOTE_CHAIN,
                assetId: ASSET_ID,
                sharedDecimals: 6,
                vaults: vaults_,
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                rescueDelay: 3 days
            });
    }

    function _decodeHeld(uint256 index_) private view returns (CcipMsgType messageType, bytes memory data) {
        (messageType, data) = CcipMessages.decode(router.heldData(index_));
    }

    /// @notice Once the destination deployed the dispatcher, it re-ACKs only a byte-identical ticket. A ticket
    ///         with a different vault list is answered NACK(1) (occupied) and never deploys or ACKs.
    /// @dev The dispatcher deployed for the first ticket is the orphan: its ACK was lost or arrived late. The
    ///      re-ACK answers the source's identical re-request (`ticket hash` in the ACK equals the source's).
    ///      Negative: `consumedTicket` keyed on anything but the full ticket hash -> the different-vault
    ///      ticket would be re-ACKed instead of NACKed -> fails.
    function testShouldReAckOnlyTheIdenticalTicketAndNackAnyOtherForAnOrphanedDispatcher() public {
        CcipCrosschainFactory.DeploymentTicket memory ticketA = _orphanTicket(bytes32("orphan"), new address[](0));
        bytes32 hashA = keccak256(abi.encode(ticketA));
        CcipCrosschainFactory.DeploymentTicket memory ticketB = _orphanTicket(bytes32("orphan"), _vaultsB());
        bytes32 hashB = keccak256(abi.encode(ticketB));
        assertTrue(hashA != hashB);

        vm.chainId(REMOTE_CHAIN);
        assertEq(ticketA.executor.code.length, 0, "predicted address free");

        // First delivery deploys the dispatcher and ACKs (this ACK is the one that is lost / late).
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticketA, _expiry()), "create-1");
        assertGt(ticketA.executor.code.length, 0, "orphan dispatcher deployed");
        assertTrue(factory.isDispatcher(ticketA.executor));
        assertTrue(factory.consumedTicket(hashA));
        uint256 ackIndex = router.heldCount() - 1;
        (CcipMsgType type1, bytes memory data1) = _decodeHeld(ackIndex);
        assertEq(uint8(type1), uint8(CcipMsgType.DEPLOYMENT_ACK), "first answer is an ACK");
        assertEq(data1, _ackDataFor(ticketA.executor, hashA), "ACK for ticket A");

        // Identical ticket re-delivered (the source's identical re-request): re-ACK, same hash, no new deploy.
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticketA, _expiry()), "create-2");
        (CcipMsgType type2, bytes memory data2) = _decodeHeld(router.heldCount() - 1);
        assertEq(uint8(type2), uint8(CcipMsgType.DEPLOYMENT_ACK), "identical ticket is re-ACKed");
        assertEq(data2, data1, "re-ACK is byte-identical to the original ACK");

        // Different vault list -> different hash -> occupied address -> NACK(1); nothing is consumed.
        uint256 heldBefore = router.heldCount();
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticketB, _expiry()), "create-3");
        assertEq(router.heldCount(), heldBefore + 1, "one answer sent");
        (CcipMsgType type3, bytes memory data3) = _decodeHeld(router.heldCount() - 1);
        assertEq(uint8(type3), uint8(CcipMsgType.DEPLOYMENT_NACK), "changed ticket is NACKed");
        assertEq(data3, abi.encode(ticketB.executor, REMOTE_CHAIN, hashB, uint8(1)), "NACK(1) for ticket B");
        assertFalse(factory.consumedTicket(hashB), "changed ticket never consumed");

        // The NACK is permanent for that hash: re-delivery answers NACK(1) again.
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticketB, _expiry()), "create-4");
        (CcipMsgType type4, ) = _decodeHeld(router.heldCount() - 1);
        assertEq(uint8(type4), uint8(CcipMsgType.DEPLOYMENT_NACK), "still NACK");
    }

    function _ackDataFor(address executor_, bytes32 ticketHash_) private view returns (bytes memory) {
        return abi.encode(executor_, block.chainid, ticketHash_);
    }

    // ---------------------------------------------------------------------
    // IL-8561 / IL-8636: deterministic destination rejections answer NACK, source rejects bad lists
    // ---------------------------------------------------------------------

    function _ticketWith(
        bytes32 userSalt_,
        bytes32 assetId_,
        uint8 sharedDecimals_,
        address[] memory vaults_
    ) private view returns (CcipCrosschainFactory.DeploymentTicket memory ticket) {
        ticket = _orphanTicket(userSalt_, vaults_);
        ticket.assetId = assetId_;
        ticket.sharedDecimals = sharedDecimals_;
    }

    /// @dev Delivers `ticket_` to the destination (one factory plays both sides) and returns the held answer.
    function _deliverToDestination(
        CcipCrosschainFactory.DeploymentTicket memory ticket_
    ) private returns (CcipMsgType answerType, bytes memory answer) {
        return _deliverToDestination(ticket_, "create");
    }

    function _deliverToDestination(
        CcipCrosschainFactory.DeploymentTicket memory ticket_,
        bytes32 messageId_
    ) private returns (CcipMsgType answerType, bytes memory answer) {
        uint256 heldBefore = router.heldCount();
        vm.chainId(REMOTE_CHAIN);
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket_, _expiry()), messageId_);
        vm.chainId(LOCAL_CHAIN);
        assertEq(router.heldCount(), heldBefore + 1, "exactly one answer sent");
        (answerType, answer) = _decodeHeld(router.heldCount() - 1);
    }

    function _assertNacked(
        CcipCrosschainFactory.DeploymentTicket memory ticket_,
        CcipMsgType answerType_,
        bytes memory answer_,
        uint8 reason_
    ) private view {
        bytes32 hash = keccak256(abi.encode(ticket_));
        assertEq(uint8(answerType_), uint8(CcipMsgType.DEPLOYMENT_NACK), "answer is a NACK");
        assertEq(answer_, abi.encode(ticket_.executor, REMOTE_CHAIN, hash, reason_), "NACK reason");
        assertFalse(factory.consumedTicket(hash), "ticket not consumed");
        assertFalse(factory.isDispatcher(ticket_.executor), "no dispatcher registered");
        assertEq(ticket_.executor.code.length, 0, "nothing deployed");
    }

    /// @dev Found empirically: the mock's early rejection needs ~500k to NACK; 100k-250k hits the custom revert.
    uint256 private constant LOW_GAS = 200_000;

    function testShouldNackWhenDestinationAssetNotEnabled() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticketWith(
            bytes32("no-asset"),
            keccak256("DAI"),
            6,
            new address[](0)
        );
        (CcipMsgType t, bytes memory a) = _deliverToDestination(ticket);
        _assertNacked(ticket, t, a, 2);
        assertFalse(factory.assetFrozen(keccak256("DAI")), "asset not frozen by a rejected ticket");
    }

    function testShouldNackWhenSharedDecimalsMismatch() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticketWith(
            bytes32("bad-dec"),
            ASSET_ID,
            18,
            new address[](0)
        );
        (CcipMsgType t, bytes memory a) = _deliverToDestination(ticket);
        _assertNacked(ticket, t, a, 2);
        assertFalse(factory.assetFrozen(ASSET_ID), "asset not frozen by a rejected ticket");
    }

    function testShouldNackWhenTicketVaultHasNoCode() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(0xDEAD);
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticketWith(bytes32("no-code"), ASSET_ID, 6, vaults);
        (CcipMsgType t, bytes memory a) = _deliverToDestination(ticket);
        _assertNacked(ticket, t, a, 3);
    }

    /// @notice TP-L-08: the vault was valid when the ticket was sent, its `asset()` changed before delivery.
    ///         The destination NACKs (reason 3), the source ticket is freed at once and a corrected request works.
    function testShouldNackWhenTicketVaultBecameInvalid() public {
        StubVault vault = new StubVault(address(token));
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);

        address executor = _createExecutor(bytes32("tp-l-08"));
        bytes32 hash = _request(executor, vaults);
        assertEq(keccak256(abi.encode(_ticket(executor, vaults))), hash);

        vault.setAsset(address(0xBAD));

        // One factory plays both sides: free the predicted address for the destination view, restore afterwards.
        bytes memory executorCode = executor.code;
        bytes memory ticketData = abi.encode(_ticket(executor, vaults), _expiry());
        _freePredictedAddress(executor);
        vm.chainId(REMOTE_CHAIN);
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, ticketData, "create");
        vm.chainId(LOCAL_CHAIN);
        assertEq(executor.code.length, 0, "dispatcher not deployed");
        vm.etch(executor, executorCode);
        assertFalse(factory.consumedTicket(hash), "ticket not consumed");
        assertFalse(factory.isDispatcher(executor), "no dispatcher registered");
        (CcipMsgType t, bytes memory a) = _decodeHeld(router.heldCount() - 1);
        assertEq(uint8(t), uint8(CcipMsgType.DEPLOYMENT_NACK));
        assertEq(a, abi.encode(executor, REMOTE_CHAIN, hash, uint8(3)), "NACK reason 3");

        // The NACK reaches the source: pending ticket cleared, event carries the reason.
        vm.expectEmit(address(factory));
        emit CcipCrosschainFactory.DeploymentNack(executor, REMOTE_CHAIN, hash, 3);
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_NACK, a, "nack");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "pending cleared");

        // A corrected list (a new ticket) can be requested at once.
        address[] memory corrected = new address[](0);
        bytes32 hash2 = _request(executor, corrected);
        assertTrue(hash2 != bytes32(0) && hash2 != hash, "new ticket pending");

        // The corrected ticket is delivered to the destination and ACKed: the dispatcher is deployed.
        bytes memory correctedData = abi.encode(_ticket(executor, corrected), _expiry());
        _freePredictedAddress(executor);
        vm.chainId(REMOTE_CHAIN);
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, correctedData, "create2");
        vm.chainId(LOCAL_CHAIN);
        (CcipMsgType t2, ) = _decodeHeld(router.heldCount() - 1);
        assertEq(uint8(t2), uint8(CcipMsgType.DEPLOYMENT_ACK), "corrected ticket ACKed");
        assertGt(executor.code.length, 0, "dispatcher deployed");
        assertTrue(factory.isDispatcher(executor), "dispatcher registered");
        assertTrue(factory.consumedTicket(hash2), "corrected ticket consumed");
    }

    /// @dev One factory plays both sides: empties the executor address and its CREATE3 proxy so the destination
    ///      side can deploy at the predicted address.
    function _freePredictedAddress(address executor_) private {
        vm.etch(executor_, "");
        vm.resetNonce(executor_);
        // The CREATE3 proxy is a CREATE2 child of the factory; free it as well.
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(factory),
                            factory.saltOf(executor_),
                            bytes32(0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f)
                        )
                    )
                )
            )
        );
        vm.etch(proxy, "");
        vm.resetNonce(proxy);
    }

    function _receiveWithGas(
        CcipCrosschainFactory.DeploymentTicket memory ticket_,
        uint256 gas_
    ) private returns (bool ok, bytes memory ret) {
        vm.prank(address(router));
        (ok, ret) = address(factory).call{gas: gas_}(
            abi.encodeCall(
                factory.ccipReceive,
                (
                    CcipClient.Any2EVMMessage({
                        messageId: bytes32("low-gas"),
                        sourceChainSelector: LOCAL_SELECTOR,
                        sender: abi.encode(address(factory)),
                        data: CcipMessages.encode(CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket_, _expiry())),
                        destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
                    })
                )
            )
        );
    }

    /// @notice A deterministic rejection delivered with too little gas must not be answered with a NACK: the
    ///         receive reverts (retryable) when the attempt burned most of its gas or leaves < NACK_MIN_GAS.
    function testShouldRevertInsufficientGasForNackInsteadOfFalseNack() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticketWith(
            bytes32("low-gas"),
            keccak256("DAI"),
            6,
            new address[](0)
        );
        bytes32 hash = keccak256(abi.encode(ticket));
        vm.chainId(REMOTE_CHAIN);
        uint256 held = router.heldCount();
        (bool ok, bytes memory ret) = _receiveWithGas(ticket, LOW_GAS);
        assertFalse(ok, "receive reverts");
        assertEq(bytes4(ret), CcipCrosschainFactory.InsufficientGasForNack.selector, "custom error");
        assertEq(router.heldCount(), held, "no NACK sent");
        assertFalse(factory.consumedTicket(hash), "nothing consumed");

        // Same ticket with ample gas is a legitimate NACK.
        (ok, ) = _receiveWithGas(ticket, 10_000_000);
        assertTrue(ok, "ample gas NACKs");
        assertEq(router.heldCount(), held + 1, "NACK sent");
        vm.chainId(LOCAL_CHAIN);
    }

    /// @notice Re-delivering a NACK-able ticket gives the same NACK and leaves no state behind.
    function testShouldReNackSameTicketRedelivered() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticketWith(
            bytes32("re-nack"),
            keccak256("DAI"),
            6,
            new address[](0)
        );
        (CcipMsgType t1, bytes memory a1) = _deliverToDestination(ticket);
        _assertNacked(ticket, t1, a1, 2);
        (CcipMsgType t2, bytes memory a2) = _deliverToDestination(ticket, "create-2");
        _assertNacked(ticket, t2, a2, 2);
        assertEq(a1, a2, "same NACK both times");
    }

    function testShouldStillNackOccupiedAddress() public {
        address executor = _createExecutor(bytes32("occupied"));
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticket(executor, _vaultsA());
        (CcipMsgType t, bytes memory a) = _deliverToDestination(ticket);
        assertEq(uint8(t), uint8(CcipMsgType.DEPLOYMENT_NACK));
        assertEq(a, abi.encode(executor, REMOTE_CHAIN, keccak256(abi.encode(ticket)), uint8(1)), "reason 1");
    }

    function testShouldRejectOversizedVaultListAtRequest() public {
        address executor = _createExecutor(bytes32("big"));
        address[] memory vaults = new address[](33);
        for (uint256 i; i < 33; ++i) vaults[i] = address(uint160(0x1000 + i));
        uint256 balance = address(factory).balance;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.TooManyVaults.selector, 33, 32));
        factory.requestDispatcher(executor, REMOTE_CHAIN, vaults, MAX_FEE);
        assertEq(router.heldCount(), 0, "router not called");
        assertEq(address(factory).balance, balance, "no fee paid");
    }

    function testShouldRejectZeroVaultAtRequest() public {
        address executor = _createExecutor(bytes32("zero"));
        address[] memory vaults = new address[](2);
        vaults[0] = address(0xA001);
        uint256 balance = address(factory).balance;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.InvalidVaultAddress.selector, address(0)));
        factory.requestDispatcher(executor, REMOTE_CHAIN, vaults, MAX_FEE);
        assertEq(router.heldCount(), 0, "router not called");
        assertEq(address(factory).balance, balance, "no fee paid");
    }

    function testShouldRejectDuplicateVaultAtRequest() public {
        address executor = _createExecutor(bytes32("dup"));
        address[] memory vaults = new address[](2);
        vaults[0] = address(0xA001);
        vaults[1] = address(0xA001);
        uint256 balance = address(factory).balance;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.DuplicateVault.selector, address(0xA001)));
        factory.requestDispatcher(executor, REMOTE_CHAIN, vaults, MAX_FEE);
        assertEq(router.heldCount(), 0, "router not called");
        assertEq(address(factory).balance, balance, "no fee paid");
    }

    /// @notice A transient failure of the answer send (budget below the fee) still reverts the whole receive:
    ///         nothing is consumed or registered, and a funded re-execution succeeds with an ACK.
    function testShouldKeepRevertingOnTransientAckSendFailure() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticketWith(
            bytes32("transient"),
            ASSET_ID,
            6,
            new address[](0)
        );
        bytes32 hash = keccak256(abi.encode(ticket));
        vm.deal(address(factory), 0);
        vm.chainId(REMOTE_CHAIN);
        vm.expectPartialRevert(CcipSendLib.CcipInsufficientNativeFeeBalance.selector);
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket, _expiry()), "create");
        assertFalse(factory.consumedTicket(hash), "nothing consumed");
        assertFalse(factory.isDispatcher(ticket.executor), "nothing registered");
        assertEq(ticket.executor.code.length, 0, "nothing deployed");

        vm.deal(address(factory), 20 * FEE);
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket, _expiry()), "create");
        (CcipMsgType t, ) = _decodeHeld(router.heldCount() - 1);
        assertEq(uint8(t), uint8(CcipMsgType.DEPLOYMENT_ACK), "funded retry ACKs");
        vm.chainId(LOCAL_CHAIN);
    }

    function testShouldRevertCancelExpiredDeploymentWithoutPendingTicket() public {
        address executor = _createExecutor(bytes32("none"));
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.NoPendingDeployment.selector, executor, REMOTE_CHAIN)
        );
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);
    }

    function testShouldRevertTicketSourceChainMismatch() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticketWith(
            bytes32("srcmismatch"),
            ASSET_ID,
            6,
            new address[](0)
        );
        ticket.srcChainId = LOCAL_CHAIN + 1;
        vm.chainId(REMOTE_CHAIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.TicketSourceChainMismatch.selector, LOCAL_CHAIN + 1, LOCAL_CHAIN
            )
        );
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket, _expiry()), "srcmismatch");
    }

    function testShouldRevertMessageWithTokenTransfer() public {
        CcipClient.EVMTokenAmount[] memory amounts = new CcipClient.EVMTokenAmount[](1);
        amounts[0] = CcipClient.EVMTokenAmount({token: address(token), amount: 1});
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.UnexpectedTokenTransfer.selector, 1));
        factory.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: "tokens",
                sourceChainSelector: REMOTE_SELECTOR,
                sender: abi.encode(address(factory)),
                data: CcipMessages.encode(CcipMsgType.DEPLOYMENT_ACK, ""),
                destTokenAmounts: amounts
            })
        );
    }

    // ---------------------------------------------------------------------
    // IL-8623: absolute expiry of a CREATE_DISPATCHER ticket
    // ---------------------------------------------------------------------

    function _deliverWithExpiry(CcipCrosschainFactory.DeploymentTicket memory ticket_, uint256 expiresAt_)
        private
        returns (CcipMsgType answerType, bytes memory answer)
    {
        uint256 heldBefore = router.heldCount();
        vm.chainId(REMOTE_CHAIN);
        bytes memory data = abi.encode(ticket_, expiresAt_);
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, data, keccak256(abi.encode(data, block.timestamp)));
        vm.chainId(LOCAL_CHAIN);
        assertEq(router.heldCount(), heldBefore + 1, "exactly one answer sent");
        (answerType, answer) = _decodeHeld(router.heldCount() - 1);
    }

    /// @notice A ticket delivered at its `expiresAt` is answered NACK(4); nothing is deployed or frozen. This is the
    ///         late manual execution of a ticket the source already dropped.
    function testShouldNackExpiredTicketAndDeployNothing() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("expired"), new address[](0));
        uint256 expiresAt = block.timestamp + factory.DEPLOYMENT_TTL();
        vm.warp(expiresAt);

        (CcipMsgType t, bytes memory a) = _deliverWithExpiry(ticket, expiresAt);
        _assertNacked(ticket, t, a, 4);
        assertFalse(factory.assetFrozen(ASSET_ID), "asset not frozen by an expired ticket");
    }

    function testShouldDeployTicketOneSecondBeforeExpiry() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("fresh"), new address[](0));
        uint256 expiresAt = block.timestamp + factory.DEPLOYMENT_TTL();
        vm.warp(expiresAt - 1);

        (CcipMsgType t,) = _deliverWithExpiry(ticket, expiresAt);
        assertEq(uint8(t), uint8(CcipMsgType.DEPLOYMENT_ACK), "ACK");
        assertGt(ticket.executor.code.length, 0, "deployed");
        assertTrue(factory.assetFrozen(ASSET_ID), "frozen by the deployment");
    }

    /// @notice The source drops a ticket only after TTL + margin, so a destination lagging up to the margin has
    ///         already stopped accepting it.
    function testShouldGateCancelOnTtlPlusMargin() public {
        address executor = _createExecutor(bytes32("il-8623"));
        uint256 t0 = block.timestamp;
        _request(executor, new address[](0));
        uint256 cancellableAt = t0 + factory.DEPLOYMENT_TTL() + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;

        vm.warp(t0 + factory.DEPLOYMENT_TTL() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.DeploymentNotExpired.selector, executor, REMOTE_CHAIN, cancellableAt
            )
        );
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);

        // Exactly at `cancellableAt` is still refused: the gate is strictly after.
        vm.warp(cancellableAt);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.DeploymentNotExpired.selector, executor, REMOTE_CHAIN, cancellableAt
            )
        );
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);

        vm.warp(cancellableAt + 1);
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "dropped");
    }

    /// @notice An already consumed ticket delivered again after its `expiresAt` is re-ACKed, not NACKed: the expiry
    ///         check sits inside the `!consumed` branch.
    /// @dev Negative: moving the expiry check before the consumed check turns the re-ACK into NACK(4) -> fails.
    function testShouldReAckConsumedTicketRedeliveredAfterExpiry() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("reack"), new address[](0));
        uint256 expiresAt = block.timestamp + factory.DEPLOYMENT_TTL();
        (CcipMsgType t1,) = _deliverWithExpiry(ticket, expiresAt);
        assertEq(uint8(t1), uint8(CcipMsgType.DEPLOYMENT_ACK), "first delivery ACK");

        vm.warp(expiresAt + 1 days);
        (CcipMsgType t2,) = _deliverWithExpiry(ticket, expiresAt);
        assertEq(uint8(t2), uint8(CcipMsgType.DEPLOYMENT_ACK), "re-delivery after expiry is re-ACKed");
    }

    // ---------------------------------------------------------------------
    // IL-8623 hardening H1: destination sanity bound on `expiresAt`
    // ---------------------------------------------------------------------

    function _maxExpiresAt() private view returns (uint256) {
        return
            block.timestamp + CrosschainConstants.MAX_DEPLOYMENT_TTL + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN;
    }

    /// @notice An `expiresAt` above `now + MAX_DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN` reverts (retryable, no
    ///         NACK, nothing written); exactly at the bound the ticket deploys.
    /// @dev Negative: dropping the bound makes the absurd value deploy -> the revert expectation fails.
    function testShouldRevertTicketWithExpiryBeyondSanityBoundAndDeployAtTheBound() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("bound"), new address[](0));
        uint256 maxExpiresAt = _maxExpiresAt();
        uint256 heldBefore = router.heldCount();

        vm.chainId(REMOTE_CHAIN);
        bytes memory data = abi.encode(ticket, maxExpiresAt + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.TicketExpiryOutOfRange.selector,
                maxExpiresAt + 1,
                maxExpiresAt
            )
        );
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, data, "absurd");
        vm.chainId(LOCAL_CHAIN);
        assertEq(router.heldCount(), heldBefore, "no answer sent");
        assertEq(ticket.executor.code.length, 0, "nothing deployed");

        (CcipMsgType t,) = _deliverWithExpiry(ticket, maxExpiresAt);
        assertEq(uint8(t), uint8(CcipMsgType.DEPLOYMENT_ACK), "ACK at the bound");
        assertGt(ticket.executor.code.length, 0, "deployed");
    }

    /// @notice A payload of the OLD wire format (the ticket alone) decodes silently here with `expiresAt` reading the
    ///         ticket's first word (the salt, a hash); the bound rejects it instead of deploying.
    function testShouldRejectOldFormatPayloadWhoseExpiryReadsTheSaltWord() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("oldfmt"), new address[](0));
        uint256 maxExpiresAt = _maxExpiresAt();

        vm.chainId(REMOTE_CHAIN);
        bytes memory data = abi.encode(ticket);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.TicketExpiryOutOfRange.selector,
                uint256(ticket.salt),
                maxExpiresAt
            )
        );
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, data, "old-format");
        vm.chainId(LOCAL_CHAIN);
        assertEq(ticket.executor.code.length, 0, "nothing deployed");
    }

    // ---------------------------------------------------------------------
    // IL-8623 hardening H2: a stale NACK(TICKET_EXPIRED) must not close an identical fresh re-request
    // ---------------------------------------------------------------------

    /// @notice An identical re-request is pending; the NACK(4) answering the PREVIOUS request is replayed. It reverts
    ///         (retryable) and the pending request stays; once the fresh TTL has elapsed it is consumed.
    /// @dev Negative: without the guard the first delivery closes the fresh request -> the revert expectation fails.
    function testShouldRefuseStaleExpiredNackWhileFreshReRequestIsPending() public {
        address executor = _createExecutor(bytes32("stale-4"));
        bytes32 hash1 = _requestAndCancel(executor, _vaultsA());
        bytes32 hash2 = _request(executor, _vaultsA());
        assertEq(hash2, hash1, "identical re-request has the identical ticket hash");
        uint256 notBefore = block.timestamp + factory.DEPLOYMENT_TTL();

        bytes memory nack4 = abi.encode(executor, REMOTE_CHAIN, hash1, uint8(4));
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.PrematureExpiredNack.selector,
                executor,
                REMOTE_CHAIN,
                notBefore
            )
        );
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_NACK, nack4, "stale-4");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), hash1, "fresh request stays pending");

        vm.warp(notBefore - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.PrematureExpiredNack.selector,
                executor,
                REMOTE_CHAIN,
                notBefore
            )
        );
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_NACK, nack4, "stale-4");

        vm.warp(notBefore);
        vm.expectEmit(true, true, true, true, address(factory));
        emit CcipCrosschainFactory.DeploymentNack(executor, REMOTE_CHAIN, hash1, 4);
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_NACK, nack4, "stale-4");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "consumed after the TTL");
    }

    // ---------------------------------------------------------------------
    // IL-8623 hardening H3: CCIP migration gate
    // ---------------------------------------------------------------------

    function _scheduleMigration() private returns (address newToken, bytes32 commitment) {
        newToken = address(new MockERC20("USD Coin 2", "USDC2", 6));
        factory.scheduleAsset(ASSET_ID, newToken, 6);
        commitment = keccak256(abi.encode("ASSET", ASSET_ID, newToken, uint8(6)));
    }

    function _deliverRaw(CcipCrosschainFactory.DeploymentTicket memory ticket_) private {
        vm.chainId(REMOTE_CHAIN);
        bytes memory data = abi.encode(ticket_, block.timestamp + factory.DEPLOYMENT_TTL());
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, data, keccak256(abi.encode(data, block.timestamp)));
        vm.chainId(LOCAL_CHAIN);
    }

    /// @notice A fresh ticket for an asset with a scheduled migration reverts (retryable) and deploys nothing;
    ///         after `executeAsset` it deploys, bound to the NEW token.
    /// @dev Negative: without the gate the first delivery deploys and freezes the asset, so `executeAsset` reverts
    ///      `AssetConfigFrozen` forever -> both the revert expectation and the later `executeAsset` fail.
    function testShouldHoldFreshTicketWhileMigrationScheduledAndDeployAfterExecuteAsset() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("mig-exec"), new address[](0));
        (address newToken, ) = _scheduleMigration();
        assertEq(factory.scheduledAssetCount(ASSET_ID), 1, "one scheduled migration");

        vm.chainId(REMOTE_CHAIN);
        bytes memory data = abi.encode(ticket, block.timestamp + factory.DEPLOYMENT_TTL());
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DestinationAssetMigrationScheduled.selector, ASSET_ID));
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, data, "mig");
        vm.chainId(LOCAL_CHAIN);
        assertEq(ticket.executor.code.length, 0, "nothing deployed while scheduled");
        assertFalse(factory.assetFrozen(ASSET_ID), "asset not frozen");

        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeAsset(ASSET_ID, newToken, 6);
        assertEq(factory.scheduledAssetCount(ASSET_ID), 0, "released on execute");

        _deliverRaw(ticket);
        assertGt(ticket.executor.code.length, 0, "deploys after the migration executed");
        assertTrue(factory.assetFrozen(ASSET_ID), "frozen by the deployment");
    }

    /// @notice Cancelling the scheduled migration releases the gate; scheduling the same commitment twice counts once.
    function testShouldReleaseMigrationGateOnCancelAndCountRescheduleOnce() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("mig-cancel"), new address[](0));
        (address newToken, bytes32 commitment) = _scheduleMigration();
        factory.scheduleAsset(ASSET_ID, newToken, 6);
        assertEq(factory.scheduledAssetCount(ASSET_ID), 1, "identical re-schedule counts once");

        factory.cancelScheduledConfig(commitment);
        assertEq(factory.scheduledAssetCount(ASSET_ID), 0, "released on cancel");

        _deliverRaw(ticket);
        assertGt(ticket.executor.code.length, 0, "deploys after the cancel");
    }

    /// @notice Two different commitments for one asset count twice; the gate holds until the last is cancelled.
    function testShouldHoldGateUntilEveryScheduledCommitmentForTheAssetIsCancelled() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("mig-two"), new address[](0));
        (, bytes32 first) = _scheduleMigration();
        address secondToken = address(new MockERC20("USD Coin 3", "USDC3", 6));
        factory.scheduleAsset(ASSET_ID, secondToken, 6);
        bytes32 second = keccak256(abi.encode("ASSET", ASSET_ID, secondToken, uint8(6)));
        assertEq(factory.scheduledAssetCount(ASSET_ID), 2, "two distinct commitments");

        factory.cancelScheduledConfig(first);
        assertEq(factory.scheduledAssetCount(ASSET_ID), 1, "one left");
        vm.chainId(REMOTE_CHAIN);
        bytes memory data = abi.encode(ticket, block.timestamp + factory.DEPLOYMENT_TTL());
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DestinationAssetMigrationScheduled.selector, ASSET_ID));
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, data, "mig-two");
        vm.chainId(LOCAL_CHAIN);

        factory.cancelScheduledConfig(second);
        assertEq(factory.scheduledAssetCount(ASSET_ID), 0, "none left");
        _deliverRaw(ticket);
        assertGt(ticket.executor.code.length, 0, "deploys once every commitment is cancelled");
    }

    /// @notice A frozen asset cannot be migrated, so a stale commitment on it must not hold a fresh ticket.
    function testShouldSkipMigrationGateOnceTheAssetIsFrozen() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _orphanTicket(bytes32("mig-frozen"), new address[](0));
        _scheduleMigration();
        _createExecutor(bytes32("freezer")); // freezes ASSET_ID
        assertTrue(factory.assetFrozen(ASSET_ID), "frozen by createExecutor");
        assertEq(factory.scheduledAssetCount(ASSET_ID), 1, "stale commitment remains");

        _deliverRaw(ticket);
        assertGt(ticket.executor.code.length, 0, "deploys despite the stale commitment");
    }

    /// @notice A zero asset id cannot be scheduled (it would leak `scheduledAssetCount`).
    function testShouldRevertScheduleAssetWithZeroAssetId() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.AssetConfigNotEnabled.selector, bytes32(0)));
        factory.scheduleAsset(bytes32(0), address(token), 6);
    }

    function testShouldRejectDirectCallToDeployDispatcherForTicket() public {
        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticketWith(
            bytes32("direct"),
            ASSET_ID,
            6,
            new address[](0)
        );
        vm.expectRevert(CcipCrosschainFactory.OnlySelf.selector);
        factory.deployDispatcherForTicket(ticket, LOCAL_CHAIN);
    }
}

contract StubVault {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }
}
