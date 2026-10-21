// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipRouteConfig} from "../interfaces/ICcipCrosschain.sol";
import {ICcipRouterClient} from "../interfaces/CcipClient.sol";

/// @title CcipRouteLib
/// @notice Registers immutable CCIP route identities and updates their timelocked delivery policy.
/// @dev This is an external linked library to keep every `CcipAppBase` consumer below EIP-170. It
///      operates on the caller's storage through delegatecall. A route's `(chainSelector, peer)` pair
///      is an authentication boundary and can never change after registration; fee token, gas limits,
///      fee ceiling and enabled state are operational policy and may be replaced by an authorized caller.
library CcipRouteLib {
    error CcipZeroAddress();
    error CcipRouteAlreadyRegistered(uint256 chainId, uint64 selector);
    error CcipUnknownChain(uint256 chainId);
    error CcipRouteIdentityMismatch(
        uint256 chainId, uint64 expectedSelector, uint64 suppliedSelector, address expectedPeer, address suppliedPeer
    );
    error CcipUnsupportedSelector(uint64 selector);
    error CcipRouteGasPolicyUnset(uint256 chainId);

    event CcipRouteRegistered(uint256 chainId, uint64 selector, address peer);
    /// @notice Carries the full new route config (selector, peer, fee token, gas limits, fee ceiling, enabled), so
    ///         disabling a lane (`enabled = false`) or changing a fee or gas cap is visible in plain values.
    event CcipRoutePolicyUpdated(uint256 chainId, CcipRouteConfig route);

    function setRoute(
        mapping(uint256 chainId => CcipRouteConfig route) storage routes_,
        mapping(uint64 selector => uint256 chainId) storage selectorToChain_,
        address router_,
        uint256 chainId_,
        CcipRouteConfig memory route_
    ) public {
        if (route_.enabled && (route_.messageGasLimit == 0 || route_.tokenGasLimit == 0)) {
            revert CcipRouteGasPolicyUnset(chainId_);
        }
        CcipRouteConfig storage current = routes_[chainId_];
        if (current.chainSelector == 0) {
            if (chainId_ == 0 || route_.chainSelector == 0 || route_.peer == address(0)) revert CcipZeroAddress();
            if (!ICcipRouterClient(router_).isChainSupported(route_.chainSelector)) {
                revert CcipUnsupportedSelector(route_.chainSelector);
            }
            if (selectorToChain_[route_.chainSelector] != 0) {
                revert CcipRouteAlreadyRegistered(chainId_, route_.chainSelector);
            }
            routes_[chainId_] = route_;
            selectorToChain_[route_.chainSelector] = chainId_;
            emit CcipRouteRegistered(chainId_, route_.chainSelector, route_.peer);
            emit CcipRoutePolicyUpdated(chainId_, route_);
            return;
        }

        if (current.chainSelector != route_.chainSelector || current.peer != route_.peer) {
            revert CcipRouteIdentityMismatch(
                chainId_, current.chainSelector, route_.chainSelector, current.peer, route_.peer
            );
        }

        routes_[chainId_] = route_;
        emit CcipRoutePolicyUpdated(chainId_, current);
    }

    function updatePolicy(
        mapping(uint256 chainId => CcipRouteConfig route) storage routes_,
        uint256 chainId_,
        address feeToken_,
        uint256 gasLimitsAndFlags_,
        uint256 maxFee_
    ) public {
        CcipRouteConfig storage current = routes_[chainId_];
        if (current.chainSelector == 0) revert CcipUnknownChain(chainId_);
        bool enabled = gasLimitsAndFlags_ >> 192 & 1 != 0;
        if (enabled && (uint96(gasLimitsAndFlags_) == 0 || uint96(gasLimitsAndFlags_ >> 96) == 0)) {
            revert CcipRouteGasPolicyUnset(chainId_);
        }
        current.feeToken = feeToken_;
        current.messageGasLimit = uint96(gasLimitsAndFlags_);
        current.tokenGasLimit = uint96(gasLimitsAndFlags_ >> 96);
        current.maxFee = maxFee_;
        current.enabled = enabled;
        emit CcipRoutePolicyUpdated(chainId_, current);
    }
}
