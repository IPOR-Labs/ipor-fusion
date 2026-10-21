// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title TrackedVaultPricingLib
/// @notice Failure-tolerant read of one tracked vault position (IL-8602). A faulty vault must not be able to revert
///         the dispatcher's aggregate valuation, which backs the observation view, on CCIP every response, and on
///         Stargate the `RETURN_STARTED` balance (IL-8606).
/// @dev Low-level `staticcall` rather than `try/catch`: a Solidity `try` does not catch a malformed return payload
///      (empty returndata from a code-less address, a short return), because the ABI decode runs in the caller.
///      Only the first 32 bytes of returndata are copied, so a returndata bomb costs nothing beyond the call.
///      Each read is capped at `VAULT_READ_GAS`, so a gas-burning vault (INVALID opcode, infinite loop) cannot leave
///      the caller with 1/64 of its gas. A pre-check reverts when the caller supplied too little gas to honour the
///      cap, so a failed read is always the vault's fault and a caller cannot starve a read (EIP-150) to force an
///      understatement. An honest read that needs more than its cap is reported unpriced (errs low and is
///      flagged); CCIP route gas limits need roughly this headroom per faulty vault.
///
///      Two budgets for `convertToAssets` (IL-8602 review, G-1). The attestation views (`observation()`, CCIP
///      `accountedBalance()`) run as eth_call and block nothing on-chain, so they give it `VIEW_CONVERT_GAS`, enough
///      for a multi-market aggregator: a MetaMorpho V1 vault costs about 40k gas per market cold, about 1.25M at its
///      30-market queue limit. The on-chain paths (CCIP responses, the Stargate recall) keep `VAULT_READ_GAS`: their
///      figure is evidence for attesters, and a gas-burning vault must not make every delivery heavy. `balanceOf` and
///      `asset()` use `VAULT_READ_GAS` on every path.
/// @author IPOR Labs
library TrackedVaultPricingLib {
    /// @dev Reason codes (2 bits each in the CCIP observation); 0 means priced.
    uint8 internal constant PRICED = 0;
    uint8 internal constant UNPRICED_BALANCE_OF = 1;
    uint8 internal constant UNPRICED_CONVERT_TO_ASSETS = 2;
    /// @dev The vault's `asset()` reverted, was malformed or no longer equals the dispatcher's ASSET (IL-8645).
    uint8 internal constant UNPRICED_ASSET_DRIFT = 3;

    /// @dev Gas forwarded to each vault read on the on-chain paths, and to `balanceOf` / `asset()` everywhere.
    uint256 internal constant VAULT_READ_GAS = 200_000;

    /// @dev Gas forwarded to `convertToAssets` in the attestation views (eth_call only). A MetaMorpho V1 vault loops
    ///      over its withdraw queue at about 40k gas per market cold, about 1.25M at its 30-market queue limit, so 2M
    ///      leaves headroom. The views run as eth_call and block nothing on-chain; a gas-burning vault costs a view at
    ///      most this much per vault, plus up to 2 x `VAULT_READ_GAS` on its `balanceOf` / `asset()` reads. Never used on a path that mutates state.
    uint256 internal constant VIEW_CONVERT_GAS = 2_000_000;

    /// @dev The caller supplied too little gas to give a vault read its cap (budget).
    error InsufficientGasForVaultRead();

    /// @notice `vault_.balanceOf(holder_)` as `(ok, shares)`; `ok == false` when the read reverted or was malformed.
    function shares(address vault_, address holder_) internal view returns (bool ok, uint256 amount) {
        return _staticUint(vault_, abi.encodeWithSelector(0x70a08231, holder_), VAULT_READ_GAS);
    }

    /// @notice `price` with the on-chain `convertToAssets` budget (`VAULT_READ_GAS`): for responses and the Stargate
    ///         recall, whose figure is evidence for attesters.
    function price(address vault_, address holder_, address asset_)
        internal
        view
        returns (uint256 assets, uint8 reason)
    {
        return price(vault_, holder_, asset_, VAULT_READ_GAS);
    }

    /// @notice Underlying value of `holder_`'s position in `vault_`; `reason != PRICED` when a read failed.
    /// @dev A zero share balance is worth zero without asking the vault to convert (and without the asset check: an
    ///      empty position carries no value that a drifted underlying could misprice). A held position is priced
    ///      only while `vault_.asset() == asset_` (IL-8645); otherwise `convertToAssets` would be denominated in
    ///      another token. That makes up to three capped reads per vault.
    /// @param convertGas_ Gas forwarded to `convertToAssets`: `VIEW_CONVERT_GAS` in the attestation views,
    ///        `VAULT_READ_GAS` on the on-chain paths.
    function price(
        address vault_,
        address holder_,
        address asset_,
        uint256 convertGas_
    ) internal view returns (uint256 assets, uint8 reason) {
        (bool ok, uint256 held) = shares(vault_, holder_);
        if (!ok) return (0, UNPRICED_BALANCE_OF);
        if (held == 0) return (0, PRICED);
        // asset()
        uint256 reported;
        (ok, reported) = _staticUint(vault_, abi.encodeWithSelector(0x38d52e0f), VAULT_READ_GAS);
        if (!ok || reported != uint256(uint160(asset_))) return (0, UNPRICED_ASSET_DRIFT);
        // convertToAssets(uint256)
        (ok, assets) = _staticUint(vault_, abi.encodeWithSelector(0x07a2d13a, held), convertGas_);
        if (!ok) return (0, UNPRICED_CONVERT_TO_ASSETS);
        return (assets, PRICED);
    }

    function _staticUint(address target_, bytes memory data_, uint256 gas_)
        private
        view
        returns (bool ok, uint256 value)
    {
        if (gasleft() < gas_ * 64 / 63 + 5_000) revert InsufficientGasForVaultRead();
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(gas_, target_, add(data_, 0x20), mload(data_), out, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            if ok {
                value := mload(out)
            }
        }
    }
}
