// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IMidasRedemptionVaultLimits
/// @notice Read-only views of a Midas redemption vault used to size an instant redemption
/// @dev Kept apart from IMidasRedemptionVault so that its mocks keep compiling
interface IMidasRedemptionVaultLimits {
    /// @notice mToken price feed of the vault (`getDataInBase18`: USD per mToken, 18 decimals)
    function mTokenDataFeed() external view returns (address);

    /// @notice Instant redemption limit per day, in mTokens (18 decimals)
    function instantDailyLimit() external view returns (uint256);

    /// @notice mTokens redeemed instantly on `day` (`block.timestamp / 1 days`)
    function dailyLimits(uint256 day) external view returns (uint256);

    /// @notice Minimum mToken amount of one redemption (18 decimals)
    function minAmount() external view returns (uint256);

    /// @notice Instant redemption fee, in basis points of 100_00
    function instantFee() external view returns (uint256);

    /// @notice Payment token config: price feed, fee (basis points of 100_00), remaining allowance (18 decimals) and
    ///         the stable flag (a stable token is priced at 1e18)
    function tokensConfig(
        address token
    ) external view returns (address dataFeed, uint256 fee, uint256 allowance, bool stable);
}
