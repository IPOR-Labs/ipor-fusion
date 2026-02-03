// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IDolomiteMargin interface for Dolomite Margin protocol
/// @notice Core interface for interacting with Dolomite Margin
interface IDolomiteMargin {
    // ============ Enums ============

    /// @notice Action types for operate()
    enum ActionType {
        Deposit, // 0: supply tokens
        Withdraw, // 1: borrow tokens (can create negative balance)
        Transfer, // 2: transfer balance between accounts
        Buy, // 3: buy tokens externally
        Sell, // 4: sell tokens externally
        Trade, // 5: trade with another account
        Liquidate, // 6: liquidate undercollateralized account
        Vaporize, // 7: use excess tokens to zero-out negative account
        Call // 8: send arbitrary data
    }

    /// @notice How the asset amount is denominated
    enum AssetDenomination {
        Wei, // actual token amount
        Par // principal/normalized amount
    }

    /// @notice How the amount is interpreted
    enum AssetReference {
        Delta, // relative to current value
        Target // absolute target value
    }

    // ============ Structs ============

    /// @notice Represents a unique account in Dolomite
    struct AccountInfo {
        /// @dev Owner address of the account
        address owner;
        /// @dev Sub-account number (0 = default)
        uint256 number;
    }

    /// @notice Represents a signed value (positive for supply, negative for borrow)
    struct Wei {
        /// @dev true = positive (supply), false = negative (borrow)
        bool sign;
        /// @dev Absolute value of the balance, In Dolomite, Wei.value has as many decimals as the given token has (native decimals).
        uint256 value;
    }

    /// @notice Represents a normalized value for internal accounting
    struct Par {
        /// @dev true = positive, false = negative
        bool sign;
        /// @dev Absolute value of the normalized balance
        uint128 value;
    }

    /// @notice Asset amount specification for actions
    struct AssetAmount {
        /// @dev true = positive, false = negative
        bool sign;
        /// @dev Wei or Par denomination
        AssetDenomination denomination;
        /// @dev Delta or Target reference
        AssetReference ref;
        /// @dev The amount value
        uint256 value;
    }

    /// @notice Arguments for a single action in operate()
    struct ActionArgs {
        ActionType actionType;
        uint256 accountId;
        AssetAmount amount;
        uint256 primaryMarketId;
        uint256 secondaryMarketId;
        address otherAddress;
        uint256 otherAccountId;
        bytes data;
    }

    /// @notice Interest rate index for a market
    struct Index {
        /// @dev Borrow index (scaled by 1e18)
        uint96 borrow;
        /// @dev Supply index (scaled by 1e18)
        uint96 supply;
        /// @dev Last update timestamp
        uint32 lastUpdate;
    }

    /// @notice Price of an asset
    struct Price {
        /// @dev Price value (scaled by 1e36 / baseUnit)
        uint256 value;
    }

    // ============ Getter Functions ============

    /// @notice Get the Wei balance for an account in a market
    /// @param account The account to query
    /// @param marketId The market ID
    /// @return The Wei balance (signed)
    function getAccountWei(AccountInfo calldata account, uint256 marketId) external view returns (Wei memory);

    /// @notice Get the Par balance for an account in a market
    /// @param account The account to query
    /// @param marketId The market ID
    /// @return The Par balance (signed)
    function getAccountPar(AccountInfo calldata account, uint256 marketId) external view returns (Par memory);

    /// @notice Get the current price of a market's token
    /// @param marketId The market ID
    /// @return The price struct
    function getMarketPrice(uint256 marketId) external view returns (Price memory);

    /// @notice Get the market ID for a token address
    /// @param token The token address
    /// @return The market ID
    function getMarketIdByTokenAddress(address token) external view returns (uint256);

    /// @notice Get the token address for a market ID
    /// @param marketId The market ID
    /// @return The token address
    function getMarketTokenAddress(uint256 marketId) external view returns (address);

    /// @notice Get the total number of markets
    /// @return The number of markets
    function getNumMarkets() external view returns (uint256);

    /// @notice Get the current index for a market
    /// @param marketId The market ID
    /// @return The index struct
    function getMarketCurrentIndex(uint256 marketId) external view returns (Index memory);

    /// @notice Check if a market ID is valid
    /// @param marketId The market ID to check
    /// @return True if valid
    function getMarketIsClosing(uint256 marketId) external view returns (bool);

    /// @notice Get the margin premium for a market
    /// @param marketId The market ID
    /// @return The margin premium (scaled by 1e18)
    function getMarketMarginPremium(uint256 marketId) external view returns (uint256);

    // ============ Write Functions ============

    /// @notice The main entry-point to DolomiteMargin for managing accounts
    /// @dev Take one or more actions on one or more accounts
    /// @param accounts List of accounts that will be used in this operation
    /// @param actions Ordered list of actions to take
    function operate(AccountInfo[] calldata accounts, ActionArgs[] calldata actions) external;
}
