// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IDepositWithdrawalRouter interface for Dolomite deposit/withdraw operations
/// @notice Router interface for simplified deposit and withdrawal operations
interface IDepositWithdrawalRouter {
    /// @notice Event flag for tracking operation type
    enum EventFlag {
        None,
        Borrow
    }

    /// @notice Balance check flag for withdrawals
    enum BalanceCheckFlag {
        None,
        Both,
        From,
        To
    }

    /// @notice Deposit Wei (actual token amount) to Dolomite
    /// @param isolationModeMarketId Market ID for isolation mode (0 if not in isolation mode)
    /// @param toAccountNumber Sub-account number to deposit to
    /// @param marketId Market ID of the token to deposit
    /// @param amountWei Amount of tokens to deposit (in Wei)
    /// @param eventFlag Event flag for tracking
    function depositWei(
        uint256 isolationModeMarketId,
        uint256 toAccountNumber,
        uint256 marketId,
        uint256 amountWei,
        EventFlag eventFlag
    ) external;

    /// @notice Deposit Par (normalized amount) to Dolomite
    /// @param isolationModeMarketId Market ID for isolation mode (0 if not in isolation mode)
    /// @param toAccountNumber Sub-account number to deposit to
    /// @param marketId Market ID of the token to deposit
    /// @param amountPar Amount of tokens to deposit (in Par)
    /// @param eventFlag Event flag for tracking
    function depositPar(
        uint256 isolationModeMarketId,
        uint256 toAccountNumber,
        uint256 marketId,
        uint256 amountPar,
        EventFlag eventFlag
    ) external;

    /// @notice Withdraw Wei (actual token amount) from Dolomite
    /// @param isolationModeMarketId Market ID for isolation mode (0 if not in isolation mode)
    /// @param fromAccountNumber Sub-account number to withdraw from
    /// @param marketId Market ID of the token to withdraw
    /// @param amountWei Amount of tokens to withdraw (in Wei)
    /// @param balanceCheckFlag Balance check flag
    function withdrawWei(
        uint256 isolationModeMarketId,
        uint256 fromAccountNumber,
        uint256 marketId,
        uint256 amountWei,
        BalanceCheckFlag balanceCheckFlag
    ) external;

    /// @notice Withdraw Par (normalized amount) from Dolomite
    /// @param isolationModeMarketId Market ID for isolation mode (0 if not in isolation mode)
    /// @param fromAccountNumber Sub-account number to withdraw from
    /// @param marketId Market ID of the token to withdraw
    /// @param amountPar Amount of tokens to withdraw (in Par)
    /// @param balanceCheckFlag Balance check flag
    function withdrawPar(
        uint256 isolationModeMarketId,
        uint256 fromAccountNumber,
        uint256 marketId,
        uint256 amountPar,
        BalanceCheckFlag balanceCheckFlag
    ) external;

    /// @notice Get the Dolomite Margin contract address
    /// @return The DolomiteMargin address
    function DOLOMITE_MARGIN() external view returns (address);
}
