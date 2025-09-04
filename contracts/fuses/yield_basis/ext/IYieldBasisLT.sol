// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Interface for Yield Basis LT - Yield Bearing Token
interface IYieldBasisLT {
    function ASSET_TOKEN() external view returns (address);

    function balanceOf(address account) external view returns (uint256);

    function decimals() external view returns (uint8);

    /// @notice Method to deposit assets (e.g. like BTC) to receive shares (e.g. like yield-bearing BTC)
    /// @param assets Amount of assets to deposit
    /// @param debt Amount of debt for AMM to take (approximately BTC * btc_price)
    /// @param minShares Minimal amount of shares to receive (important to calculate to exclude sandwich attacks)
    /// @param receiver Receiver of the shares who is optional. If not specified - receiver is the sender
    /// @return uint256 Amount of shares received
    function deposit(
        uint256 assets,
        uint256 debt,
        uint256 minShares,
        address receiver
    ) external returns (uint256);


    /// @notice Method to withdraw assets (e.g. like BTC) by spending shares (e.g. like yield-bearing BTC)
    /// @param shares Shares to withdraw
    /// @param minAssets Minimal amount of assets to receive (important to calculate to exclude sandwich attacks)
    /// @param receiver Receiver of the assets who is optional. If not specified - receiver is the sender
    function withdraw(
        uint256 shares,
        uint256 minAssets,
        address receiver
    ) external returns (uint256);


    /// @notice Emergency withdraw method that allows withdrawing shares in case of emergency
    /// @param shares Amount of shares to withdraw
    /// @return uint256 Amount of assets received
    /// @return int256 Debt change
    function emergency_withdraw(
        uint256 shares
    ) external returns (uint256, int256);


    /// @notice Emergency withdraw method that allows withdrawing shares in case of emergency
    /// @param shares Amount of shares to withdraw
    /// @param receiver Address to receive the withdrawn assets
    /// @return uint256 Amount of assets received
    /// @return int256 Debt change
    function emergency_withdraw(
        uint256 shares,
        address receiver
    ) external returns (uint256, int256);

    
    /// @notice Emergency withdraw method that allows withdrawing shares in case of emergency
    /// @param shares Amount of shares to withdraw
    /// @param receiver Address to receive the withdrawn assets
    /// @param owner Owner of the shares
    /// @return uint256 Amount of assets received
    /// @return int256 Debt change
    function emergency_withdraw(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256, int256);

    

    function set_admin(address admin) external;

    /// @notice Returns the price per share of the LT in 18 decimals
    function pricePerShare() external view returns (uint256);
}