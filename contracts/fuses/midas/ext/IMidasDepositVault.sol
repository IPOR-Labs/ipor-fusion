// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IMidasDepositVault
/// @notice Interface for Midas Deposit Vault supporting instant and async deposit operations
interface IMidasDepositVault {
    /// @notice Midas deposit request struct
    struct Request {
        address sender;
        address tokenIn;
        uint8 status; // 0=Pending, 1=Processed, 2=Canceled
        uint256 depositedUsdAmount;
        uint256 usdAmountWithoutFees;
        uint256 tokenOutRate;
    }

    /// @notice Instant deposit - mints mTokens immediately
    /// @param tokenIn Address of the deposit token (e.g., USDC)
    /// @param amountToken Amount of tokenIn to deposit (decimals 18)
    /// @param minReceiveAmount Minimum expected mTokens to receive (slippage protection)
    /// @param referrerId Referrer identifier (can be bytes32(0) if none)
    function depositInstant(
        address tokenIn,
        uint256 amountToken,
        uint256 minReceiveAmount,
        bytes32 referrerId
    ) external;

    /// @notice Request deposit - creates async mint request (1-7 days)
    /// @dev Admin calls approveRequest() to fulfill - mTokens are minted directly to caller
    /// @param tokenIn Address of the deposit token (e.g., USDC)
    /// @param amountToken Amount of tokenIn to deposit (decimals 18)
    /// @param referrerId Referrer identifier (can be bytes32(0) if none)
    /// @return requestId Unique ID for tracking the mint request
    function depositRequest(address tokenIn, uint256 amountToken, bytes32 referrerId)
        external
        returns (uint256 requestId);

    /// @notice Get deposit request details by ID
    /// @param requestId The ID of the deposit request
    /// @return The Request struct with deposit details
    function mintRequests(uint256 requestId) external view returns (Request memory);

    /// @notice Get the mToken address associated with this vault
    /// @return The mToken contract address
    function mToken() external view returns (address);

    /// @notice Get the data feed contract for mToken pricing
    /// @return The IDataFeed contract address
    function mTokenDataFeed() external view returns (address);
}
