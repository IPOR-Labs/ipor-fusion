// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipAppBase} from "../../contracts/crosschain/ccip/base/CcipAppBase.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

/// @title CcipFactoryBudgetPolicyTest
/// @notice IL-8104: pins the bounds the CCIP factory's shared fee budget rests on, driving the real
///         `CcipCrosschainFactory` through `requestDispatcher` with hand-delivered ACK / NACK /
///         CREATE_DISPATCHER legs (`MockCcipRouter.setAutoDeliver(false)`, because the fixture never
///         registers a selector for the factory, so an auto-delivered message reverts
///         `CcipAppBase.ccipReceive`'s `CcipUnknownSelector` check before any ticket field is read).
///         Every test is green on the unmodified tree — they are regression pins of the documented
///         policy, each with a named negative case in its own NatSpec.
contract CcipFactoryBudgetPolicyTest is Test {
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
    address internal stranger;
    address internal creator;

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
        // The route back to LOCAL_CHAIN is registered from the destination's view (the same factory instance
        // plays both sides via `vm.chainId`): a route to the factory's own chain id is refused (IL-8451).
        vm.chainId(REMOTE_CHAIN);
        _setFactoryRoute(LOCAL_CHAIN, LOCAL_SELECTOR);
        vm.chainId(LOCAL_CHAIN);

        router.setAutoDeliver(false);
        router.setFee(FEE);
        vm.deal(address(factory), 3 * FEE);

        manager = makeAddr("manager");
        stranger = makeAddr("stranger");
        creator = makeAddr("creator");
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

    function _createExecutor(address creator_, bytes32 userSalt_, address manager_) private returns (address) {
        vm.prank(creator_);
        return factory.createExecutor(userSalt_, ASSET_ID, manager_, _safety());
    }

    function _vaults() private pure returns (address[] memory vaults) {
        vaults = new address[](0);
    }

    function _request(address executor_, address[] memory vaults_) private returns (bytes32 messageId) {
        vm.prank(manager);
        messageId = factory.requestDispatcher(executor_, REMOTE_CHAIN, vaults_, MAX_FEE);
    }

    /// @dev Rebuilds the `DeploymentTicket` from the executor's own getters, matching the ticket built
    ///      inside `requestDispatcher` field for field. Every test that calls this proves the rebuild
    ///      against the stored `pendingDeploymentTicket` hash before relying on it.
    function _ticket(
        address executor_,
        address[] memory vaults_
    ) private view returns (CcipCrosschainFactory.DeploymentTicket memory ticket) {
        CcipCrosschainExecutor exec = CcipCrosschainExecutor(payable(executor_));
        ticket = CcipCrosschainFactory.DeploymentTicket({
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

    // ---------------------------------------------------------------------
    // T1
    // ---------------------------------------------------------------------

    /// @notice Pins the default policy: creation is restricted and only the owner is allowlisted.
    /// @dev Negative: default flipped to `false`, or the flag no longer gating `createExecutor` -> the
    ///      first half fails; the setter no longer clearing the gate -> the second half fails.
    function testShouldDefaultToRestrictedCreationWithOwnerAsTheOnlyAllowlistedCreator() public {
        assertTrue(factory.creationRestricted());
        assertTrue(factory.isAllowedCreator(address(this)));
        assertFalse(factory.isAllowedCreator(stranger));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.CreatorNotAllowed.selector, stranger));
        factory.createExecutor(bytes32("blocked"), ASSET_ID, manager, _safety());

        factory.setCreationRestricted(false);
        vm.prank(stranger);
        address deployed = factory.createExecutor(bytes32("allowed"), ASSET_ID, manager, _safety());
        assertTrue(factory.isExecutor(deployed));
    }

    // ---------------------------------------------------------------------
    // T2
    // ---------------------------------------------------------------------

    /// @notice Pins that the two creation-policy setters and `sweepNative` are `onlyOwner`, rejecting
    ///         both a stranger and an allowlisted creator.
    /// @dev Negative: `onlyOwner` dropped from any of the three -> that call succeeds -> fails.
    function testShouldRejectCreationPolicyChangesFromNonOwnerAndFromAllowlistedCreator() public {
        factory.setCreatorAllowed(creator, true);
        uint256 balanceBefore = address(factory).balance;

        address[2] memory callers = [stranger, creator];
        for (uint256 i; i < callers.length; ++i) {
            address caller = callers[i];

            vm.prank(caller);
            vm.expectRevert(CcipCrosschainFactory.OnlyOwner.selector);
            factory.setCreationRestricted(false);

            vm.prank(caller);
            vm.expectRevert(CcipCrosschainFactory.OnlyOwner.selector);
            factory.setCreatorAllowed(caller, true);

            vm.prank(caller);
            vm.expectRevert(CcipCrosschainFactory.OnlyOwner.selector);
            factory.sweepNative(payable(caller), 1);
        }

        assertTrue(factory.creationRestricted());
        assertFalse(factory.isAllowedCreator(stranger));
        assertFalse(factory.isAllowedCreator(manager));
        assertEq(address(factory).balance, balanceBefore);
    }

    // ---------------------------------------------------------------------
    // T3
    // ---------------------------------------------------------------------

    /// @notice Pins that `requestDispatcher` is callable only by the executor's `MANAGER`, and only for
    ///         a registered executor.
    /// @dev Negative: the MANAGER gate removed -> the first call sends -> fails.
    function testShouldRejectDispatcherRequestFromNonManagerAndForUnregisteredExecutor() public {
        address executor = _createExecutor(address(this), bytes32("t3"), manager);
        uint256 balanceBefore = address(factory).balance;

        vm.prank(stranger);
        vm.expectRevert(CcipCrosschainFactory.InvalidExecutor.selector);
        factory.requestDispatcher(executor, REMOTE_CHAIN, _vaults(), MAX_FEE);

        vm.prank(manager);
        vm.expectRevert(CcipCrosschainFactory.InvalidExecutor.selector);
        factory.requestDispatcher(stranger, REMOTE_CHAIN, _vaults(), MAX_FEE);

        assertEq(address(factory).balance, balanceBefore);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));
    }

    // ---------------------------------------------------------------------
    // T4
    // ---------------------------------------------------------------------

    /// @notice Pins that one request pays exactly one quoted fee from the factory's own balance and
    ///         holds at most one open ticket per `(executor, chain)`.
    /// @dev Negative: the pending-ticket guard removed -> a second call pays a second fee -> fails.
    function testShouldPayExactlyOneQuotedFeeFromTheFactoryBudgetAndHoldOneTicketPerChain() public {
        address executor = _createExecutor(address(this), bytes32("t4"), manager);
        uint256 balanceBefore = address(factory).balance;

        vm.recordLogs();
        bytes32 messageId = _request(executor, _vaults());

        assertEq(address(factory).balance, balanceBefore - FEE);
        assertTrue(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN) != bytes32(0));
        assertEq(factory.pendingDeploymentCreatedAt(executor, REMOTE_CHAIN), uint64(block.timestamp));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("DispatcherRequested(address,uint256,bytes32)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != topic) continue;
            (address loggedExecutor, uint256 loggedChain, bytes32 loggedMessageId) = abi.decode(
                logs[i].data,
                (address, uint256, bytes32)
            );
            assertEq(loggedExecutor, executor);
            assertEq(loggedChain, REMOTE_CHAIN);
            assertEq(loggedMessageId, messageId);
            found = true;
        }
        assertTrue(found);

        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.DeploymentAlreadyPending.selector, executor, REMOTE_CHAIN)
        );
        _request(executor, _vaults());
        assertEq(address(factory).balance, balanceBefore - FEE);
    }

    // ---------------------------------------------------------------------
    // T5
    // ---------------------------------------------------------------------

    /// @notice Pins the two fee ceilings on `requestDispatcher`: the caller's `maxFee_` cannot exceed
    ///         the route ceiling, and the router's quote cannot exceed `maxFee_`.
    /// @dev Negative: either check in `CcipSendLib.send` removed -> the send goes through -> fails.
    function testShouldRefuseDispatcherRequestAboveRouteCeilingOrAboveCallerCeiling() public {
        address executor = _createExecutor(address(this), bytes32("t5"), manager);
        uint256 balanceBefore = address(factory).balance;

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipFeeCeilingTooHigh.selector, MAX_FEE + 1, MAX_FEE));
        factory.requestDispatcher(executor, REMOTE_CHAIN, _vaults(), MAX_FEE + 1);

        assertEq(address(factory).balance, balanceBefore);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));

        router.setFee(MAX_FEE + 1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipFeeTooHigh.selector, MAX_FEE + 1, MAX_FEE));
        factory.requestDispatcher(executor, REMOTE_CHAIN, _vaults(), MAX_FEE);

        assertEq(address(factory).balance, balanceBefore);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));
    }

    // ---------------------------------------------------------------------
    // T6
    // ---------------------------------------------------------------------

    /// @notice Pins that a request below the factory's native balance reverts, and that the factory
    ///         recovers via its permissionless `receive()` top-up.
    /// @dev Negative: `receive()` removed from `CcipAppBase` -> the top-up call fails -> fails.
    function testShouldRefuseDispatcherRequestBelowBudgetAndRecoverAfterPermissionlessTopUp() public {
        address executor = _createExecutor(address(this), bytes32("t6"), manager);
        vm.deal(address(factory), FEE - 1);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipInsufficientNativeFeeBalance.selector, FEE - 1, FEE));
        factory.requestDispatcher(executor, REMOTE_CHAIN, _vaults(), MAX_FEE);

        vm.deal(stranger, FEE);
        vm.prank(stranger);
        (bool ok, ) = address(factory).call{value: FEE}("");
        assertTrue(ok);

        _request(executor, _vaults());
        assertEq(address(factory).balance, FEE - 1);
    }

    // ---------------------------------------------------------------------
    // T7
    // ---------------------------------------------------------------------

    /// @notice Pins that once an executor's dispatcher for a chain is acknowledged, the factory refuses
    ///         a new request for that `(executor, chain)` for the executor's lifetime.
    /// @dev Negative: the `hasDispatcher` close removed -> a second ticket is paid -> fails.
    function testShouldCloseDispatcherRequestsForAChainOnceTheDispatcherIsAcknowledged() public {
        address executor = _createExecutor(address(this), bytes32("t7"), manager);
        _request(executor, _vaults());

        bytes32 ticketHash = factory.pendingDeploymentTicket(executor, REMOTE_CHAIN);
        assertTrue(ticketHash != bytes32(0));

        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, abi.encode(executor, REMOTE_CHAIN, ticketHash), "ack-1");

        assertTrue(CcipCrosschainExecutor(payable(executor)).hasDispatcher(REMOTE_CHAIN));
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));

        uint256 balanceBefore = address(factory).balance;
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.DispatcherAlreadyDeployed.selector, executor, REMOTE_CHAIN)
        );
        _request(executor, _vaults());
        assertEq(address(factory).balance, balanceBefore);
    }

    // ---------------------------------------------------------------------
    // T8
    // ---------------------------------------------------------------------

    /// @notice Pins the occupancy NACK loop (assessment IL-8104 s1.4 L2): a request that finds its
    ///         predicted CREATE3 address already occupied on the destination is NACKed at the
    ///         destination's expense, clears at once on the source, and can be re-requested in the same
    ///         transaction -- one factory instance plays both sides via `vm.chainId`.
    /// @dev Negative: a cooldown or counter added after a NACK -> step 4 reverts -> fails. Also fails if
    ///      the NACK branch stops clearing the pending ticket.
    function testShouldReRequestImmediatelyAfterNackWithBothFactoriesPayingOneFeePerIteration() public {
        address executor = _createExecutor(address(this), bytes32("t8"), manager);

        // Step 1: source request.
        uint256 balanceAfterStep1 = address(factory).balance - FEE;
        _request(executor, _vaults());
        assertEq(address(factory).balance, balanceAfterStep1);

        CcipCrosschainFactory.DeploymentTicket memory ticket = _ticket(executor, _vaults());
        bytes32 ticketHash = keccak256(abi.encode(ticket));
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), ticketHash);

        // Step 2: deliver CREATE_DISPATCHER on the destination view of the same factory. The source
        // executor already occupies the predicted CREATE3 address (CREATE3 depends only on deployer and
        // salt, not on chain id), which is the occupancy `_deployDispatcher` keys on.
        vm.chainId(REMOTE_CHAIN);
        uint256 balanceAfterStep2 = address(factory).balance - FEE;
        _deliver(LOCAL_SELECTOR, CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket, _expiry()), "create-dispatcher-1");
        assertEq(address(factory).balance, balanceAfterStep2);
        assertFalse(factory.consumedTicket(ticketHash));
        assertFalse(factory.isDispatcher(executor));

        // Step 3: restore the source chain view and deliver the NACK.
        vm.chainId(LOCAL_CHAIN);
        vm.expectEmit(true, true, true, true, address(factory));
        emit CcipCrosschainFactory.DeploymentNack(executor, REMOTE_CHAIN, ticketHash, 1);
        _deliver(
            REMOTE_SELECTOR,
            CcipMsgType.DEPLOYMENT_NACK,
            abi.encode(executor, REMOTE_CHAIN, ticketHash, uint8(1)),
            "nack-1"
        );
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));

        // Step 4: re-request in the same block, no warp.
        uint256 balanceAfterStep4 = address(factory).balance - FEE;
        _request(executor, _vaults());
        assertEq(address(factory).balance, balanceAfterStep4);
        assertEq(address(factory).balance, 0);
    }

    // ---------------------------------------------------------------------
    // T9
    // ---------------------------------------------------------------------

    /// @notice Pins the permissionless cancel gate: strictly after `DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN`,
    ///         not at or before it.
    /// @dev Negative: TTL shortened, `<=` weakened to `<`, or a caller gate added -> one of its
    ///      assertions fails.
    function testShouldGateExpiredDeploymentCancelStrictlyAfterTtlPlusMargin() public {
        assertEq(factory.DEPLOYMENT_TTL(), 7 days);
        address executor = _createExecutor(address(this), bytes32("t9"), manager);
        uint256 t0 = block.timestamp;
        _request(executor, _vaults());
        // A third party waits out the exclusive owner / manager grace too (IL-8637).
        uint256 cancellableAt = t0 + factory.DEPLOYMENT_TTL() + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN
            + CrosschainConstants.DEPLOYMENT_CANCEL_GRACE;

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.DeploymentNotExpired.selector,
                executor,
                REMOTE_CHAIN,
                cancellableAt
            )
        );
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);

        vm.warp(cancellableAt);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.DeploymentNotExpired.selector,
                executor,
                REMOTE_CHAIN,
                cancellableAt
            )
        );
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);

        vm.warp(cancellableAt + 1);
        vm.prank(stranger);
        factory.cancelExpiredDeployment(executor, REMOTE_CHAIN);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));

        uint256 balanceBefore = address(factory).balance;
        _request(executor, _vaults());
        assertEq(address(factory).balance, balanceBefore - FEE);
    }

    // ---------------------------------------------------------------------
    // T10
    // ---------------------------------------------------------------------

    /// @notice Pins the finding's own scenario as a green regression: an allowlisted creator can spend
    ///         the shared budget once per executor per destination chain, bounded only by gas and by the
    ///         factory's balance.
    /// @dev Negative: a per-creator bound added -> the third request reverts -> fails.
    function testShouldLetAnAllowlistedCreatorSpendTheSharedBudgetOncePerExecutorPerChain() public {
        factory.setCreatorAllowed(creator, true);
        vm.deal(creator, 0);

        address[] memory executors = new address[](3);
        executors[0] = _createExecutor(creator, bytes32("t10-0"), creator);
        executors[1] = _createExecutor(creator, bytes32("t10-1"), creator);
        executors[2] = _createExecutor(creator, bytes32("t10-2"), creator);

        vm.deal(address(factory), 3 * FEE);

        for (uint256 i; i < executors.length; ++i) {
            vm.prank(creator);
            factory.requestDispatcher(executors[i], REMOTE_CHAIN, _vaults(), MAX_FEE);
        }
        assertEq(address(factory).balance, 0);
        assertEq(creator.balance, 0);

        address fourth = _createExecutor(creator, bytes32("t10-3"), creator);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipInsufficientNativeFeeBalance.selector, 0, FEE));
        factory.requestDispatcher(fourth, REMOTE_CHAIN, _vaults(), MAX_FEE);
    }

    // ---------------------------------------------------------------------
    // IL-8565 / IL-8605: per-executor, per-chain CREATE_DISPATCHER attempt cap
    // ---------------------------------------------------------------------

    function _nack(address executor_, bytes32 id_) private {
        bytes32 ticketHash = factory.pendingDeploymentTicket(executor_, REMOTE_CHAIN);
        _deliver(
            REMOTE_SELECTOR,
            CcipMsgType.DEPLOYMENT_NACK,
            abi.encode(executor_, REMOTE_CHAIN, ticketHash, uint8(2)),
            id_
        );
    }

    function _ttlCancel(address executor_) private {
        vm.warp(block.timestamp + factory.DEPLOYMENT_TTL() + CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN + 1);
        factory.cancelExpiredDeployment(executor_, REMOTE_CHAIN);
    }

    /// @notice Three requests, each cleared by a NACK or a TTL cancel, exhaust the budget; the fourth reverts
    ///         before any fee is paid.
    /// @dev Negative: the check in `requestDispatcher` removed -> the fourth request succeeds -> fails.
    function testShouldRevertAfterMaxDeploymentAttempts() public {
        address executor = _createExecutor(address(this), bytes32("att1"), manager);
        vm.deal(address(factory), 10 * FEE);
        assertEq(factory.MAX_DEPLOYMENT_ATTEMPTS(), 3);

        _request(executor, _vaults());
        _nack(executor, "att-nack-1");
        _request(executor, _vaults());
        _ttlCancel(executor);
        _request(executor, _vaults());
        _nack(executor, "att-nack-3");
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 3);

        uint256 balanceBefore = address(factory).balance;
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.DeploymentAttemptsExhausted.selector, executor, REMOTE_CHAIN, 3)
        );
        _request(executor, _vaults());
        assertEq(address(factory).balance, balanceBefore);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));
    }

    /// @notice A NACK and a TTL cancel clear the pending ticket but leave the counter untouched.
    /// @dev Negative: either path deleting the counter -> an assertion fails.
    function testShouldNotResetAttemptsOnNackOrTtlCancel() public {
        address executor = _createExecutor(address(this), bytes32("att2"), manager);
        vm.deal(address(factory), 10 * FEE);

        _request(executor, _vaults());
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 1);
        _nack(executor, "att2-nack");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 1);

        _request(executor, _vaults());
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 2);
        _ttlCancel(executor);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 2);
    }

    /// @notice A DEPLOYMENT_ACK deletes the counter. The executor then reports `hasDispatcher`, so a new request
    ///         on the pair is refused by that existing guard, not by the cap; the counter being 0 is asserted.
    /// @dev Negative: the ACK branch no longer deleting the counter -> the final assertion fails.
    function testShouldClearAttemptsOnSuccessfulAck() public {
        address executor = _createExecutor(address(this), bytes32("att3"), manager);
        vm.deal(address(factory), 10 * FEE);

        _request(executor, _vaults());
        _nack(executor, "att3-nack");
        _request(executor, _vaults());
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 2);

        bytes32 ticketHash = factory.pendingDeploymentTicket(executor, REMOTE_CHAIN);
        _deliver(REMOTE_SELECTOR, CcipMsgType.DEPLOYMENT_ACK, abi.encode(executor, REMOTE_CHAIN, ticketHash), "att3-ack");

        assertTrue(CcipCrosschainExecutor(payable(executor)).hasDispatcher(REMOTE_CHAIN));
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 0);
    }

    /// @notice Only the owner can clear the counter; the reset re-opens requests and emits the event.
    /// @dev Negative: the owner gate removed -> the stranger call succeeds -> fails.
    function testShouldResetAttemptsOnlyByOwner() public {
        address executor = _createExecutor(address(this), bytes32("att4"), manager);
        vm.deal(address(factory), 10 * FEE);
        _request(executor, _vaults());
        _nack(executor, "att4-nack");
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 1);

        vm.prank(stranger);
        vm.expectRevert(CcipCrosschainFactory.OnlyOwner.selector);
        factory.resetDeploymentAttempts(executor, REMOTE_CHAIN);
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 1);

        vm.expectEmit(true, true, true, true, address(factory));
        emit CcipCrosschainFactory.DeploymentAttemptsReset(executor, REMOTE_CHAIN);
        factory.resetDeploymentAttempts(executor, REMOTE_CHAIN);
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 0);
    }

    /// @notice After the cap is hit, the owner's reset re-opens the pair: a new request succeeds and counts 1.
    /// @dev Negative: the reset not clearing the counter -> the post-reset request reverts -> fails.
    function testShouldAllowRequestAgainAfterOwnerReset() public {
        address executor = _createExecutor(address(this), bytes32("att5"), manager);
        vm.deal(address(factory), 10 * FEE);

        _request(executor, _vaults());
        _nack(executor, "att5-nack-1");
        _request(executor, _vaults());
        _ttlCancel(executor);
        _request(executor, _vaults());
        _nack(executor, "att5-nack-3");
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.DeploymentAttemptsExhausted.selector, executor, REMOTE_CHAIN, 3)
        );
        _request(executor, _vaults());

        factory.resetDeploymentAttempts(executor, REMOTE_CHAIN);
        _request(executor, _vaults());
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 1);
        assertTrue(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN) != bytes32(0));
    }

    /// @notice The counter is keyed by (executor, chain): exhausting one pair leaves another executor on the same
    ///         chain, and the same executor toward another registered chain, unaffected.
    /// @dev Negative: a counter keyed by executor only, or by chain only -> one of the final requests reverts.
    function testShouldKeepAttemptCountersIndependentPerPair() public {
        address executorA = _createExecutor(address(this), bytes32("att6a"), manager);
        address executorB = _createExecutor(address(this), bytes32("att6b"), manager);
        uint256 otherChain = 10;
        _setFactoryRoute(otherChain, 4949039107694359620);
        vm.deal(address(factory), 10 * FEE);

        _request(executorA, _vaults());
        _nack(executorA, "att6-nack-1");
        _request(executorA, _vaults());
        _ttlCancel(executorA);
        _request(executorA, _vaults());
        _nack(executorA, "att6-nack-3");
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.DeploymentAttemptsExhausted.selector, executorA, REMOTE_CHAIN, 3)
        );
        _request(executorA, _vaults());

        _request(executorB, _vaults());
        assertEq(factory.deploymentAttempts(executorB, REMOTE_CHAIN), 1);

        vm.prank(manager);
        factory.requestDispatcher(executorA, otherChain, _vaults(), MAX_FEE);
        assertEq(factory.deploymentAttempts(executorA, otherChain), 1);
        assertEq(factory.deploymentAttempts(executorA, REMOTE_CHAIN), 3);
    }

    /// @notice A request whose send reverts consumes no attempt and leaves no pending ticket.
    /// @dev Negative: the counter written outside the revert scope (not rolled back) -> the counter reads 1 -> fails.
    function testShouldNotConsumeAttemptWhenSendReverts() public {
        address executor = _createExecutor(address(this), bytes32("att7"), manager);
        router.setFee(MAX_FEE + 1);
        vm.deal(address(factory), 10 * FEE);

        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipFeeTooHigh.selector, MAX_FEE + 1, MAX_FEE));
        _request(executor, _vaults());
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 0);
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0));
    }

    // ---------------------------------------------------------------------
    // IL-8473: asset config and creation-code events / hash getters
    // ---------------------------------------------------------------------

    /// @notice `scheduleAsset` emits the hash-only `ConfigScheduled` and the readable `AssetConfigScheduled`.
    function testShouldEmitAssetConfigScheduledOnScheduleAsset() public {
        bytes32 assetId = keccak256("DAI");
        uint256 executableAt = block.timestamp + factory.CONFIG_DELAY();
        bytes32 commitment = keccak256(abi.encode("ASSET", assetId, address(token), uint8(18)));

        vm.expectEmit(address(factory));
        emit CcipCrosschainFactory.ConfigScheduled(commitment, executableAt);
        vm.expectEmit(address(factory));
        emit CcipCrosschainFactory.AssetConfigScheduled(assetId, address(token), 18, executableAt);
        factory.scheduleAsset(assetId, address(token), 18);
    }

    /// @notice `executeAsset` emits `AssetConfigExecuted` and writes `assetConfig`.
    function testShouldEmitAssetConfigExecutedOnExecuteAsset() public {
        bytes32 assetId = keccak256("DAI");
        factory.scheduleAsset(assetId, address(token), 18);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());

        vm.expectEmit(address(factory));
        emit CcipCrosschainFactory.AssetConfigExecuted(assetId, address(token), 18);
        factory.executeAsset(assetId, address(token), 18);

        (address configuredToken, uint8 sharedDecimals, bool enabled) = factory.assetConfig(assetId);
        assertEq(configuredToken, address(token));
        assertEq(sharedDecimals, 18);
        assertTrue(enabled);
    }

    /// @notice `configureCreationCodes` emits `CreationCodesConfigured` and exposes both code hashes.
    function testShouldEmitCreationCodesConfiguredAndExposeHashes() public {
        CcipCrosschainFactory fresh = new CcipCrosschainFactory(address(router), address(this));
        assertEq(fresh.executorCreationCodeHash(), bytes32(0));
        assertEq(fresh.dispatcherCreationCodeHash(), bytes32(0));

        bytes memory executorCode = type(CcipCrosschainExecutor).creationCode;
        bytes memory dispatcherCode = type(CcipCrosschainDispatcher).creationCode;
        bytes32 executorHash = keccak256(executorCode);
        bytes32 dispatcherHash = keccak256(dispatcherCode);

        vm.expectEmit(address(fresh));
        emit CcipCrosschainFactory.CreationCodesConfigured(executorHash, dispatcherHash);
        fresh.configureCreationCodes(executorCode, dispatcherCode);

        assertEq(fresh.executorCreationCodeHash(), executorHash);
        assertEq(fresh.dispatcherCreationCodeHash(), dispatcherHash);
    }
}
