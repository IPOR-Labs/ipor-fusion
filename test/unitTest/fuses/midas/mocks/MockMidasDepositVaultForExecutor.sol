// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasDepositVault} from "contracts/fuses/midas/ext/IMidasDepositVault.sol";

/// @title MockMidasDepositVaultForExecutor
/// @notice Minimal mock implementing IMidasDepositVault.depositRequest for MidasExecutor unit tests.
///         Records call arguments (including referrerId and call count) and returns a configurable requestId.
contract MockMidasDepositVaultForExecutor is IMidasDepositVault {
    uint256 public nextRequestId;

    // Last recorded call arguments
    address public lastTokenIn;
    uint256 public lastAmountToken;
    bytes32 public lastReferrerId;

    // Call count tracking
    uint256 public depositRequestCallCount;

    constructor(uint256 nextRequestId_) {
        nextRequestId = nextRequestId_;
    }

    function setNextRequestId(uint256 id) external {
        nextRequestId = id;
    }

    function depositRequest(
        address tokenIn,
        uint256 amountToken,
        bytes32 referrerId
    ) external override returns (uint256 requestId) {
        lastTokenIn = tokenIn;
        lastAmountToken = amountToken;
        lastReferrerId = referrerId;
        depositRequestCallCount++;
        return nextRequestId;
    }

    // ---- Unused interface methods (must compile) ----

    function depositInstant(
        address, /* tokenIn */
        uint256, /* amountToken */
        uint256, /* minReceiveAmount */
        bytes32 /* referrerId */
    ) external pure override {
        revert("MockMidasDepositVaultForExecutor: not implemented");
    }

    function mintRequests(uint256 /* requestId */ ) external pure override returns (Request memory) {
        revert("MockMidasDepositVaultForExecutor: not implemented");
    }

    function mToken() external pure override returns (address) {
        return address(0);
    }

    function mTokenDataFeed() external pure override returns (address) {
        return address(0);
    }
}
