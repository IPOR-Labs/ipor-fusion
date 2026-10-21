// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {
    ICrosschainFactory,
    DeploymentRequest,
    ExecutorInitParams
} from "../../../contracts/crosschain/interfaces/ICrosschainFactory.sol";

/// @title MockTtlExecutor
/// @notice Test-only executor creation code whose `DEPLOYMENT_TTL()` is caller-chosen and unbounded, so
///         `StargateCrosschainFactory.requestDispatcher`'s own TTL floor (IL-8069) can be exercised without
///         weakening the canonical `StargateCrosschainExecutor` constructor bound (IL-8049). The constructor
///         tuple mirrors the one the real factory appends at `createExecutor`
///         (`StargateCrosschainFactory.sol:382-387`): `(endpoint, localToken, localStargatePool, assetId,
///         factory, ExecutorInitParams)`. Only `assetId`, `factory` and `params_.deploymentTtl`/`manager` are
///         retained; the unused leading three addresses exist solely to keep the ABI layout identical.
contract MockTtlExecutor {
    ICrosschainFactory public immutable FACTORY;
    bytes32 public immutable ASSET_ID;
    uint256 public immutable DEPLOYMENT_TTL;
    address public immutable MANAGER;

    constructor(
        address /* endpoint_, unused */,
        address /* localToken_, unused */,
        address /* localStargatePool_, unused */,
        bytes32 assetId_,
        address factory_,
        ExecutorInitParams memory params_
    ) {
        ASSET_ID = assetId_;
        FACTORY = ICrosschainFactory(factory_);
        DEPLOYMENT_TTL = params_.deploymentTtl;
        MANAGER = params_.manager;
    }

    /// @notice Mirrors `StargateExecutorDeploymentLib.request`'s immutable-params-hash construction
    ///         (`contracts/crosschain/stargate/lib/StargateExecutorDeploymentLib.sol:36-53`) without any of
    ///         the canonical executor's own pending-request bookkeeping — this mock exists only to reach
    ///         `StargateCrosschainFactory.requestDispatcher` with a caller-chosen, unbounded TTL.
    function request(
        uint256 dstChainId_,
        address admin_,
        address guardian_,
        uint256 rescueDelay_
    ) public returns (uint256 requestId) {
        bytes32 immutableParamsHash = keccak256(
            abi.encode(admin_, guardian_, rescueDelay_, block.chainid, dstChainId_, ASSET_ID)
        );
        requestId = FACTORY.requestDispatcher(
            DeploymentRequest({
                executor: address(this),
                dstChainId: dstChainId_,
                assetId: ASSET_ID,
                admin: admin_,
                rescueGuardian: guardian_,
                rescueDelay: rescueDelay_,
                immutableParamsHash: immutableParamsHash
            })
        );
    }

    function cancel(uint256 requestId_) public {
        FACTORY.cancelPendingDeployment(requestId_);
    }

    /// @notice Runs `iterations_` request/cancel cycles in one external call, so a same-block
    ///         request/cancel drain loop is a single call a test can wrap in `try/catch` and assert the
    ///         invariant whether or not a guard rejects the action (the pattern
    ///         `test/crosschain/CommandCancelRetryRaceTest.t.sol` uses around `retryCommand`).
    function loop(
        uint256 dstChainId_,
        address admin_,
        address guardian_,
        uint256 rescueDelay_,
        uint256 iterations_
    ) external {
        for (uint256 i = 0; i < iterations_; ++i) {
            uint256 requestId = request(dstChainId_, admin_, guardian_, rescueDelay_);
            cancel(requestId);
        }
    }

    // --- Factory-only callbacks (`ICrosschainExecutor`); empty bodies, this suite never drives an
    //     ACK/NACK to completion for a mock executor ---
    function onDispatcherCreated(uint256, uint256, address) external {}
    function onDispatcherRequestFailed(uint256) external {}
    function onDispatcherRequestCancelled(uint256) external {}
}
