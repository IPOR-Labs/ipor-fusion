// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuse.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultBase} from "../../interfaces/IPlasmaVaultBase.sol";
import {WithdrawManager, WithdrawRequestInfo} from "../../managers/withdraw/WithdrawManager.sol";

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
 * - Enforces that the recipient's WithdrawRequest has expired (strict `>`
 *   against endWithdrawWindowTimestamp).
 * - Routes transfer through the vault's _update pipeline for proper hook
 *   execution.
 * - Maintains version and market tracking.
 * - Implements fuse enter/exit pattern (exit reverts).
 *
 * Integration Points:
 * - PlasmaVault: Main vault interaction (via delegatecall).
 * - PlasmaVaultBase: Token state management (via nested delegatecall).
 * - WithdrawManager: Source of fee shares and authority on request expiry.
 * - Fuse System: Execution framework.
 *
 * Security Considerations:
 * - Transfer routes through vault's _update pipeline to maintain voting
 *   checkpoints on both the withdraw manager and the recipient.
 * - Recipient guard against address(0) prevents accidental burn semantics.
 * - Strict-`>` expiry check prevents double-dip with active withdraw
 *   requests (WithdrawManager uses inclusive `<=` on the boundary).
 * - No storage variables; fuse is stateless.
 * - Amount overflow bounded by ERC20 balance of WithdrawManager.
 * - Delegatecall targets are hard-coded storage reads from
 *   PlasmaVaultStorageLib (WithdrawManager and PlasmaVaultBase slots).
 */

/// @notice Data structure for the enter function parameters
/// @dev Used to pass refund parameters to the enter function.
struct RequestFeeRefundDataEnter {
    /// @notice Address that will receive the refunded fee shares.
    /// @dev Must have a previously submitted withdraw request whose window
    ///      has strictly expired.
    address recipient;
    /// @notice Amount of fee shares to refund. `0` is a no-op.
    uint256 amount;
}

/// @title RequestFeeRefundFuse
/// @notice Contract responsible for refunding request fee shares from
///         PlasmaVault's WithdrawManager to a user with an expired request.
contract RequestFeeRefundFuse is IFuseCommon {
    using Address for address;

    /// @notice Thrown when WithdrawManager address is not set in PlasmaVault.
    error RequestFeeRefundWithdrawManagerNotSet();

    /// @notice Thrown when the recipient address is address(0).
    /// @dev Guards against drifting into BurnRequestFeeFuse semantics.
    error RequestFeeRefundInvalidRecipient();

    /// @notice Thrown when the recipient has never submitted a withdraw request.
    /// @param recipient The recipient address with no prior request.
    error RequestFeeRefundNoActiveRequest(address recipient);

    /// @notice Thrown when the recipient's withdraw request has not yet expired.
    /// @param recipient Recipient address whose request is still active.
    /// @param endWithdrawWindowTimestamp Stored expiry of the recipient's request.
    /// @param nowTimestamp `block.timestamp` at the time of the call.
    error RequestFeeRefundRequestStillActive(
        address recipient,
        uint256 endWithdrawWindowTimestamp,
        uint256 nowTimestamp
    );

    /// @notice Thrown when exit function is called (not implemented).
    error RequestFeeRefundExitNotImplemented();

    /// @notice Emitted when request fee shares are refunded to a recipient.
    /// @param version Address of the fuse contract version.
    /// @param recipient Address that received the refund.
    /// @param amount Amount of shares transferred.
    /// @param endWithdrawWindowTimestamp Expiry timestamp of the recipient's request
    ///        at the time of refund.
    event RequestFeeRefundEnter(
        address version,
        address indexed recipient,
        uint256 amount,
        uint256 endWithdrawWindowTimestamp
    );

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
    /// - Reads recipient's WithdrawRequest via WithdrawManager.requestInfo.
    /// - Requires a request to exist AND block.timestamp >
    ///   endWithdrawWindowTimestamp (strict).
    /// - Transfers `amount` shares from WithdrawManager to recipient via
    ///   delegatecall to PlasmaVaultBase.updateInternal.
    /// - Emits RequestFeeRefundEnter.
    ///
    /// Security:
    /// - Routes through vault's _update pipeline to maintain voting
    ///   checkpoints on both WithdrawManager and recipient.
    /// - Checks WithdrawManager existence.
    /// - Validates recipient against address(0).
    /// - Validates request existence and expiry.
    ///
    /// @param data_ Struct containing the recipient and the amount to refund.
    /// @dev IMPORTANT: The fuse reads the WITHDRAW_MANAGER storage slot via
    /// PlasmaVaultStorageLib.getWithdrawManager(). This slot was corrected in
    /// IL-6952 (audit R4H7) to avoid collision with CALLBACK_HANDLER. Any
    /// changes to that slot must be coordinated with all fuses that access
    /// it, because fuses execute via delegatecall in the PlasmaVault storage
    /// context.
    function enter(RequestFeeRefundDataEnter memory data_) public {
        if (data_.amount == 0) {
            return;
        }

        if (data_.recipient == address(0)) {
            revert RequestFeeRefundInvalidRecipient();
        }

        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
        if (withdrawManager == address(0)) {
            revert RequestFeeRefundWithdrawManagerNotSet();
        }

        WithdrawRequestInfo memory info = WithdrawManager(withdrawManager).requestInfo(data_.recipient);

        if (info.endWithdrawWindowTimestamp == 0) {
            revert RequestFeeRefundNoActiveRequest(data_.recipient);
        }

        if (block.timestamp <= info.endWithdrawWindowTimestamp) {
            revert RequestFeeRefundRequestStillActive(
                data_.recipient,
                info.endWithdrawWindowTimestamp,
                block.timestamp
            );
        }

        // Route transfer through PlasmaVaultBase.updateInternal to ensure voting
        // checkpoints and supply-cap validations are properly executed on both
        // the source (withdrawManager) and destination (recipient). Using
        // delegatecall ensures the vault's _update pipeline is used instead of
        // bypassing it (see IL-6952 / BurnRequestFeeVotingRegressionTest).
        PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
            abi.encodeWithSelector(
                IPlasmaVaultBase.updateInternal.selector,
                withdrawManager,
                data_.recipient,
                data_.amount
            )
        );

        emit RequestFeeRefundEnter(VERSION, data_.recipient, data_.amount, info.endWithdrawWindowTimestamp);
    }

    /// @notice Exit function (not implemented).
    /// @dev Always reverts; this fuse only supports refunding via `enter`.
    function exit() external pure {
        revert RequestFeeRefundExitNotImplemented();
    }
}
