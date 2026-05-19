// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuse.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultBase} from "../../interfaces/IPlasmaVaultBase.sol";

/// @dev Minimal interface for resolving the PlasmaVaultBase address on both new
///      and legacy PlasmaVault deployments. New vaults expose this getter via
///      `PlasmaVault.PLASMA_VAULT_BASE()` reading `PLASMA_VAULT_BASE_SLOT`;
///      legacy (pre-migration) vaults expose the same selector backed by an
///      `immutable` field baked into bytecode. Tracked in IL-7407.
interface IPlasmaVaultBaseGetter {
    function PLASMA_VAULT_BASE() external view returns (address);
}

/**
 * @title RequestFeeRefundFuse - Fuse for Refunding Request Fee Shares
 * @notice Specialized fuse contract that refunds request-fee shares collected
 *         by WithdrawManager to a user whose withdraw request has already
 *         expired. Counterpart to BurnRequestFeeFuse.
 * @dev Routes the share transfer through PlasmaVaultBase.updateInternal so
 *      that ERC20Votes checkpoints and supply-cap validations stay
 *      consistent - the same pattern that was mandated for the burn path in
 *      IL-6952 (audit R4H7) and is covered by
 *      BurnRequestFeeVotingRegressionTest.
 *
 * Execution Context:
 * - All fuse operations are executed via delegatecall from PlasmaVault.
 * - Storage operations affect PlasmaVault's state, not the fuse contract.
 * - msg.sender refers to the caller of PlasmaVault.execute.
 * - address(this) refers to PlasmaVault's address during execution.
 *
 * Inheritance Structure:
 * - IFuseCommon: Base fuse interface implementation.
 *
 * Core Features:
 * - Refunds fee shares from WithdrawManager to a specified recipient.
 * - Routes transfer through the vault's _update pipeline for proper hook
 *   execution.
 * - Maintains version and market tracking.
 * - Implements fuse enter/exit pattern (exit reverts).
 *
 * Integration Points:
 * - PlasmaVault: Main vault interaction (via delegatecall).
 * - PlasmaVaultBase: Token state management (via nested delegatecall).
 * - WithdrawManager: Source of fee shares.
 * - Fuse System: Execution framework.
 *
 * Security Considerations:
 * - Transfer routes through vault's _update pipeline to maintain voting
 *   checkpoints on both the withdraw manager and the recipient.
 * - Recipient guard against address(0) prevents accidental burn semantics.
 * - No storage variables; fuse is stateless.
 * - Amount overflow bounded by ERC20 balance of WithdrawManager.
 * - Delegatecall targets are resolved with backward-compat shims per IL-7407:
 *   WithdrawManager via PlasmaVaultStorageLib.getWithdrawManagerAddressWithLegacyFallback()
 *   (corrected + legacy slot), and PlasmaVaultBase via a self-staticcall to
 *   `PLASMA_VAULT_BASE()` which is served from `PLASMA_VAULT_BASE_SLOT` on new
 *   vaults and from a baked-in `immutable` on legacy ones.
 */

/// @notice Data structure for the enter function parameters
/// @dev Used to pass refund parameters to the enter function.
struct RequestFeeRefundDataEnter {
    /// @notice Address that will receive the refunded fee shares.
    address recipient;
    /// @notice Amount of fee shares to refund. `0` is a no-op.
    uint256 amount;
}

/// @title RequestFeeRefundFuse
/// @notice Contract responsible for refunding request fee shares from
///         PlasmaVault's WithdrawManager to a user with an expired request.
contract RequestFeeRefundFuse is IFuseCommon {
    using Address for address;

    /// @notice Thrown when WithdrawManager address is not set in either the
    ///         corrected (IL-6952) or legacy slot of PlasmaVault.
    error RequestFeeRefundWithdrawManagerNotSet();

    /// @notice Thrown when PlasmaVaultBase address resolved via the vault's
    ///         `PLASMA_VAULT_BASE()` getter is `address(0)` (IL-7407).
    error RequestFeeRefundPlasmaVaultBaseNotSet();

    /// @notice Thrown when the recipient address is address(0).
    /// @dev Guards against drifting into BurnRequestFeeFuse semantics.
    error RequestFeeRefundInvalidRecipient();

    /// @notice Thrown when exit function is called (not implemented).
    error RequestFeeRefundExitNotImplemented();

    /// @notice Emitted when request fee shares are refunded to a recipient.
    /// @param version Address of the fuse contract version.
    /// @param recipient Address that received the refund.
    /// @param amount Amount of shares transferred.
    event RequestFeeRefundEnter(address version, address recipient, uint256 amount);

    /// @notice Address of this fuse contract version.
    /// @dev Immutable value set in constructor; equals `address(this)`.
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on.
    /// @dev Immutable value set in constructor.
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the RequestFeeRefundFuse contract.
    /// @dev Sets up the fuse with market ID.
    /// @param marketId_ The market ID this fuse will operate on.
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Refunds request-fee shares from WithdrawManager to `recipient`.
    /// @dev Routes through PlasmaVaultBase.updateInternal via delegatecall to
    ///      ensure ERC20Votes checkpoint updates on both sides.
    ///
    /// Operation Flow:
    /// - Zero-amount: immediate return, no-op (parity with BurnRequestFeeFuse).
    /// - Validates recipient is non-zero.
    /// - Verifies WithdrawManager is set in PlasmaVault.
    /// - Transfers `amount` shares from WithdrawManager to recipient via
    ///   delegatecall to PlasmaVaultBase.updateInternal.
    /// - Emits RequestFeeRefundEnter.
    ///
    /// Security:
    /// - Routes through vault's _update pipeline to maintain voting
    ///   checkpoints on both WithdrawManager and recipient.
    /// - Checks WithdrawManager existence.
    /// - Validates recipient against address(0).
    ///
    /// @param data_ Struct containing the recipient and the amount to refund.
    /// @dev IMPORTANT: This fuse resolves vault addresses with backward-compat shims
    /// so the same bytecode runs against new and legacy PlasmaVaults (IL-7407):
    ///  1. WithdrawManager: read via PlasmaVaultStorageLib.getWithdrawManagerAddressWithLegacyFallback(),
    ///     which prefers the corrected WITHDRAW_MANAGER slot (IL-6952, audit R4H7) and
    ///     falls back to the legacy slot used by pre-IL-6952 deployments.
    ///  2. PlasmaVaultBase: read by calling `PLASMA_VAULT_BASE()` on the vault itself
    ///     (delegatecall context ⇒ address(this) == PlasmaVault). New vaults serve the
    ///     value from `PLASMA_VAULT_BASE_SLOT`; legacy vaults (e.g. Clearstar) serve it
    ///     from a baked-in `immutable`. Both expose the same external selector, so the
    ///     fuse stays drop-in compatible without storage migration.
    /// Any changes to either slot must be coordinated with BurnRequestFeeFuse,
    /// PlasmaVaultRequestSharesFuse, UpdateWithdrawManagerMaintenanceFuse and the helper.
    function enter(RequestFeeRefundDataEnter memory data_) public {
        if (data_.amount == 0) {
            return;
        }

        if (data_.recipient == address(0)) {
            revert RequestFeeRefundInvalidRecipient();
        }

        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManagerAddressWithLegacyFallback();
        if (withdrawManager == address(0)) {
            revert RequestFeeRefundWithdrawManagerNotSet();
        }

        address plasmaVaultBase = IPlasmaVaultBaseGetter(address(this)).PLASMA_VAULT_BASE();
        if (plasmaVaultBase == address(0)) {
            revert RequestFeeRefundPlasmaVaultBaseNotSet();
        }

        // Route transfer through PlasmaVaultBase.updateInternal to ensure voting
        // checkpoints and supply-cap validations are properly executed on both
        // the source (withdrawManager) and destination (recipient). Using
        // delegatecall ensures the vault's _update pipeline is used instead of
        // bypassing it (see IL-6952 / BurnRequestFeeVotingRegressionTest).
        plasmaVaultBase.functionDelegateCall(
            abi.encodeWithSelector(
                IPlasmaVaultBase.updateInternal.selector,
                withdrawManager,
                data_.recipient,
                data_.amount
            )
        );

        emit RequestFeeRefundEnter(VERSION, data_.recipient, data_.amount);
    }

    /// @notice Exit function (not implemented).
    /// @dev Always reverts; this fuse only supports refunding via `enter`.
    function exit() external pure {
        revert RequestFeeRefundExitNotImplemented();
    }
}
