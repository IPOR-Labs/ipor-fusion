// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IAguaGlobalCarryVault
/// @notice Minimal interface to Reservoir's Agua Global Carry Vault (`aguaUSDCgc`).
/// @dev The Agua vault is an ERC-4626-shaped vault whose deposit is synchronous and
///      4626-compliant, but whose exit is asynchronous (request -> complete) with an
///      optional instant `redeemEarly` path that charges a fee. The contract is its own
///      ERC-4626 share token (vault address == share token address).
interface IAguaGlobalCarryVault {
    /// @notice Underlying asset of the vault (e.g. USDC)
    /// @return The underlying asset token address
    function asset() external view returns (address);

    /// @notice Number of decimals of the vault share token
    /// @return The share token decimals
    function decimals() external view returns (uint8);

    /// @notice Synchronous, 4626-compliant deposit of underlying assets
    /// @param assets Amount of underlying assets to deposit
    /// @param receiver Address receiving the minted shares
    /// @return shares Amount of shares minted to the receiver
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Maximum amount of underlying assets that can currently be deposited (honors the cap)
    /// @param receiver Address that would receive the shares
    /// @return The maximum depositable amount of underlying assets
    function maxDeposit(address receiver) external view returns (uint256);

    /// @notice Share balance of an account
    /// @param account Account to query
    /// @return The share balance of the account
    function balanceOf(address account) external view returns (uint256);

    /// @notice Convert a share amount to its current underlying asset value (live NAV)
    /// @param shares Amount of shares to convert
    /// @return The equivalent amount of underlying assets
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Request an asynchronous redemption, escrowing `shares` out of the holder balance
    /// @dev Only one active request per holder is allowed.
    /// @param shares Amount of shares to redeem
    function requestRedemption(uint256 shares) external;

    /// @notice Complete an unlocked redemption request, burning escrowed shares and paying the receiver
    /// @dev Callable only after the request unlock time; payout uses the frozen yield factor.
    /// @param receiver Address receiving the redeemed underlying assets
    /// @return assets Amount of underlying assets paid to the receiver
    function completeRedemption(address receiver) external returns (uint256 assets);

    /// @notice Cancel the active redemption request, returning escrowed shares to the holder
    function cancelRedemption() external;

    /// @notice Instantly redeem shares for underlying assets, charging the early redemption fee
    /// @param shares Amount of shares to redeem instantly
    /// @param receiver Address receiving the redeemed underlying assets
    /// @param minAssetsOut Minimum acceptable amount of underlying assets (slippage protection)
    /// @return assets Amount of underlying assets paid to the receiver
    function redeemEarly(uint256 shares, address receiver, uint256 minAssetsOut) external returns (uint256 assets);

    /// @notice Preview the frozen underlying payout of the holder's active redemption request
    /// @param user Holder to query
    /// @return assets Frozen underlying payout; 0 when there is no active request
    function previewCompleteRedemption(address user) external view returns (uint256 assets);

    /// @notice Read the holder's active redemption request
    /// @param user Holder to query
    /// @return shares Escrowed shares of the active request (0 when none)
    /// @return requestTime Timestamp the request was created
    /// @return unlockTime Timestamp the request becomes completable
    /// @return isUnlocked Whether the request is currently unlocked
    function getRedemptionRequest(
        address user
    ) external view returns (uint256 shares, uint256 requestTime, uint256 unlockTime, bool isUnlocked);
}
