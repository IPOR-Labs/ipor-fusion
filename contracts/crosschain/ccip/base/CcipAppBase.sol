// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {CcipRouteConfig} from "../interfaces/ICcipCrosschain.sol";
import {CcipClient, ICcipMessageReceiver} from "../interfaces/CcipClient.sol";
import {CcipRouteLib} from "../lib/CcipRouteLib.sol";
import {CcipSendLib} from "../lib/CcipSendLib.sol";

abstract contract CcipAppBase is ICcipMessageReceiver, IERC165 {
    error CcipZeroAddress();
    error CcipUnknownChain(uint256 chainId);
    error CcipUnknownSelector(uint64 selector);
    error CcipRouteAlreadyRegistered(uint256 chainId, uint64 selector);
    error CcipRouteIdentityMismatch(
        uint256 chainId, uint64 expectedSelector, uint64 suppliedSelector, address expectedPeer, address suppliedPeer
    );
    error CcipUnauthorizedPeer(uint64 selector, address sender);
    error CcipMessageAlreadyProcessed(bytes32 messageId);
    error CcipFeeTooHigh(uint256 fee, uint256 maxFee);
    error CcipFeeCeilingTooHigh(uint256 supplied, uint256 routeMaximum);
    error CcipInsufficientNativeFeeBalance(uint256 balance, uint256 required);
    error CcipFeeTokenMismatch(address expected, address supplied);
    error CcipGasLimitBelowRoutePolicy(uint256 supplied, uint256 policy);
    error CcipInvalidRouter(address caller);
    error CcipUnsupportedSelector(uint64 selector);
    error CcipRouteGasPolicyUnset(uint256 chainId);

    address public immutable CCIP_ROUTER;
    mapping(uint256 chainId => CcipRouteConfig route) internal _ccipRoutes;
    mapping(uint64 selector => uint256 chainId) internal _selectorToChain;
    mapping(bytes32 messageId => bool processed) public processedCcipMessage;

    event CcipRouteRegistered(uint256 chainId, uint64 selector, address peer);
    event CcipRoutePolicyUpdated(uint256 chainId, CcipRouteConfig route);
    event CcipMessageSent(bytes32 messageId, uint256 dstChainId, bool withToken, uint256 fee);
    event CcipMessageReceived(bytes32 messageId, uint256 srcChainId, address peer);

    constructor(address router_) {
        if (router_ == address(0)) revert CcipZeroAddress();
        CCIP_ROUTER = router_;
    }

    receive() external payable {}

    function ccipRoute(uint256 chainId_) external view returns (CcipRouteConfig memory) {
        return _ccipRoutes[chainId_];
    }

    function chainIdOfSelector(uint64 selector_) external view returns (uint256) {
        uint256 chainId = _selectorToChain[selector_];
        if (chainId == 0) revert CcipUnknownSelector(selector_);
        return chainId;
    }

    function _registerCcipRoute(uint256 chainId_, CcipRouteConfig memory route_) internal {
        CcipRouteLib.setRoute(_ccipRoutes, _selectorToChain, CCIP_ROUTER, chainId_, route_);
    }

    function _updateCcipRoutePolicy(uint256 chainId_, address feeToken_, uint256 gasLimitsAndFlags_, uint256 maxFee_)
        internal
    {
        CcipRouteLib.updatePolicy(_ccipRoutes, chainId_, feeToken_, gasLimitsAndFlags_, maxFee_);
    }

    /// @dev Sends with the destination gas limit bound to the route policy (see `CcipSendLib.send`).
    function _sendCcip(
        uint256 dstChainId_,
        bytes memory data_,
        address token_,
        uint256 amount_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) internal returns (bytes32 messageId, uint256 fee) {
        return _sendCcipWithGasPolicy(dstChainId_, data_, token_, amount_, maxFee_, feeToken_, gasLimit_, true);
    }

    /// @dev Sends with `gasLimit_` used verbatim. Reserved for the factory deployment ticket, whose gas limit is
    ///      its own timelocked `dispatcherDeploymentGasLimit`.
    function _sendCcipUnbound(
        uint256 dstChainId_,
        bytes memory data_,
        address token_,
        uint256 amount_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_
    ) internal returns (bytes32 messageId, uint256 fee) {
        return _sendCcipWithGasPolicy(dstChainId_, data_, token_, amount_, maxFee_, feeToken_, gasLimit_, false);
    }

    function _sendCcipWithGasPolicy(
        uint256 dstChainId_,
        bytes memory data_,
        address token_,
        uint256 amount_,
        uint256 maxFee_,
        address feeToken_,
        uint256 gasLimit_,
        bool bindToRoutePolicy_
    ) private returns (bytes32 messageId, uint256 fee) {
        return CcipSendLib.send(
            _ccipRoutes,
            CcipSendLib.SendParams({
                router: CCIP_ROUTER,
                dstChainId: dstChainId_,
                data: data_,
                token: token_,
                amount: amount_,
                maxFee: maxFee_,
                feeToken: feeToken_,
                gasLimit: gasLimit_,
                bindToRoutePolicy: bindToRoutePolicy_,
                // Every message is sent unordered. CCIP 2.0 ignores `false` anyway, and a CCIP 1.6 lane that
                // honours it would hold every later message behind one that failed. The receivers tolerate
                // out-of-order delivery because each value or command transition is fenced: commands and
                // cancels by sequence AND deadline (IL-8255, IL-8594), command ACK/NACK receipts by commandId +
                // sequence + the active slot (a late receipt is adopted by sequence, not applied blindly), value
                // responses by the state-version frontier (IL-8496) and their operationId replay guards, and
                // balance reports are evidence only.
                allowOutOfOrderExecution: true
            })
        );
    }

    function supportsInterface(bytes4 interfaceId_) public pure returns (bool) {
        return interfaceId_ == type(ICcipMessageReceiver).interfaceId || interfaceId_ == type(IERC165).interfaceId;
    }

    function ccipReceive(CcipClient.Any2EVMMessage calldata message_) public virtual override {
        if (msg.sender != CCIP_ROUTER) revert CcipInvalidRouter(msg.sender);
        if (processedCcipMessage[message_.messageId]) revert CcipMessageAlreadyProcessed(message_.messageId);
        uint256 srcChainId = _selectorToChain[message_.sourceChainSelector];
        if (srcChainId == 0) revert CcipUnknownSelector(message_.sourceChainSelector);
        address sender = abi.decode(message_.sender, (address));
        if (_ccipRoutes[srcChainId].peer != sender) {
            revert CcipUnauthorizedPeer(message_.sourceChainSelector, sender);
        }
        processedCcipMessage[message_.messageId] = true;
        _handleCcipMessage(srcChainId, message_);
        emit CcipMessageReceived(message_.messageId, srcChainId, sender);
    }

    function _handleCcipMessage(uint256 srcChainId_, CcipClient.Any2EVMMessage memory message_) internal virtual;
}
