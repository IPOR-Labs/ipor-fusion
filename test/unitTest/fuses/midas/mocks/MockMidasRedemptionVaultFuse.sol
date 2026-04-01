// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasRedemptionVault} from "contracts/fuses/midas/ext/IMidasRedemptionVault.sol";

/// @title MockMidasRedemptionVaultFuse
/// @notice Mock implementation of IMidasRedemptionVault for testing MidasRequestSupplyFuse.
///         Supports configurable requestId return value and redeemRequests responses.
contract MockMidasRedemptionVaultFuse is IMidasRedemptionVault {
    /// @dev The requestId returned by redeemRequest()
    uint256 public nextRequestId;

    /// @dev Mapping from requestId to its Request struct
    mapping(uint256 => Request) public redeemRequestsMap;

    /// @dev Track last redeemRequest call
    address public lastTokenOut;
    uint256 public lastAmountMToken;

    constructor(uint256 nextRequestId_) {
        nextRequestId = nextRequestId_;
    }

    /// @notice Set the requestId to return on next redeemRequest() call
    function setNextRequestId(uint256 requestId_) external {
        nextRequestId = requestId_;
    }

    /// @notice Configure a redeemRequest response for a given requestId
    function setRedeemRequest(uint256 requestId_, address sender_, address tokenOut_, uint8 status_) external {
        redeemRequestsMap[requestId_] = Request({
            sender: sender_,
            tokenOut: tokenOut_,
            status: status_,
            amountMToken: 0,
            mTokenRate: 0,
            tokenOutRate: 0
        });
    }

    /// @notice Set request status directly (for updating existing requests)
    function setRequestStatus(uint256 requestId_, uint8 status_) external {
        redeemRequestsMap[requestId_].status = status_;
    }

    function redeemInstant(address, uint256, uint256) external pure override {
        revert("MockMidasRedemptionVaultFuse: not implemented");
    }

    function redeemRequest(address tokenOut, uint256 amountMTokenIn) external override returns (uint256 requestId) {
        lastTokenOut = tokenOut;
        lastAmountMToken = amountMTokenIn;
        requestId = nextRequestId;
        redeemRequestsMap[requestId] = Request({
            sender: msg.sender,
            tokenOut: tokenOut,
            status: 0,
            amountMToken: amountMTokenIn,
            mTokenRate: 1e18,
            tokenOutRate: 1e18
        });
    }

    function redeemRequests(uint256 requestId) external view override returns (Request memory) {
        return redeemRequestsMap[requestId];
    }

    function mToken() external pure override returns (address) {
        return address(0);
    }
}
