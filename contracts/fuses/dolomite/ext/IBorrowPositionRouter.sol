// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IBorrowPositionRouter interface for Dolomite borrow position management
/// @notice Router interface for managing borrow positions in Dolomite
/// @dev Address on Arbitrum: 0xF579b345cdA0860668b857De10ABD62442133D0F
interface IBorrowPositionRouter {
    /// @notice Opens a borrow position by borrowing tokens
    /// @param fromAccountNumber The account number from which to borrow (must have collateral)
    /// @param toAccountNumber The account number to receive borrowed tokens
    /// @param marketId The market ID of the token to borrow
    /// @param amountWei The amount to borrow in Wei
    function openBorrowPosition(
        uint256 fromAccountNumber,
        uint256 toAccountNumber,
        uint256 marketId,
        uint256 amountWei
    ) external;

    /// @notice Closes a borrow position by repaying borrowed tokens
    /// @param borrowAccountNumber The account number holding the debt
    /// @param toAccountNumber The account number to return collateral to
    /// @param marketIds Array of market IDs to repay
    function closeBorrowPosition(
        uint256 borrowAccountNumber,
        uint256 toAccountNumber,
        uint256[] calldata marketIds
    ) external;

    /// @notice Transfers tokens between accounts (can create debt if withdrawing more than balance)
    /// @param fromAccountNumber Source account number
    /// @param toAccountNumber Destination account number
    /// @param marketId Market ID of the token
    /// @param amountWei Amount to transfer in Wei
    /// @param balanceCheckFlag Flag for balance checking (0 = None, 1 = Both, 2 = From, 3 = To)
    function transferBetweenAccounts(
        uint256 fromAccountNumber,
        uint256 toAccountNumber,
        uint256 marketId,
        uint256 amountWei,
        uint8 balanceCheckFlag
    ) external;

    /// @notice Repays a borrow by depositing tokens
    /// @param accountNumber The account number to repay
    /// @param marketId The market ID of the token to repay
    /// @param amountWei The amount to repay in Wei (use type(uint256).max for full repay)
    function repayBorrow(uint256 accountNumber, uint256 marketId, uint256 amountWei) external;

    /// @notice Get the Dolomite Margin contract address
    /// @return The DolomiteMargin address
    function DOLOMITE_MARGIN() external view returns (address);
}
