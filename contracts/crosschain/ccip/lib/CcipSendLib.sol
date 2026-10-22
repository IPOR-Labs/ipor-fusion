// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CcipRouteConfig} from "../interfaces/ICcipCrosschain.sol";
import {CcipClient, ICcipRouterClient} from "../interfaces/CcipClient.sol";

/// @title CcipSendLib
/// @notice Linked CCIP sender shared by the factory, executor and dispatcher runtimes.
/// @dev This is an external linked library so the send path is not duplicated into every
///      `CcipAppBase` consumer's runtime, which keeps them below EIP-170. It operates on the
///      caller's storage and balance through delegatecall, exactly like `StargateLzSendLib` on the
///      Stargate side: `address(this)` is the consumer, so the approvals and the native fee are the
///      consumer's and the emitted log carries the consumer's address. The error and event
///      declarations are duplicated from `CcipAppBase` so their selectors and topics are identical.
library CcipSendLib {
    using SafeERC20 for IERC20;

    error CcipUnknownChain(uint256 chainId);
    error CcipFeeTooHigh(uint256 fee, uint256 maxFee);
    error CcipFeeCeilingTooHigh(uint256 supplied, uint256 routeMaximum);
    error CcipInsufficientNativeFeeBalance(uint256 balance, uint256 required);
    error CcipFeeTokenMismatch(address expected, address supplied);
    error CcipGasLimitBelowRoutePolicy(uint256 supplied, uint256 policy);
    error CcipRouteGasPolicyUnset(uint256 chainId);

    event CcipMessageSent(bytes32 messageId, uint256 dstChainId, bool withToken, uint256 fee);

    /// @notice Arguments of one CCIP send, packed into a memory struct so the library entry point
    ///         stays within the stack limit without `via_ir`.
    struct SendParams {
        address router;
        uint256 dstChainId;
        bytes data;
        address token;
        uint256 amount;
        uint256 maxFee;
        address feeToken;
        /// @dev Destination gas limit requested by the caller: 0 = use the route policy, above the policy is
        ///      clamped to it, below the policy reverts (`CcipGasLimitBelowRoutePolicy`).
        uint256 gasLimit;
        /// @dev When false the caller's `gasLimit` is used verbatim. Only the factory's deployment ticket sets it,
        ///      because its gas limit is its own timelocked `dispatcherDeploymentGasLimit`, not the route policy.
        bool bindToRoutePolicy;
        bool allowOutOfOrderExecution;
    }

    /// @notice The destination gas limit a token-less message (COMMAND / UPDATE_VAULTS / RETRY) to `dstChainId_` is
    ///         sent with: the route's `messageGasLimit`, resolved exactly as `send` does (0 or above policy is
    ///         clamped to it, below reverts). The executor derives the command's gas budget from this value before
    ///         it encodes the command (IL-8625).
    /// @param routes_ The caller's route mapping.
    /// @param dstChainId_ The destination chain.
    /// @param gasLimit_ The caller-requested limit (0 = policy).
    function commandGasLimit(
        mapping(uint256 chainId => CcipRouteConfig route) storage routes_,
        uint256 dstChainId_,
        uint256 gasLimit_
    ) public view returns (uint256) {
        CcipRouteConfig memory route = routes_[dstChainId_];
        if (!route.enabled) revert CcipUnknownChain(dstChainId_);
        return _boundToPolicy(route, dstChainId_, false, gasLimit_);
    }

    function _boundToPolicy(
        CcipRouteConfig memory route_,
        uint256 dstChainId_,
        bool withToken_,
        uint256 gasLimit_
    ) private pure returns (uint256) {
        uint256 policy = withToken_ ? route_.tokenGasLimit : route_.messageGasLimit;
        if (policy == 0) revert CcipRouteGasPolicyUnset(dstChainId_);
        if (gasLimit_ == 0 || gasLimit_ > policy) return policy;
        if (gasLimit_ < policy) revert CcipGasLimitBelowRoutePolicy(gasLimit_, policy);
        return gasLimit_;
    }

    /// @notice Sends one CCIP message, optionally carrying `p_.amount` of `p_.token`.
    /// @dev The destination gas limit is bound by the timelocked route policy synchronised from the factory:
    ///      `tokenGasLimit` when the message carries tokens (`p_.amount != 0`), otherwise `messageGasLimit`.
    ///      When `p_.bindToRoutePolicy` is set, `p_.gasLimit == 0` selects the policy, a larger value is clamped to
    ///      it (the quote cannot be inflated past policy) and a smaller non-zero value reverts (a token transfer
    ///      cannot be under-gassed). An unset (zero) policy reverts `CcipRouteGasPolicyUnset`.
    /// @param routes_ The caller's route mapping; the destination route is read from it.
    /// @param p_ The send arguments, including the router and the out-of-order flag resolved by the caller.
    /// @return messageId The router-assigned message id.
    /// @return fee The fee quoted and paid for the message.
    function send(
        mapping(uint256 chainId => CcipRouteConfig route) storage routes_,
        SendParams memory p_
    ) public returns (bytes32 messageId, uint256 fee) {
        CcipRouteConfig memory route = routes_[p_.dstChainId];
        if (!route.enabled) revert CcipUnknownChain(p_.dstChainId);
        if (route.feeToken != p_.feeToken) revert CcipFeeTokenMismatch(route.feeToken, p_.feeToken);
        if (p_.maxFee > route.maxFee) revert CcipFeeCeilingTooHigh(p_.maxFee, route.maxFee);

        uint256 gasLimit = p_.gasLimit;
        if (p_.bindToRoutePolicy) gasLimit = _boundToPolicy(route, p_.dstChainId, p_.amount != 0, gasLimit);

        CcipClient.EVMTokenAmount[] memory amounts = new CcipClient.EVMTokenAmount[](p_.amount == 0 ? 0 : 1);
        if (p_.amount != 0) amounts[0] = CcipClient.EVMTokenAmount({token: p_.token, amount: p_.amount});
        CcipClient.EVM2AnyMessage memory message = CcipClient.EVM2AnyMessage({
            receiver: abi.encode(route.peer),
            data: p_.data,
            tokenAmounts: amounts,
            feeToken: p_.feeToken,
            extraArgs: CcipClient.argsToBytes(
                CcipClient.GenericExtraArgsV2({
                    gasLimit: gasLimit,
                    allowOutOfOrderExecution: p_.allowOutOfOrderExecution
                })
            )
        });
        ICcipRouterClient router = ICcipRouterClient(p_.router);
        fee = router.getFee(route.chainSelector, message);
        if (fee > p_.maxFee) revert CcipFeeTooHigh(fee, p_.maxFee);

        bool sharedToken = p_.amount != 0 && p_.feeToken == p_.token;
        if (p_.amount != 0) IERC20(p_.token).forceApprove(address(router), p_.amount + (sharedToken ? fee : 0));
        if (p_.feeToken == address(0)) {
            if (address(this).balance < fee) revert CcipInsufficientNativeFeeBalance(address(this).balance, fee);
            messageId = router.ccipSend{value: fee}(route.chainSelector, message);
        } else {
            if (!sharedToken) IERC20(p_.feeToken).forceApprove(address(router), fee);
            messageId = router.ccipSend(route.chainSelector, message);
            if (!sharedToken) IERC20(p_.feeToken).forceApprove(address(router), 0);
        }
        if (p_.amount != 0) IERC20(p_.token).forceApprove(address(router), 0);
        emit CcipMessageSent(messageId, p_.dstChainId, p_.amount != 0, fee);
    }
}
