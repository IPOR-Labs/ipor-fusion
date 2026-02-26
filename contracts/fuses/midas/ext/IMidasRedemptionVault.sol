// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IMidasRedemptionVault
/// @notice Interface for Midas Redemption Vault supporting instant and async redemption operations
interface IMidasRedemptionVault {
    /// @notice Midas redemption request struct
    struct Request {
        address sender;
        address tokenOut;
        uint8 status; // 0=Pending, 1=Processed, 2=Canceled
        uint256 amountMToken;
        uint256 mTokenRate;
        uint256 tokenOutRate;
    }

    /// @notice Instant redeem - redeems mTokens for stablecoin immediately
    /// @param tokenOut Address of the output token (e.g., USDC)
    /// @param amountMTokenIn Amount of mTokens to redeem (decimals 18)
    /// @param minReceiveAmount Minimum expected tokenOut to receive (slippage protection)
    function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) external;

    /// @notice Request redeem - creates async redemption request (1-7 days)
    /// @dev Admin calls approveRequest() to fulfill - output tokens are sent directly to caller
    /// @param tokenOut Address of the output token (e.g., USDC)
    /// @param amountMTokenIn Amount of mTokens to redeem (decimals 18)
    /// @return requestId Unique ID for tracking the redemption request
    function redeemRequest(address tokenOut, uint256 amountMTokenIn) external returns (uint256 requestId);

    /// @notice Get redemption request details by ID
    /// @param requestId The ID of the redemption request
    /// @return The Request struct with redemption details
    function redeemRequests(uint256 requestId) external view returns (Request memory);

    /// @notice Get the mToken address associated with this vault
    /// @return The mToken contract address
    function mToken() external view returns (address);
}
