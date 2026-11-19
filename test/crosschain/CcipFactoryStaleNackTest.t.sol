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

/// @title CcipFactoryStaleNackTest
/// @notice IL-9685 (L54): a `DEPLOYMENT_NACK` answering a cancelled request must not close an identical fresh
///         re-request. The ticket hash carries no nonce and is identical across identical re-requests (IL-8486), so
///         the NACK now echoes the request's `expiresAt` (`createdAt + DEPLOYMENT_TTL`) and the source refuses one
///         whose `expiresAt` is not the pending request's (`StaleDeploymentNack`).
/// @dev Harness as in `CcipFactoryDeploymentRecoveryTest`: one factory instance plays both chains via `vm.chainId`,
///      `MockCcipRouter.setAutoDeliver(false)` holds every send, and a message that reverts on the receiver stays
///      executable (the OffRamp's FAILED state), so a late manual execution is the same payload delivered again.
///      Unlike the hand-built NACKs of the other factory suites, every NACK here is the destination factory's own
///      answer to the held `CREATE_DISPATCHER`, so the test follows the wire format of the code under test and
///      compiles and runs unchanged on the base (`StaleDeploymentNack` is matched by its signature).
///      On base 8692fbe5 the stale NACK closes the fresh request: the `StaleDeploymentNack` expectation fails.
///      Negative (re-injection): drop the `expiresAt` comparison in the factory's NACK branch -> the stale NACK is
///      accepted and closes the re-request -> both tests fail at that expectation.
contract CcipFactoryStaleNackTest is Test {
    MockCcipRouter internal router;
    MockERC20 internal token;
    CcipCrosschainFactory internal factory;

    bytes32 internal constant ASSET_ID = keccak256("USDC");
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant REMOTE_SELECTOR = 15971525489660198786;
    uint64 internal constant LOCAL_SELECTOR = 5009297550715157269;
    uint256 internal constant MAX_FEE = 0.01 ether;
    uint256 internal constant FEE = 0.001 ether;
    /// @dev CREATE3 proxy init code hash (the factory's CREATE3 library), used to free the predicted address.
    bytes32 internal constant CREATE3_PROXY_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;
    string internal constant STALE_NACK_SIG = "StaleDeploymentNack(address,uint256,uint256,uint256)";

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
            type(CcipCrosschainExecutor).creationCode,
            type(CcipCrosschainDispatcher).creationCode
        );
        _setFactoryRoute(REMOTE_CHAIN, REMOTE_SELECTOR);
        // The route back to LOCAL_CHAIN is registered from the destination's view (one factory plays both sides).
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

    function _createExecutor(bytes32 userSalt_) private returns (address) {
        return
            factory.createExecutor(
                userSalt_,
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
                    anchorBandBps: 2_000,
                    minUpdateInterval: 1 hours,
                    transferStalenessMax: 1 days
                })
            );
    }

    function _list(address vault_) private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = vault_;
    }

    /// @dev Sends a `CREATE_DISPATCHER` as the executor's manager; returns the pending hash, the request's
    ///      `expiresAt` and the held raw payload of the ticket message.
    function _request(
        address executor_,
        address[] memory vaults_
    ) private returns (bytes32 ticketHash, uint256 expiresAt, bytes memory createDispatcher) {
        vm.prank(manager);
        factory.requestDispatcher(executor_, REMOTE_CHAIN, vaults_, MAX_FEE);
        ticketHash = factory.pendingDeploymentTicket(executor_, REMOTE_CHAIN);
        expiresAt = uint256(factory.pendingDeploymentCreatedAt(executor_, REMOTE_CHAIN)) + factory.DEPLOYMENT_TTL();
        createDispatcher = router.heldData(router.heldCount() - 1);
        (CcipMsgType messageType, ) = CcipMessages.decode(createDispatcher);
        assertEq(uint8(messageType), uint8(CcipMsgType.CREATE_DISPATCHER), "held ticket");
    }

    /// @dev Owner cancel strictly after `createdAt + DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN`.
    function _cancelAfterTtl(address executor_) private {
        vm.warp(
            uint256(factory.pendingDeploymentCreatedAt(executor_, REMOTE_CHAIN)) +
                factory.DEPLOYMENT_TTL() +
                CrosschainConstants.DEPLOYMENT_CANCEL_MARGIN +
                1
        );
        factory.cancelExpiredDeployment(executor_, REMOTE_CHAIN);
        assertEq(factory.pendingDeploymentTicket(executor_, REMOTE_CHAIN), bytes32(0), "ticket cancelled");
    }

    function _deliverRaw(uint64 sourceChainSelector_, bytes memory rawData_, bytes32 messageId_) private {
        vm.prank(address(router));
        factory.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: messageId_,
                sourceChainSelector: sourceChainSelector_,
                sender: abi.encode(address(factory)),
                data: rawData_,
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    /// @dev Executes a held `CREATE_DISPATCHER` on the destination view and returns the factory's held answer.
    function _answerOnDestination(bytes memory createDispatcher_, bytes32 messageId_) private returns (bytes memory) {
        uint256 heldBefore = router.heldCount();
        vm.chainId(REMOTE_CHAIN);
        _deliverRaw(LOCAL_SELECTOR, createDispatcher_, messageId_);
        vm.chainId(LOCAL_CHAIN);
        assertEq(router.heldCount(), heldBefore + 1, "one answer sent");
        return router.heldData(router.heldCount() - 1);
    }

    function _assertNackType(bytes memory rawAnswer_) private pure {
        (CcipMsgType messageType, ) = CcipMessages.decode(rawAnswer_);
        assertEq(uint8(messageType), uint8(CcipMsgType.DEPLOYMENT_NACK), "destination answered NACK");
    }

    function _staleNackError(
        address executor_,
        uint256 pendingExpiresAt_,
        uint256 staleExpiresAt_
    ) private pure returns (bytes memory) {
        return abi.encodeWithSignature(STALE_NACK_SIG, executor_, REMOTE_CHAIN, pendingExpiresAt_, staleExpiresAt_);
    }

    function _unknown(address executor_, bytes32 ticketHash_) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                CcipCrosschainFactory.UnknownDeploymentAck.selector,
                executor_,
                REMOTE_CHAIN,
                ticketHash_
            );
    }

    /// @dev One factory plays both sides: empties the executor address and its CREATE3 proxy so the destination
    ///      side does not see the address occupied (a rejected deployment rolls back, the caller restores the code).
    function _freePredictedAddress(address executor_) private {
        vm.etch(executor_, "");
        vm.resetNonce(executor_);
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), factory.saltOf(executor_), CREATE3_PROXY_HASH)
                    )
                )
            )
        );
        vm.etch(proxy, "");
        vm.resetNonce(proxy);
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    /// @notice The destination answers request #1 with NACK(1); the NACK is not executed before the source cancels
    ///         the ticket. After an identical re-request (same ticket hash) the manual re-execution of that NACK
    ///         reverts `StaleDeploymentNack`: the re-request stays pending with its own `createdAt` and the attempt
    ///         counter does not move. The re-request's own NACK then closes it.
    /// @dev On base the stale NACK closes the re-request (no revert) -> the `StaleDeploymentNack` expectation fails.
    function testShouldNotCloseIdenticalReRequestWithStaleNackOfCancelledRequest() public {
        address executor = _createExecutor(bytes32("stale-nack-1"));
        CcipCrosschainExecutor exec = CcipCrosschainExecutor(payable(executor));

        (bytes32 hash1, uint256 expiresAt1, bytes memory create1) = _request(executor, _list(address(0xA001)));
        // The executor occupies the predicted address in this one-factory harness: the destination answers NACK(1).
        bytes memory staleNack = _answerOnDestination(create1, "create-1");
        _assertNackType(staleNack);

        // The NACK reaches the source only after the cancel: its first execution fails, it stays executable.
        _cancelAfterTtl(executor);
        vm.expectRevert(_unknown(executor, hash1));
        _deliverRaw(REMOTE_SELECTOR, staleNack, "nack-1");

        (bytes32 hash2, uint256 expiresAt2, bytes memory create2) = _request(executor, _list(address(0xA001)));
        assertEq(hash2, hash1, "identical re-request has the identical ticket hash");
        assertGt(expiresAt2, expiresAt1, "the re-request is a later request");
        uint64 createdAt2 = factory.pendingDeploymentCreatedAt(executor, REMOTE_CHAIN);
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 2, "two attempts counted");

        // Manual re-execution of the stale NACK: refused, nothing changes.
        vm.expectRevert(_staleNackError(executor, expiresAt2, expiresAt1));
        _deliverRaw(REMOTE_SELECTOR, staleNack, "nack-1");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), hash1, "re-request still pending");
        assertEq(factory.pendingDeploymentCreatedAt(executor, REMOTE_CHAIN), createdAt2, "own createdAt kept");
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 2, "attempt counter unchanged");
        assertFalse(exec.hasDispatcher(REMOTE_CHAIN), "no dispatcher");

        // The re-request's own NACK closes it; a NACK still does not reset the attempt counter.
        bytes memory freshNack = _answerOnDestination(create2, "create-2");
        _assertNackType(freshNack);
        vm.expectEmit(true, true, true, true, address(factory));
        emit CcipCrosschainFactory.DeploymentNack(executor, REMOTE_CHAIN, hash1, 1);
        _deliverRaw(REMOTE_SELECTOR, freshNack, "nack-2");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), bytes32(0), "closed by its own NACK");
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 2, "a NACK does not reset the counter");
        assertFalse(exec.hasDispatcher(REMOTE_CHAIN), "a NACK never marks the dispatcher ready");

        // Each NACK names its request by the `expiresAt` the destination received with the ticket.
        (, bytes memory staleData) = CcipMessages.decode(staleNack);
        (, , , , uint256 staleExpiresAt) = abi.decode(staleData, (address, uint256, bytes32, uint8, uint256));
        assertEq(staleExpiresAt, expiresAt1, "stale NACK carries the cancelled request's expiresAt");
        (, bytes memory freshData) = CcipMessages.decode(freshNack);
        (, , , , uint256 freshExpiresAt) = abi.decode(freshData, (address, uint256, bytes32, uint8, uint256));
        assertEq(freshExpiresAt, expiresAt2, "fresh NACK carries the re-request's expiresAt");
    }

    /// @notice The IL-8637 R3 case: request #1 is rejected on the destination because a vault's asset changed
    ///         (NACK(3), nothing deployed) and the NACK is late; the vault is fixed and an identical re-request is
    ///         sent. The stale NACK(3) says nothing about the re-request and is refused. When the re-request's ACK is
    ///         late as well and the source cancels it first, that ACK still lands (`DeploymentLateAcked`).
    /// @dev On base the stale NACK(3) closes the re-request and emits a misleading `DeploymentNack` -> the
    ///      `StaleDeploymentNack` expectation fails.
    function testShouldRefuseStaleVaultRejectionNackAndStillLandLateAckOfReRequest() public {
        StaleNackStubVault vault = new StaleNackStubVault(address(token));
        address[] memory vaults = _list(address(vault));
        address executor = _createExecutor(bytes32("stale-nack-3"));
        CcipCrosschainExecutor exec = CcipCrosschainExecutor(payable(executor));

        (bytes32 hash1, uint256 expiresAt1, bytes memory create1) = _request(executor, vaults);

        // The vault's asset changes before delivery: the destination's dispatcher rejects the list -> NACK(3).
        vault.setAsset(address(0xBAD));
        bytes memory executorCode = executor.code;
        _freePredictedAddress(executor);
        bytes memory staleNack = _answerOnDestination(create1, "create-1");
        vm.etch(executor, executorCode);
        _assertNackType(staleNack);
        (, bytes memory staleData) = CcipMessages.decode(staleNack);
        // The leading four words are the same in both layouts (`expiresAt` is appended).
        (, , , uint8 reason) = abi.decode(staleData, (address, uint256, bytes32, uint8));
        assertEq(reason, 3, "vault list rejected");
        assertFalse(factory.consumedTicket(hash1), "nothing deployed for request #1");

        // The NACK is late; request #1 is cancelled; the vault is fixed and an identical request is sent.
        _cancelAfterTtl(executor);
        vault.setAsset(address(token));
        (bytes32 hash2, uint256 expiresAt2, ) = _request(executor, vaults);
        assertEq(hash2, hash1, "identical re-request has the identical ticket hash");

        vm.expectRevert(_staleNackError(executor, expiresAt2, expiresAt1));
        _deliverRaw(REMOTE_SELECTOR, staleNack, "nack-3");
        assertEq(factory.pendingDeploymentTicket(executor, REMOTE_CHAIN), hash1, "re-request still pending");

        // The re-request's ACK is late too: the source cancels it first. The stale NACK then finds nothing pending.
        _cancelAfterTtl(executor);
        vm.expectRevert(_unknown(executor, hash1));
        _deliverRaw(REMOTE_SELECTOR, staleNack, "nack-3");

        // The late ACK (format unchanged) still completes the pair.
        vm.expectEmit(true, true, true, true, address(factory));
        emit CcipCrosschainFactory.DeploymentLateAcked(executor, REMOTE_CHAIN, hash1);
        _deliverRaw(
            REMOTE_SELECTOR,
            CcipMessages.encode(CcipMsgType.DEPLOYMENT_ACK, abi.encode(executor, REMOTE_CHAIN, hash1)),
            "ack-2"
        );
        assertTrue(exec.hasDispatcher(REMOTE_CHAIN), "dispatcher ready via the late ACK");
        assertEq(factory.deploymentAttempts(executor, REMOTE_CHAIN), 0, "attempts cleared by the ACK");
    }
}

contract StaleNackStubVault {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }
}
