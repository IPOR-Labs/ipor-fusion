// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICrosschainFactory, DeploymentRequest} from "../../interfaces/ICrosschainFactory.sol";
import {DeploymentStatus, CrosschainConstants} from "../../lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {StargateLzSendLib} from "./StargateLzSendLib.sol";

struct DeploymentRequestRecord {
    uint256 dstChainId;
    DeploymentStatus status;
    address[] vaults;
}

/// @notice Linked dispatcher-deployment bookkeeping and `registerChain` validation for `StargateCrosschainExecutor`.
library StargateExecutorDeploymentLib {
    /// @notice Lowest executor `lzReceive` gas accepted for the command lane (IL-8625): the smallest lane that still
    ///         yields a `COMMAND_EXECUTION_MIN_GAS` budget for the largest payload, a 32-vault UPDATE_VAULTS (39 stored
    ///         words): `laneGasFor(1,000,000, 39 words)` = about 2.47M with `COMMAND_PRE_CALL_BASE` 500,000, 24,000 per
    ///         word and the endpoint's lane / 64 hop loss, rounded up (pinned by the constants test). The executor stamps
    ///         every command with `CrosschainMessages.commandGasBudget(lane gas, words, true)` and refuses a budget below the
    ///         floor, so a smaller lane is refused at registration (2,000,000 is no longer registrable). This is only the
    ///         protocol minimum: the lane must be sized to the heaviest allowed action (see the README), or topped up per
    ///         command.
    uint128 internal constant COMMAND_LANE_MIN_RECEIVE_GAS = 2_500_000;

    /// @notice Highest executor `lzReceive` gas accepted for the command lane, well above the 4,000,000
    ///         reference option recommended by IL-8617 and far below any unpayable amount.
    uint128 internal constant COMMAND_LANE_MAX_RECEIVE_GAS = 10_000_000;

    struct RequestParams {
        bytes32 assetId;
        address admin;
        address guardian;
        uint256 rescueDelay;
        uint256 srcChainId;
        uint256 dstChainId;
    }

    event DispatcherRequested(uint256 dstChainId, uint256 requestId);
    event DispatcherReady(uint256 dstChainId, uint256 requestId);
    event DispatcherRequestResolved(uint256 requestId, uint8 status);

    /// @dev Files a dispatcher deployment request for `params_.dstChainId` with the factory and records it as
    ///      `PENDING`, remembering the vaults to wire once the dispatcher is ready. `immutableParamsHash` binds
    ///      admin, guardian, rescue delay, source and destination chains and the asset id, so the factory and the
    ///      later ACK can be checked against the same parameters. Sets the chain's pending pointer and emits
    ///      `DispatcherRequested`.
    /// @param pendingRequestByChain_ Pending request id per destination chain.
    /// @param requests_ Deployment request records by id.
    /// @param factory_ The crosschain factory that deploys the dispatcher.
    /// @param params_ The request parameters (destination chain, asset, admin, guardian, rescue delay, source chain).
    /// @param vaults_ The vaults to activate once the dispatcher is deployed.
    /// @return requestId The factory-assigned request id.
    function request(
        mapping(uint256 chainId => uint256 requestId) storage pendingRequestByChain_,
        mapping(uint256 requestId => DeploymentRequestRecord record) storage requests_,
        ICrosschainFactory factory_,
        RequestParams memory params_,
        address[] calldata vaults_
    ) public returns (uint256 requestId) {
        DeploymentRequest memory request_ = DeploymentRequest({
            executor: address(this),
            dstChainId: params_.dstChainId,
            assetId: params_.assetId,
            admin: params_.admin,
            rescueGuardian: params_.guardian,
            rescueDelay: params_.rescueDelay,
            immutableParamsHash: keccak256(
                abi.encode(
                    params_.admin,
                    params_.guardian,
                    params_.rescueDelay,
                    params_.srcChainId,
                    params_.dstChainId,
                    params_.assetId
                )
            )
        });
        requestId = factory_.requestDispatcher(request_);
        DeploymentRequestRecord storage record = requests_[requestId];
        record.dstChainId = params_.dstChainId;
        record.status = DeploymentStatus.PENDING;
        record.vaults = vaults_;
        pendingRequestByChain_[params_.dstChainId] = requestId;
        emit DispatcherRequested(params_.dstChainId, requestId);
    }

    /// @dev Records the dispatcher deployed for `requestId_` as ready (`DEPLOYED`) and returns the vaults saved at
    ///      request time. The request must be `PENDING` for `dstChainId_` and the reported dispatcher must be the
    ///      executor's same-address twin (`DispatcherAddressMismatch` otherwise). Late ACK (IL-8649): a
    ///      `CANCELLED` request is promoted by a late factory ACK only while nothing else decided the chain, i.e.
    ///      no newer request is pending and no dispatcher is recorded yet; otherwise the ACK stays rejected with
    ///      `DeploymentRequestInvalid`. A late promotion leaves the chain's pending pointer untouched.
    /// @param pendingRequestByChain_ Pending request id per destination chain.
    /// @param requests_ Deployment request records by id.
    /// @param hasDispatcher_ Whether a dispatcher is already recorded per chain.
    /// @param dispatcherChainIds_ Chains with a recorded dispatcher.
    /// @param requestId_ The request being acknowledged.
    /// @param dstChainId_ The destination chain the dispatcher was deployed on.
    /// @param dispatcher_ The deployed dispatcher address reported by the factory.
    /// @return vaults The vaults saved with the request.
    function markReady(
        mapping(uint256 chainId => uint256 requestId) storage pendingRequestByChain_,
        mapping(uint256 requestId => DeploymentRequestRecord record) storage requests_,
        mapping(uint256 chainId => bool ready) storage hasDispatcher_,
        uint256[] storage dispatcherChainIds_,
        uint256 requestId_,
        uint256 dstChainId_,
        address dispatcher_
    ) public returns (address[] memory vaults) {
        DeploymentRequestRecord storage record = requests_[requestId_];
        // A CANCELLED request is promoted by a late factory ACK (IL-8649) only while nothing else decided the
        // chain: no newer request pending and no dispatcher already recorded; otherwise the ACK stays rejected.
        bool late = record.status == DeploymentStatus.CANCELLED;
        if ((record.status != DeploymentStatus.PENDING && !late) || record.dstChainId != dstChainId_) {
            revert CrosschainErrors.DeploymentRequestInvalid(requestId_);
        }
        if (late && (pendingRequestByChain_[dstChainId_] != 0 || hasDispatcher_[dstChainId_])) {
            revert CrosschainErrors.DeploymentRequestInvalid(requestId_);
        }
        if (dispatcher_ != address(this)) {
            revert CrosschainErrors.DispatcherAddressMismatch(address(this), dispatcher_);
        }
        record.status = DeploymentStatus.DEPLOYED;
        hasDispatcher_[dstChainId_] = true;
        dispatcherChainIds_.push(dstChainId_);
        if (!late) delete pendingRequestByChain_[dstChainId_];
        vaults = record.vaults;
        emit DispatcherReady(dstChainId_, requestId_);
    }

    /// @dev Closes a `PENDING` request with the terminal `status_` (the executor passes `FAILED` or `CANCELLED`)
    ///      and clears the chain's pending pointer; any other state reverts `DeploymentRequestInvalid`. A request
    ///      closed as `CANCELLED` can still be promoted later by a late ACK in `markReady` (IL-8649).
    /// @param pendingRequestByChain_ Pending request id per destination chain.
    /// @param requests_ Deployment request records by id.
    /// @param requestId_ The request being closed.
    /// @param status_ The terminal status to record.
    function resolve(
        mapping(uint256 chainId => uint256 requestId) storage pendingRequestByChain_,
        mapping(uint256 requestId => DeploymentRequestRecord record) storage requests_,
        uint256 requestId_,
        DeploymentStatus status_
    ) public {
        DeploymentRequestRecord storage record = requests_[requestId_];
        if (record.status != DeploymentStatus.PENDING) {
            revert CrosschainErrors.DeploymentRequestInvalid(requestId_);
        }
        record.status = status_;
        delete pendingRequestByChain_[record.dstChainId];
        emit DispatcherRequestResolved(requestId_, uint8(status_));
    }

    /// @notice Validates a manager chain registration before the base path write: the chain cap, the
    ///         hard equality against the factory's frozen path table, and the command-lane
    ///         options. Reverts `CommandLaneOptionsInvalid` unless the last supplied `commandLaneMsgType_`
    ///         entry (the one that will actually be stored, since later duplicates overwrite earlier ones)
    ///         is exactly one executor `lzReceive` option with gas in
    ///         [`COMMAND_LANE_MIN_RECEIVE_GAS`, `COMMAND_LANE_MAX_RECEIVE_GAS`] and no native value, and
    ///         nothing else — or if no such entry is supplied at all (IL-8296).
    /// @param factory_ The executor's `FACTORY` immutable.
    /// @param registeredChainCount_ The executor's current `registeredChainCount`.
    /// @param chainId_ EVM chain id being registered.
    /// @param eid_ LayerZero endpoint id being registered.
    /// @param commandLaneMsgType_ The executor's `MSG_OPTION_TYPE`, passed in rather than duplicated here.
    /// @param enforcedOptions_ ABI-encoded `EnforcedOptionParam[]` for this path, or empty.
    /// @return commandLaneGas The command-lane `lzReceive` gas the executor stores for the chain (IL-8625).
    function validateRegistration(
        ICrosschainFactory factory_,
        uint256 registeredChainCount_,
        uint256 chainId_,
        uint32 eid_,
        uint16 commandLaneMsgType_,
        bytes calldata enforcedOptions_
    ) public view returns (uint128 commandLaneGas) {
        if (registeredChainCount_ >= CrosschainConstants.MAX_DISPATCHER_CHAINS) {
            revert CrosschainErrors.DispatcherChainsCapReached(CrosschainConstants.MAX_DISPATCHER_CHAINS);
        }
        // Hard equality check against the factory's frozen path table. `eidOf`/`chainIdOf`
        // revert on unknown, so a wrong or unregistered pair can never pass.
        if (factory_.eidOf(chainId_) != eid_ || factory_.chainIdOf(eid_) != chainId_) {
            revert CrosschainErrors.FactoryPathMismatch(chainId_, eid_);
        }
        bool ok;
        (ok, commandLaneGas) = StargateLzSendLib.lzReceiveOnlyGas(enforcedOptions_, commandLaneMsgType_);
        if (!ok || commandLaneGas < COMMAND_LANE_MIN_RECEIVE_GAS || commandLaneGas > COMMAND_LANE_MAX_RECEIVE_GAS) {
            revert CrosschainErrors.CommandLaneOptionsInvalid(eid_);
        }
    }
}
