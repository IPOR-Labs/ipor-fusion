// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @title IAaveV4Spoke
/// @notice Subset of the Aave V4 ISpoke interface used by the IPOR Fusion fuses and tests.
///         Aligned with aave/aave-v4 src/spoke/interfaces/ISpoke.sol (struct layouts are identical).
/// @dev Spoke contracts are the user-facing entry point of the Hub & Spoke architecture. Each Spoke has its
///      own risk configuration, oracle and reserve list; reserves are indexed sequentially from 0 and are
///      append-only. Positions are tracked per (Spoke, reserveId) with share-based accounting.
///      Callers act for themselves (`onBehalfOf == msg.sender`) or as an approved position manager.
///      Aave V4 has no E-Mode; supply does NOT enable collateral (see setUsingAsCollateral).
interface IAaveV4Spoke {
    // ============ Structs ============

    /// @notice Reserve level data
    /// @dev underlying The address of the underlying asset
    /// @dev hub The address of the associated Hub (IHubBase)
    /// @dev assetId The identifier of the asset in the Hub
    /// @dev decimals The number of decimals of the underlying asset
    /// @dev collateralRisk The risk associated with a collateral asset, expressed in BPS
    /// @dev flags Packed reserve flags (uint8): paused 0x01, frozen 0x02, borrowable 0x04, receiveSharesEnabled 0x08
    /// @dev dynamicConfigKey The key of the last reserve dynamic config
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    /// @notice Reserve configuration (subset of Reserve, flags unpacked)
    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    /// @notice Dynamic reserve configuration data
    /// @dev collateralFactor Proportion of the reserve value usable as collateral, in BPS
    /// @dev maxLiquidationBonus Maximum liquidation bonus, in BPS (100_00 = 0.00% bonus)
    /// @dev liquidationFee Protocol fee on liquidations, in BPS
    struct DynamicReserveConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    /// @notice User position data per reserve
    struct UserPosition {
        uint120 drawnShares;
        uint120 premiumShares;
        int200 premiumOffsetRay;
        uint120 suppliedShares;
        uint32 dynamicConfigKey;
    }

    /// @notice User account data describing a user position and its health
    /// @dev healthFactor expressed in WAD, 1e18 == 1.00; totalDebtValueRay scaled by RAY
    struct UserAccountData {
        uint256 riskPremium;
        uint256 avgCollateralFactor;
        uint256 healthFactor;
        uint256 totalCollateralValue;
        uint256 totalDebtValueRay;
        uint256 activeCollateralCount;
        uint256 borrowCount;
    }

    // ============ Errors (subset, for tests) ============

    /// @notice Thrown when an action causes a user's health factor to fall below the liquidation threshold
    error HealthFactorBelowThreshold();
    /// @notice Thrown when a reserve is paused during an attempted action
    error ReservePaused();
    /// @notice Thrown when a reserve is frozen (supply, borrow, enabling collateral)
    error ReserveFrozen();
    /// @notice Thrown when a reserve is not borrowable during a borrow action
    error ReserveNotBorrowable();
    /// @notice Thrown when a reserve is not listed
    error ReserveNotListed();
    /// @notice Thrown when an unauthorized caller attempts an action
    error Unauthorized();
    /// @notice Thrown when user attempts to exceed the maximum allowed collateral or borrowed reserves
    error MaximumUserReservesExceeded();

    // ============ Supply / Withdraw ============

    /// @notice Supplies assets into the Spoke's reserve. The Spoke pulls the tokens from the caller.
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to supply
    /// @param onBehalfOf The owner of the position to add supply shares to
    /// @return shares The amount of supply shares minted
    /// @return suppliedAmount The amount of underlying assets supplied
    function supply(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 shares, uint256 suppliedAmount);

    /// @notice Withdraws assets from the Spoke's reserve. The caller receives the withdrawn tokens.
    /// @dev An amount greater than the maximum withdrawable value signals a full withdrawal
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to withdraw
    /// @param onBehalfOf The owner of the position to remove supply shares from
    /// @return withdrawnShares The amount of supply shares burned
    /// @return withdrawnAmount The amount of underlying tokens withdrawn
    function withdraw(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 withdrawnShares, uint256 withdrawnAmount);

    // ============ Borrow / Repay ============

    /// @notice Borrows assets from the Spoke's reserve. The caller receives the borrowed tokens.
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to borrow
    /// @param onBehalfOf The owner of the position against which debt is generated
    /// @return shares The amount of drawn (debt) shares created
    /// @return borrowedAmount The amount of underlying assets borrowed
    function borrow(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 shares, uint256 borrowedAmount);

    /// @notice Repays borrowed assets to the Spoke's reserve. The Spoke pulls the tokens from the caller.
    /// @dev Repayment is capped at the user's total debt; the pulled amount never exceeds `amount`
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to repay
    /// @param onBehalfOf The owner of the position whose debt is repaid
    /// @return repaidShares The amount of drawn shares burned
    /// @return repaidAmount The amount of underlying tokens repaid (drawn + premium)
    function repay(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 repaidShares, uint256 repaidAmount);

    // ============ Collateral ============

    /// @notice Enables or disables a supplied reserve as collateral of `onBehalfOf`
    /// @dev Disabling is health-factor checked (reverts HealthFactorBelowThreshold). Enabling reverts when
    ///      the reserve is paused/frozen. No-op if the flag already has the requested value.
    /// @param reserveId The reserve identifier within this Spoke
    /// @param usingAsCollateral True to use the supply as collateral
    /// @param onBehalfOf The owner of the position being modified
    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external;

    // ============ User Position Queries ============

    /// @notice Returns the amount of supply shares held by a user for a given reserve
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Returns the amount of supplied assets of a user for a given reserve (shares converted to assets)
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Returns the debt of a user for a given reserve
    /// @return drawnDebt The drawn debt in asset units
    /// @return premiumDebt The premium debt in asset units (rounded up)
    function getUserDebt(
        uint256 reserveId,
        address user
    ) external view returns (uint256 drawnDebt, uint256 premiumDebt);

    /// @notice Returns the total debt of a user for a given reserve (drawn + premium, rounded up)
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Returns the raw user position struct for a given reserve
    function getUserPosition(uint256 reserveId, address user) external view returns (UserPosition memory);

    /// @notice Returns whether the reserve is enabled as collateral and whether it is borrowed by the user
    /// @return usingAsCollateral True if the reserve is enabled as collateral by the user
    /// @return borrowing True if the reserve is borrowed by the user
    function getUserReserveStatus(
        uint256 reserveId,
        address user
    ) external view returns (bool usingAsCollateral, bool borrowing);

    /// @notice Returns the most up-to-date account data (health factor, collateral/debt values) of a user
    function getUserAccountData(address user) external view returns (UserAccountData memory);

    // ============ Reserve Queries ============

    /// @notice Returns the number of listed reserves on the Spoke
    function getReserveCount() external view returns (uint256);

    /// @notice Returns the reserve struct data
    /// @dev Reverts ReserveNotListed for an unknown reserve id
    function getReserve(uint256 reserveId) external view returns (Reserve memory);

    /// @notice Returns the reserve configuration (flags unpacked)
    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory);

    /// @notice Returns the dynamic reserve configuration at the specified key
    function getDynamicReserveConfig(
        uint256 reserveId,
        uint32 dynamicConfigKey
    ) external view returns (DynamicReserveConfig memory);

    /// @notice Returns the reserve identifier for a given asset of a Hub
    /// @dev Reverts ReserveNotListed if no reserve is associated with the (hub, assetId) pair
    function getReserveId(address hub, uint256 assetId) external view returns (uint256);

    /// @notice Returns the total amount of supplied assets of a given reserve
    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256);

    /// @notice Returns the total debt of a given reserve (drawn + premium)
    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256);

    // ============ Immutables ============

    /// @notice Returns the address of the AaveOracle contract of this Spoke
    // solhint-disable-next-line func-name-mixedcase
    function ORACLE() external view returns (address);

    /// @notice Returns the maximum allowed number of collateral and borrow reserves per user (each counted separately)
    // solhint-disable-next-line func-name-mixedcase
    function MAX_USER_RESERVES_LIMIT() external view returns (uint16);
}
