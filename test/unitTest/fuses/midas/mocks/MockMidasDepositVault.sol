// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasDepositVault} from "contracts/fuses/midas/ext/IMidasDepositVault.sol";

/// @title MockMidasDepositVault
/// @notice Mock implementation of IMidasDepositVault for testing MidasRequestSupplyFuse.
///         Supports configurable requestId return value and mintRequests responses.
contract MockMidasDepositVault is IMidasDepositVault {
    /// @dev The requestId returned by depositRequest()
    uint256 public nextRequestId;

    /// @dev Mapping from requestId to its Request struct
    mapping(uint256 => Request) public mintRequestsMap;

    /// @dev Track last depositRequest call
    address public lastTokenIn;
    uint256 public lastAmountToken;
    bytes32 public lastReferrerId;

    constructor(uint256 nextRequestId_) {
        nextRequestId = nextRequestId_;
    }

    /// @notice Set the requestId to return on next depositRequest() call
    function setNextRequestId(uint256 requestId_) external {
        nextRequestId = requestId_;
    }

    /// @notice Configure a mintRequest response for a given requestId
    function setMintRequest(uint256 requestId_, address sender_, address tokenIn_, uint8 status_) external {
        mintRequestsMap[requestId_] = Request({
            sender: sender_,
            tokenIn: tokenIn_,
            status: status_,
            depositedUsdAmount: 0,
            usdAmountWithoutFees: 0,
            tokenOutRate: 0
        });
    }

    /// @notice Set request status directly (for updating existing requests)
    function setRequestStatus(uint256 requestId_, uint8 status_) external {
        mintRequestsMap[requestId_].status = status_;
    }

    function depositInstant(address, uint256, uint256, bytes32) external pure override {
        revert("MockMidasDepositVault: not implemented");
    }

    function depositRequest(address tokenIn, uint256 amountToken, bytes32 referrerId) external override returns (uint256 requestId) {
        lastTokenIn = tokenIn;
        lastAmountToken = amountToken;
        lastReferrerId = referrerId;
        requestId = nextRequestId;
        mintRequestsMap[requestId] = Request({
            sender: msg.sender,
            tokenIn: tokenIn,
            status: 0,
            depositedUsdAmount: amountToken,
            usdAmountWithoutFees: amountToken,
            tokenOutRate: 1e18
        });
    }

    function mintRequests(uint256 requestId) external view override returns (Request memory) {
        return mintRequestsMap[requestId];
    }

    function mToken() external pure override returns (address) {
        return address(0);
    }

    function mTokenDataFeed() external pure override returns (address) {
        return address(0);
    }
}
