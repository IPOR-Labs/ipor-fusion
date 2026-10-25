// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";
import {ICrosschainExecutor} from "../../../crosschain/interfaces/ICrosschainExecutor.sol";
import {IPlasmaVault} from "../../../interfaces/IPlasmaVault.sol";
import {IPlasmaVaultGovernance} from "../../../interfaces/IPlasmaVaultGovernance.sol";
import {
    CrosschainSubstrateLib,
    CrosschainSubstrate,
    CrosschainSubstrateType
} from "../../../fuses/crosschain/lib/CrosschainSubstrateLib.sol";

/// @title CrosschainNavValidationPreHook
/// @notice Pre-execution hook that fail-closed-gates share-price-sensitive vault operations on the freshness
///         and non-blocked state of every whitelisted crosschain executor, Stargate or CCIP (plan §5.2).
/// @dev Runs via delegatecall from PlasmaVault. For each granted EXECUTOR substrate it calls the executor's
///      `getBalance()` and discards the result: `getBalance()` already REVERTS on staleness, a blocked chain
///      that still tracks value, or an in-flight record older than `TRANSFER_STALENESS_MAX`, so invoking it is
///      a sufficient gate.
///      It deliberately does NOT call `updateMarketsBalances` (no recursion, plan §5.2).
///
///      Wire this hook (by governance, at deploy time via `PlasmaVaultGovernance.setPreHookImplementations`)
///      to the source PlasmaVault selectors: `deposit`, `depositWithPermit`, `mint`, `withdraw`, `redeem`,
///      `redeemFromRequest` and `execute`. `execute` is intentionally delegated to fuse-level action gating
///      so approved recovery can run while new exposure cannot. `updateMarketsBalances` must NOT be wired:
///      the hook returns early for it, because gating it would freeze the refresh of every other market for
///      as long as one executor is fail-closed, while the CROSSCHAIN market itself already fails closed in
///      `CrosschainBalanceFuse`. Do not wire governance selectors either — a reverting hook on
///      `setPreHookImplementations` or `grantMarketSubstrates` locks governance out of its own repair path.
///      Public view methods (`totalAssets`, previews) remain cached and may be stale.
///
///      The gate exists ONLY in `run()` (state-changing selectors via `PlasmaVault._checkCanCall`). The vault's
///      `maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem`, `preview*` and `convertTo*` views are not gated: while
///      the gate is closed they keep returning values priced from the cached NAV, whereas EIP-4626 integrators
///      would expect `max*` to return 0 during a halt (IL-8639, TP-L-11; PlasmaVault `max*` semantics are
///      intentionally unchanged). Use `isNavHealthy(plasmaVault)` as a best-effort off-chain / integrator signal.
///
///      The early return for `execute` and `updateMarketsBalances` does NOT cover performance-fee realisation:
///      both can mint fee shares after refreshing an unrelated market while an executor's cached value may
///      overstate the real remote value. This is an accepted limitation (IL-8599, TP-M-21); the operational
///      rule is in the "Performance fees while an executor is fail-closed" section of the crosschain READMEs.
/// @author IPOR Labs
contract CrosschainNavValidationPreHook is IPreHook {
    /// @notice Thrown when a granted substrate is neither a remote-vault marker nor a valid executor.
    error CrosschainNavValidationPreHookInvalidExecutorSubstrate(uint8 substrateType, address substrateAddress);

    /// @notice Thrown when a granted executor is not managed by this PlasmaVault.
    error CrosschainNavValidationPreHookExecutorManagerMismatch(address executor, address manager);

    /// @notice Market identifier bound to this pre-hook instance (governance wiring / substrate lookup).
    uint256 public immutable MARKET_ID;

    /// @param marketId_ Market identifier this pre-hook is associated with (CROSSCHAIN).
    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice Best-effort probe: would `run()` pass for a gated selector on `plasmaVault_` right now?
    /// @dev Mirrors the substrate walk of `run()` but is a plain view: a hook called directly has no vault storage,
    ///      so the substrates are read from `plasmaVault_` through `getMarketSubstrates(MARKET_ID)`. Returns false
    ///      when that read fails, a substrate is malformed or has no code, an executor reports a different
    ///      `MANAGER`, or an executor's `getBalance()` reverts (stale attestation, blocked chain, stale in-flight
    ///      record). Returns true when no EXECUTOR substrate is granted (the hook is then a no-op). It is NOT a
    ///      security control: the answer can change in the same block and the real gate is `run()` (IL-8639).
    ///      A read that succeeds but returns data shorter than its type (`getMarketSubstrates`, `MANAGER()` or
    ///      `getBalance()` on a contract that is neither a PlasmaVault nor an executor) makes this view REVERT, because
    ///      `try ... returns` does not catch a decode failure in the caller (IL-9118). Real PlasmaVaults and executors
    ///      always return well-formed data; reverting is the safe direction for an integrator signal.
    /// @param plasmaVault_ The PlasmaVault whose CROSSCHAIN executors are probed.
    /// @return True when every granted executor currently passes the fail-closed gate.
    function isNavHealthy(address plasmaVault_) external view returns (bool) {
        // A high-level call to an address without code reverts in the caller, even inside try/catch.
        if (plasmaVault_.code.length == 0) {
            return false;
        }
        bytes32[] memory substrates;
        try IPlasmaVaultGovernance(plasmaVault_).getMarketSubstrates(MARKET_ID) returns (bytes32[] memory read_) {
            substrates = read_;
        } catch {
            return false;
        }
        uint256 len = substrates.length;
        for (uint256 i; i < len; ++i) {
            // Out-of-range type bytes would make the decoder revert; `run()` reverts on them too.
            if (uint256(substrates[i]) >> 248 > uint256(CrosschainSubstrateType.REMOTE_VAULT)) {
                return false;
            }
            CrosschainSubstrate memory substrate = CrosschainSubstrateLib.bytes32ToSubstrate(substrates[i]);
            if (substrate.substrateType == CrosschainSubstrateType.REMOTE_VAULT) {
                continue;
            }
            if (substrate.substrateType != CrosschainSubstrateType.EXECUTOR || substrate.substrateAddress == address(0))
            {
                return false;
            }
            address executor = substrate.substrateAddress;
            if (executor.code.length == 0) {
                return false;
            }
            try ICrosschainExecutor(executor).MANAGER() returns (address manager_) {
                if (manager_ != plasmaVault_) {
                    return false;
                }
            } catch {
                return false;
            }
            try ICrosschainExecutor(executor).getBalance() returns (uint256) {}
            catch {
                return false;
            }
        }
        return true;
    }

    /// @notice Runs the fail-closed NAV freshness/blocked gate before the gated user operation executes.
    /// @dev `execute` and `updateMarketsBalances` pass through; every other selector gets the same check. When
    ///      no EXECUTOR substrate is granted there is no crosschain exposure and the hook is a no-op.
    /// @param selector_ The function selector that triggered this pre-hook.
    function run(bytes4 selector_) external override {
        // `execute` is gated at the fuse/action level: value-increasing cross-chain actions perform the
        // live NAV check themselves (including a RETRY_COMMAND of a stored DEPOSIT, IL-8600), while the
        // approved recovery actions must remain callable when NAV is fail-closed.
        // Share-price-sensitive deposit/withdraw selectors still use the global gate below.
        if (selector_ == IPlasmaVault.execute.selector) return;
        // `updateMarketsBalances` moves no assets and cannot price shares for a user. The CROSSCHAIN market
        // already fails closed in `CrosschainBalanceFuse`, so gating the selector here would only stop the
        // refresh of the vault's other markets while an executor is stale or blocked.
        if (selector_ == IPlasmaVault.updateMarketsBalances.selector) return;

        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = substrates.length;

        for (uint256 i; i < len; ++i) {
            CrosschainSubstrate memory substrate = CrosschainSubstrateLib.bytes32ToSubstrate(substrates[i]);
            if (substrate.substrateType == CrosschainSubstrateType.REMOTE_VAULT) {
                continue;
            }
            if (substrate.substrateType != CrosschainSubstrateType.EXECUTOR || substrate.substrateAddress == address(0))
            {
                revert CrosschainNavValidationPreHookInvalidExecutorSubstrate(
                    uint8(substrate.substrateType), substrate.substrateAddress
                );
            }
            address executor = substrate.substrateAddress;
            if (executor.code.length == 0) {
                revert CrosschainSubstrateLib.CrosschainFuseExecutorNoCode(executor);
            }
            address manager = ICrosschainExecutor(executor).MANAGER();
            if (manager != address(this)) {
                revert CrosschainNavValidationPreHookExecutorManagerMismatch(executor, manager);
            }
            // Fail-closed gate: reverts on staleness / blocked chain / stale in-flight record. Result discarded.
            ICrosschainExecutor(executor).getBalance();
        }
    }
}
