// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";
import {IPlasmaVaultBase} from "../../interfaces/IPlasmaVaultBase.sol";
import {IRealizeManagementFeeInternal} from "../../interfaces/IRealizeManagementFeeInternal.sol";
import {CallbackHandlerLib} from "../../libraries/CallbackHandlerLib.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IPlasmaVaultBaseGetter} from "../burn_request_fee/BurnRequestFeeFuse.sol";

/**
 * @title RealizeManagementFeeFuse - Fuse that collects the accrued management fee on demand
 * @author IPOR Labs
 * @notice Lets ALPHA collect the accrued management fee of a PlasmaVault through `execute`, without a deposit or a
 *         withdrawal (IL-8870). One deployment per chain serves every PlasmaVault version.
 * @dev Execution context:
 * - Runs only via delegatecall from `PlasmaVault.execute`: `address(this)` is the vault, storage is the vault's.
 *   Called directly, or by a vault outside `execute`, it reverts (the self-call below fails with data other than
 *   `HandlerNotFound()`, which is re-thrown).
 * - Stateless. `MARKET_ID` is `IporFusionMarkets.ZERO_BALANCE_MARKET`, so the balance refresh that `execute` runs
 *   after the fuse values nothing. The fuse never calls the ALPHA method `realizeManagementFee()`.
 *
 * Version detection (one low-level self-call of `realizeManagementFeeInternal()`):
 * - success: the vault has the IL-8870 entry; the vault itself realized the fee (new path);
 * - revert data exactly `CallbackHandlerLib.HandlerNotFound()` (4 bytes): a vault without the entry, whose fallback
 *   routes the unknown selector to the callback handler during `execute` (legacy path below);
 * - any other revert data, including empty data, is re-thrown unchanged, so an error of the new entry can never
 *   silently switch the fuse to the legacy computation.
 *
 * Order in the batch (IL-8870 D-025, D-026): the fuse must be the only action of its own top-level `execute`, with
 * nothing before it and nothing after it, and never inside a callback batch. `execute` refreshes the stored market
 * balances only after the last action, so with a pending fee an action before the fuse over-mints fee shares or drops
 * the fee at zero gross assets, an action after it reprices the pending fee and changes the performance fee, and on
 * F1/F2 a later loss in the batch lets the old net loss guard charge a performance fee. Collecting at a rebalance
 * therefore takes two transactions on F0, F1 and F2; on A, ALPHA may call `realizeManagementFee()` outside `execute`
 * instead. Exception: a balance fuse dependency graph under `ZERO_BALANCE_MARKET` refreshes those markets even then.
 *
 * Behaviour per vault family:
 * - A (templates built with IL-8870): the accrued fee is already in the share price as virtual fee shares. The vault
 *   mints exactly those shares in `_realizeManagementFee()`, so the share price before and after collection is the
 *   same and the result equals a deposit-time realization (clock, pending fee and the `ManagementFeeRealized` event
 *   are handled by the vault).
 * - F2 (Release 2026-10 templates, pending management fee slot) and F1 (templates after ipor-fusion #475 with
 *   IL-6959): `totalAssets()` is gross, so the fee is priced on gross assets exactly as a deposit-time realization
 *   prices it; collection lowers the share price by the fee. Run alone, it cannot produce a performance fee; with a
 *   later action in the same batch that records a loss, the immutable net loss guard of F1/F2 compares net assets
 *   before and after the batch, sees them rise by the collected fee, and can charge a performance fee.
 * - F0 (templates built before ipor-fusion #475, February 2026): `totalAssets()` is net of the accrued fee. The
 *   deposit-time realization advances the fee clock before `convertToShares`, so it prices on gross assets; the fuse
 *   keeps that order and gives the same result as a deposit (Pete, IL-8870 D-007). Like any F0 deposit this lifts the
 *   unit price by about (fee / assets)^2, which at the high-water mark can charge a dust performance fee in the same
 *   `execute`.
 *
 * Legacy path (F0, F1, F2), in the order of a deposit-time realization:
 * 1. reads the management fee account, `totalSupply()` and `getUnrealizedManagementFee()`; returns 0 without any
 *    write when one of them is zero (an empty supply is a deliberate no-op: F1 would mint `fee * offset` shares on
 *    dust, F2 would drop the accrual);
 * 2. advances the fee clock to `block.timestamp`, then reads `totalAssets()` and `convertToShares(fee)`; when either
 *    is zero the clock is restored and nothing else is written (the fee stays accrued for a later realization);
 * 3. mints the fee shares to the fee account through `PLASMA_VAULT_BASE().updateInternal` (delegatecall, the same
 *    pipeline as the vault's `_mint`: votes checkpoints, supply cap check) with the supply cap validation disabled
 *    for the mint, then clears the pending management fee slot when it is non-zero (F2 only);
 * 4. emits the vault event `ManagementFeeRealized(fee, shares)` from the vault context.
 *
 * Requirements (see contracts/fuses/management_fee/README.md):
 * - the vault's FUSE_MANAGER adds the fuse with `addFuses` (on some vaults behind a timelock);
 * - the vault has a balance fuse on `ZERO_BALANCE_MARKET` (vaults from `FusionFactory` have `ZeroBalanceFuse`),
 *   otherwise `execute` reverts with `MarketWithoutBalanceFuse`;
 * - `execute` refreshes the touched market and reads the underlying price from the price oracle; a balance fuse
 *   dependency graph attached to `ZERO_BALANCE_MARKET` makes `execute` refresh those markets too;
 * - the atomist must not register a callback handler for the pair (vault, `realizeManagementFeeInternal` selector):
 *   on a legacy vault the fallback then runs the handler (callbacks are handled during an execute) and returns
 *   empty data whatever the handler did, so the self-call succeeds with empty data and `abi.decode` reverts the
 *   whole `execute` (fail-closed, no state change). The fuse does not police this.
 *
 * Events: `RealizeManagementFeeFuseEnter` is emitted only when fee shares were minted; `ManagementFeeRealized` is
 * emitted by the vault on A and by this fuse (in the vault context, same signature) on the legacy path.
 */
contract RealizeManagementFeeFuse is IFuseCommon {
    using Address for address;

    /// @notice Thrown when exit or exitTransient is called; the fuse only collects the management fee
    error RealizeManagementFeeFuseExitNotSupported();

    /// @notice Thrown on the legacy path when the vault's `PLASMA_VAULT_BASE()` getter returns `address(0)`
    error RealizeManagementFeeFusePlasmaVaultBaseNotSet();

    /// @notice Emitted when the fuse collected the management fee
    /// @param version Address of the fuse contract version
    /// @param feeShares Management fee shares minted to the management fee account
    event RealizeManagementFeeFuseEnter(address version, uint256 feeShares);

    /// @notice PlasmaVault event, emitted from the vault context on the legacy path (same signature as the vault's)
    /// @param unrealizedFeeInUnderlying Realized management fee in underlying token decimals, including the pending fee
    /// @param unrealizedFeeInShares Management fee shares minted to the management fee account
    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);

    /// @notice Market ID this fuse operates on
    /// @dev ZERO_BALANCE_MARKET: the post-execute balance refresh of this market values nothing
    uint256 public constant MARKET_ID = IporFusionMarkets.ZERO_BALANCE_MARKET;

    /// @notice Address of this fuse contract version
    address public immutable VERSION;

    /// @notice Creates the fuse; it takes no parameters, so one deployment per chain serves every vault version
    constructor() {
        VERSION = address(this);
    }

    /// @notice Collects the accrued management fee of the vault
    /// @dev Self-calls `realizeManagementFeeInternal()`: success selects the new path, revert data exactly
    ///      `HandlerNotFound()` selects the legacy path, any other revert data is re-thrown unchanged.
    /// @return feeShares Management fee shares minted to the management fee account (0 when nothing was minted)
    function enter() public returns (uint256 feeShares) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = address(this).call(
            abi.encodeWithSelector(IRealizeManagementFeeInternal.realizeManagementFeeInternal.selector)
        );

        if (success) {
            feeShares = abi.decode(result, (uint256));
        } else if (result.length == 4 && bytes4(result) == CallbackHandlerLib.HandlerNotFound.selector) {
            feeShares = _realizeManagementFeeLegacy();
        } else {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }

        if (feeShares > 0) {
            emit RealizeManagementFeeFuseEnter(VERSION, feeShares);
        }
    }

    /// @notice Collects the accrued management fee and writes the result to transient storage
    /// @dev Takes no inputs. Writes the minted fee shares as output 0 for this fuse version.
    function enterTransient() external {
        uint256 feeShares = enter();

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(feeShares);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exit is not supported
    /// @dev Always reverts with RealizeManagementFeeFuseExitNotSupported
    function exit() external pure {
        revert RealizeManagementFeeFuseExitNotSupported();
    }

    /// @notice Exit using transient storage is not supported
    /// @dev Always reverts with RealizeManagementFeeFuseExitNotSupported
    function exitTransient() external pure {
        revert RealizeManagementFeeFuseExitNotSupported();
    }

    /// @notice Realizes the management fee on a vault without `realizeManagementFeeInternal()` (F0, F1, F2)
    /// @dev Follows the order of a deposit-time realization (see the contract NatSpec). Uses only storage slots and
    ///      vault getters shared by F0, F1, F2 and A: `ManagementFeeData`, the pending management fee slot, the supply
    ///      cap validation flag and `PLASMA_VAULT_BASE()`.
    /// @return feeShares Management fee shares minted to the management fee account (0 when nothing was minted)
    function _realizeManagementFeeLegacy() private returns (uint256 feeShares) {
        address feeAccount = PlasmaVaultLib.getManagementFeeData().feeAccount;

        if (feeAccount == address(0) || IERC4626(address(this)).totalSupply() == 0) {
            return 0;
        }

        uint256 unrealizedFeeInUnderlying = IPlasmaVault(address(this)).getUnrealizedManagementFee();

        if (unrealizedFeeInUnderlying == 0) {
            return 0;
        }

        PlasmaVaultStorageLib.ManagementFeeData storage feeData = PlasmaVaultStorageLib.getManagementFeeData();
        uint32 lastUpdateTimestamp = feeData.lastUpdateTimestamp;

        /// @dev Advance the fee clock before pricing, like the deposit-time realization: on F0 this makes
        ///      `totalAssets()` gross for the conversion; on F1, F2 `totalAssets()` is gross regardless of the clock
        PlasmaVaultLib.updateManagementFeeData();

        if (IERC4626(address(this)).totalAssets() > 0) {
            feeShares = IERC4626(address(this)).convertToShares(unrealizedFeeInUnderlying);
        }

        if (feeShares == 0) {
            /// @dev Nothing to mint: restore the clock so the state stays untouched and the fee stays accrued
            feeData.lastUpdateTimestamp = lastUpdateTimestamp;
            return 0;
        }

        _mintFeeShares(feeAccount, feeShares);

        /// @dev The pending management fee slot exists only on F2 (always zero on F0, F1)
        if (PlasmaVaultStorageLib.getPendingManagementFee() != 0) {
            PlasmaVaultStorageLib.setPendingManagementFee(0);
        }

        emit ManagementFeeRealized(unrealizedFeeInUnderlying, feeShares);
    }

    /// @notice Mints management fee shares through the vault's `_update` pipeline with the supply cap check disabled
    /// @dev Delegatecalls `PLASMA_VAULT_BASE().updateInternal(address(0), feeAccount_, feeShares_)`, the path of the
    ///      vault's own `_mint` (ERC20 state, votes checkpoints, supply cap check), with the supply cap validation flag
    ///      set to 1 for the mint and back to 0 afterwards, as in the vault's own realization.
    /// @param feeAccount_ Management fee account receiving the shares
    /// @param feeShares_ Management fee shares to mint
    function _mintFeeShares(address feeAccount_, uint256 feeShares_) private {
        address plasmaVaultBase = IPlasmaVaultBaseGetter(address(this)).PLASMA_VAULT_BASE();

        if (plasmaVaultBase == address(0)) {
            revert RealizeManagementFeeFusePlasmaVaultBaseNotSet();
        }

        /// @dev total supply cap validation is disabled for fee minting
        PlasmaVaultLib.setTotalSupplyCapValidation(1);

        plasmaVaultBase.functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, address(0), feeAccount_, feeShares_)
        );

        /// @dev total supply cap validation is enabled when fee minting is finished
        PlasmaVaultLib.setTotalSupplyCapValidation(0);
    }
}
