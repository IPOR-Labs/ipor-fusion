// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Command} from "../../lib/CrosschainMessages.sol";

struct CcipRouteConfig {
    uint64 chainSelector;
    address peer;
    address feeToken;
    uint96 messageGasLimit;
    uint96 tokenGasLimit;
    uint256 maxFee;
    bool enabled;
}

interface ICcipCrosschainExecutor {
    /// @dev Same as the 6-argument overload with `minDelivered_ = 0` (no floor).
    function sendAssetToDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external returns (bytes32);

    /// @param minDelivered_ Floor on the tokens the destination must receive, local asset decimals; 0 = none.
    ///        A miss is reported by `SettledBelowMinDelivered` at settlement, it never reverts or blocks.
    function sendAssetToDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_,
        uint256 minDelivered_
    ) external returns (bytes32);

    function requestAssetsFromDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 minReturn_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external returns (bytes32);

    function cancelPendingReturn(uint256 chainId_) external;

    function chainBlocked(uint256 chainId_) external view returns (bool);

    function cancelStalePendingReturn(uint256 chainId_) external;

    /// @dev `command_.minExecutionGas` (IL-8625): 0 = none; non-zero must be <= the budget derived from the effective gas
    ///      limit and <= `MAX_COMMAND_EXECUTION_GAS` (else `CommandBudgetAboveLane` / `CommandBudgetAboveMax`); the derived
    ///      budget is stamped, never the requested value.
    function sendCommandToDispatcher(
        uint256 dstChainId_,
        Command calldata command_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external returns (bytes32);

    function retryCommand(
        uint256 dstChainId_,
        bytes32 commandId_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external returns (bytes32);

    function cancelCommand(
        uint256 dstChainId_,
        bytes32 commandId_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external returns (bytes32);

    function updateVaults(
        uint256 dstChainId_,
        address[] calldata vaults_,
        bool allowed_,
        bool replace_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) external returns (bytes32);

    function requestRemoteBalance(uint256 dstChainId_, uint256 maxFee_, address feeToken_, uint256 gasLimit_)
        external
        returns (bytes32);

    /// @notice Records a proposal for a chain's remote balance (balance proposer only).
    /// @param balance_ The observed remote balance in LOCAL decimals of the executor's asset; the executor floors
    ///        it to shared decimals before recording it. The dispatcher's `observation().accountedBalance` is in
    ///        SHARED decimals: multiply it by the executor's `DECIMAL_CONVERSION_RATE` before proposing it.
    function proposeBalance(
        uint256 chainId_,
        uint256 balance_,
        uint64 stateVersion_,
        uint64 remoteBlock_,
        uint64 remoteTimestamp_,
        uint64 expiry_,
        bytes32 trackedPositionSetHash_
    ) external returns (uint256);

    function approveBalance(uint256 proposalId_) external;

    function rejectBalanceAndBlock(uint256 proposalId_) external;
}

interface ICcipExecutorRouteRegistrar {
    function registerExecutorRoute(address executor_, uint256 chainId_, CcipRouteConfig calldata route_) external;

    function syncCcipRoutePolicy(address app_, uint256 chainId_) external;
}
