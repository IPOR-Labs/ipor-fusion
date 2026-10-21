// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ICrosschainExecutor} from "../../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {DeploymentRequest} from "../../../contracts/crosschain/interfaces/ICrosschainFactory.sol";

/// @title MockCrosschainFactory
/// @notice Controllable factory stand-in used to drive a real `StargateCrosschainExecutor` in isolation (the real
///         factory cannot deploy a same-address dispatcher on the same test EVM). Implements exactly the
///         methods the executor calls on `FACTORY` — `eidOf`, `chainIdOf`, `requestDispatcher`,
///         `cancelPendingDeployment` — plus test helpers that fire the executor's factory-only callbacks.
/// @dev Selector-compatible with `ICrosschainFactory` for the executor's needs; does not inherit it.
contract MockCrosschainFactory {
    mapping(uint256 chainId => uint32 eid) public eids;
    mapping(uint32 eid => uint256 chainId) public chains;

    struct Req {
        address executor;
        uint256 dstChainId;
        bool exists;
    }

    uint256 public requestCounter;
    mapping(uint256 requestId => Req req) public reqs;

    /// @notice Native fee cap provider surface `StargateNativeFeeCapLib` probes on the app's `FACTORY()`.
    mapping(address app => bool) public isExecutor;
    mapping(uint256 chainId => uint256) public maxNativeFee;

    // ---------------------------------------------------------------------
    // Factory surface the executor calls
    // ---------------------------------------------------------------------

    function eidOf(uint256 chainId_) external view returns (uint32) {
        uint32 e = eids[chainId_];
        require(e != 0, "MockFactory: unknown chain");
        return e;
    }

    function chainIdOf(uint32 eid_) external view returns (uint256) {
        uint256 c = chains[eid_];
        require(c != 0, "MockFactory: unknown eid");
        return c;
    }

    function requestDispatcher(DeploymentRequest calldata request_) external returns (uint256 requestId) {
        requestId = ++requestCounter;
        reqs[requestId] = Req({executor: msg.sender, dstChainId: request_.dstChainId, exists: true});
    }

    function cancelPendingDeployment(uint256 requestId_) external {
        Req memory r = reqs[requestId_];
        require(r.exists, "MockFactory: no request");
        ICrosschainExecutor(r.executor).onDispatcherRequestCancelled(requestId_);
    }

    // ---------------------------------------------------------------------
    // Test configuration & callbacks
    // ---------------------------------------------------------------------

    function setPath(uint256 chainId_, uint32 eid_) external {
        eids[chainId_] = eid_;
        chains[eid_] = chainId_;
    }

    /// @notice Flip whether `app_` is treated as a registered executor by `StargateNativeFeeCapLib`'s probe.
    function setExecutor(address app_, bool isExecutor_) external {
        isExecutor[app_] = isExecutor_;
    }

    /// @notice Set the per-destination native fee ceiling `StargateNativeFeeCapLib` reads for a registered
    ///         executor.
    function setMaxNativeFee(uint256 chainId_, uint256 maxNativeFee_) external {
        maxNativeFee[chainId_] = maxNativeFee_;
    }

    /// @notice Simulate an authenticated ACK: flip the executor's dispatcher readiness (same-address).
    function ackDispatcher(address executor_, uint256 requestId_, uint256 dstChainId_) external {
        ICrosschainExecutor(executor_).onDispatcherCreated(requestId_, dstChainId_, executor_);
    }

    /// @notice Simulate an authenticated NACK: clear the pending request without flipping readiness.
    function nackDispatcher(address executor_, uint256 requestId_) external {
        ICrosschainExecutor(executor_).onDispatcherRequestFailed(requestId_);
    }
}
