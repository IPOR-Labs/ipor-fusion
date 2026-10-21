// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ICoreDepositWallet
/// @author IPOR Labs
/// @notice Minimal interface for Hyperliquid/Circle's CoreDepositWallet contract. HyperCore token 0
///         (USDC) routes EVM -> Core deposits through this contract on every network where USDC is
///         CCTP-native: `tokenInfo(0).evmContract` is this wallet's (TransparentUpgradeableProxy)
///         address, NOT the USDC ERC20 itself. `token()` returns the real underlying native USDC
///         ERC20 address. Sending USDC to the token's derived system address by plain ERC20
///         transfer credits nothing on HyperCore for this token; `deposit`/`depositFor` must be used
///         instead. Other HyperCore-linked tokens (e.g. USDT0) are plain ERC20s and are unaffected.
interface ICoreDepositWallet {
    /// @notice The underlying native ERC20 token this wallet accepts and forwards to HyperCore
    function token() external view returns (address);

    /// @notice Whether deposits into this wallet are currently paused
    function paused() external view returns (bool);

    /// @notice Deposits `amount` of `token()` from the caller, crediting the caller on HyperCore's `destinationDex`
    function deposit(uint256 amount, uint32 destinationDex) external;

    /// @notice Deposits `amount` of `token()` from the caller, crediting `recipient` on HyperCore's `destinationDex`
    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external;
}
