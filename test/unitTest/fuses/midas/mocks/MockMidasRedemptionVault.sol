// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasRedemptionVault} from "../../../../../contracts/fuses/midas/ext/IMidasRedemptionVault.sol";

/// @title MockMidasRedemptionVault
/// @notice Minimal mock implementing IMidasRedemptionVault.redeemRequest for MidasExecutor unit tests.
///         Records call arguments and returns a configurable requestId.
contract MockMidasRedemptionVault is IMidasRedemptionVault {
    uint256 public nextRequestId;

    // Last recorded call arguments
    address public lastTokenOut;
    uint256 public lastAmountMToken;

    // Call order tracking
    uint256 public redeemRequestCallCount;

    constructor(uint256 nextRequestId_) {
        nextRequestId = nextRequestId_;
    }

    function setNextRequestId(uint256 id) external {
        nextRequestId = id;
    }

    function redeemRequest(
        address tokenOut,
        uint256 amountMTokenIn
    ) external override returns (uint256 requestId) {
        lastTokenOut = tokenOut;
        lastAmountMToken = amountMTokenIn;
        redeemRequestCallCount++;
        return nextRequestId;
    }

    // ---- Unused interface methods (must compile) ----

    function redeemInstant(
        address, /* tokenOut */
        uint256, /* amountMTokenIn */
        uint256 /* minReceiveAmount */
    ) external pure override {
        revert("not used");
    }

    function redeemRequests(uint256 /* requestId */ ) external pure override returns (Request memory) {
        revert("not used");
    }

    function mToken() external pure override returns (address) {
        return address(0);
    }
}
