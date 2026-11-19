// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CcipExecutorFixture, CcipFixtureToken} from "test/crosschain/CcipExecutorFixture.sol";
import {CcipCrosschainExecutor} from "contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipMessages, CcipMsgType} from "contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "test/crosschain/mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "test/crosschain/mocks/MockCcipRouteValidator.sol";

/// @notice Token with configurable local decimals for the IL-9621 fixture.
contract CcipExpiredReturnToken is CcipFixtureToken {
    uint8 private immutable _DECIMALS;

    constructor(uint8 decimals_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }
}

/// @title CcipExpiredReturnFixture
/// @notice IL-9621 shared fixture: a real CCIP executor and dispatcher on the in-memory router, with parameters the
///         suites can override (local and shared decimals, `balanceStalenessMax`, the route `maxFee`, the transfer
///         staleness), helpers that make token-bearing sends fail the way a used-up pool rate limit does, a recall
///         helper that returns its deadline, and decoders of the four queued payloads that carry a dispatcher
///         balance (`TRANSFER_SETTLED`, `RETURN_TRANSFER`, `BALANCE_REPORT`, `COMMAND_ACK`).
/// @dev Uses only the dispatcher surface that exists before the IL-9621 fix (no `queuedReturnDeadline`).
abstract contract CcipExpiredReturnFixture is CcipExecutorFixture {
    error TokenRateLimitReached(uint256 minWaitInSeconds, uint256 available, address tokenAddress);

    /// @dev Decoded `COMMAND_ACK` payload: `(bytes32 commandId, uint64 sequence, int256 valueDelta, uint256 balance,
    ///      uint64 version, uint64 nextSequence, uint8 status)`.
    struct CommandAck {
        bytes32 commandId;
        uint64 sequence;
        int256 valueDelta;
        uint256 balance;
        uint64 version;
        uint64 nextSequence;
        uint8 status;
    }

    uint96 internal constant ROUTE_GAS_LIMIT = 500_000;

    // ------------------------------------------------------------------ virtual parameters

    function _localDecimals() internal view virtual returns (uint8) {
        return 18;
    }

    function _sharedDecimals() internal view virtual returns (uint8) {
        return 18;
    }

    function _expiredBalanceStalenessMax() internal view virtual returns (uint256) {
        return BALANCE_STALENESS_MAX;
    }

    function _routeMaxFee() internal view virtual returns (uint256) {
        return 0;
    }

    function _transferStalenessMax() internal view virtual returns (uint256) {
        return 1 days;
    }

    // ------------------------------------------------------------------ setup

    /// @dev Same wiring as `_fixtureSetUp`, with the virtual parameters above. Call it from `setUp` after warping.
    function _expiredFixtureSetUp() internal {
        router = new MockCcipRouter();
        token = new CcipExpiredReturnToken(_localDecimals());
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            _sharedDecimals(),
            _expiredSafety()
        );
        CcipRouteConfig memory back = _route(EXECUTOR_SELECTOR, address(executor));
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            _sharedDecimals(),
            block.chainid,
            back,
            RESCUE_ADMIN,
            address(0xB22),
            RESCUE_DELAY
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = _route(DISPATCHER_SELECTOR, address(dispatcher));
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _route(uint64 selector_, address peer_) private view returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: address(0),
                messageGasLimit: ROUTE_GAS_LIMIT,
                tokenGasLimit: ROUTE_GAS_LIMIT,
                maxFee: _routeMaxFee(),
                enabled: true
            });
    }

    function _expiredSafety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: _expiredBalanceStalenessMax(),
                bigChangeBps: 2_000,
                anchorBandBps: 2_000,
                minUpdateInterval: MIN_UPDATE_INTERVAL,
                transferStalenessMax: _transferStalenessMax()
            });
    }

    // ------------------------------------------------------------------ units

    /// @dev Local token units to shared decimals (what the queue payloads and the executor ledgers use).
    function _toShared(uint256 amountLD_) internal view returns (uint256) {
        return amountLD_ / 10 ** (_localDecimals() - _sharedDecimals());
    }

    function _toLocal(uint256 amountSD_) internal view returns (uint256) {
        return amountSD_ * 10 ** (_localDecimals() - _sharedDecimals());
    }

    // ------------------------------------------------------------------ blocking and recalls

    /// @dev Token-bearing sends of the dispatcher revert with `TokenRateLimitReached` (a used-up pool rate limit);
    ///      token-less sends still go through.
    function _blockTokenSends() internal {
        router.setFailSendWith(
            address(dispatcher),
            abi.encodeWithSelector(TokenRateLimitReached.selector, 600, 0, address(token))
        );
    }

    /// @dev Lets every send of the dispatcher through again.
    function _unblockSends() internal {
        router.setFailSendWith(address(dispatcher), "");
    }

    /// @notice Opens a recall of `amountLD_` (no minimum return).
    /// @return deadline The recall deadline the executor stamps on the request (`now + transferStalenessMax`).
    function _recall(uint256 amountLD_) internal returns (uint256 deadline) {
        deadline = block.timestamp + _transferStalenessMax();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, amountLD_, 0, 0, address(0), ROUTE_GAS_LIMIT);
    }

    // ------------------------------------------------------------------ queue decoders

    /// @return messageType Envelope type of the queued response `responseId_`.
    /// @return payload Its ABI-encoded payload.
    function _queuedPayload(uint64 responseId_) internal view returns (CcipMsgType messageType, bytes memory payload) {
        (bytes memory data, , ) = dispatcher.queuedResponse(responseId_);
        (messageType, payload) = CcipMessages.decode(data);
    }

    /// @dev `RETURN_TRANSFER` payload `(operationId, amount, balance, version)`, amounts in shared decimals.
    function _decodeReturn(
        bytes memory payload_
    ) internal pure returns (bytes32 operationId, uint256 amount, uint256 balance, uint64 version) {
        (operationId, amount, balance, version) = abi.decode(payload_, (bytes32, uint256, uint256, uint64));
    }

    /// @dev `TRANSFER_SETTLED` payload `(operationId, amount, balance, version)`, amounts in shared decimals.
    function _decodeSettled(
        bytes memory payload_
    ) internal pure returns (bytes32 operationId, uint256 amount, uint256 balance, uint64 version) {
        (operationId, amount, balance, version) = abi.decode(payload_, (bytes32, uint256, uint256, uint64));
    }

    /// @dev `BALANCE_REPORT` payload `(balance, version)`.
    function _decodeBalanceReport(bytes memory payload_) internal pure returns (uint256 balance, uint64 version) {
        (balance, version) = abi.decode(payload_, (uint256, uint64));
    }

    function _decodeCommandAck(bytes memory payload_) internal pure returns (CommandAck memory ack) {
        (ack.commandId, ack.sequence, ack.valueDelta, ack.balance, ack.version, ack.nextSequence, ack.status) = abi
            .decode(payload_, (bytes32, uint64, int256, uint256, uint64, uint64, uint8));
    }

    /// @dev Balance a queued response carries, whatever its type; `hasBalance` is false for the types without one.
    function _queuedBalance(uint64 responseId_) internal view returns (bool hasBalance, uint256 balance) {
        (CcipMsgType messageType, bytes memory payload) = _queuedPayload(responseId_);
        if (messageType == CcipMsgType.RETURN_TRANSFER) {
            (, , balance, ) = _decodeReturn(payload);
            return (true, balance);
        }
        if (messageType == CcipMsgType.TRANSFER_SETTLED) {
            (, , balance, ) = _decodeSettled(payload);
            return (true, balance);
        }
        if (messageType == CcipMsgType.BALANCE_REPORT) {
            (balance, ) = _decodeBalanceReport(payload);
            return (true, balance);
        }
        if (messageType == CcipMsgType.COMMAND_ACK) {
            return (true, _decodeCommandAck(payload).balance);
        }
    }
}
