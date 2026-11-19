// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {CallbackData} from "../../libraries/CallbackHandlerLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @title Callback handler for Euler V2 batch callbacks
/// @notice Returns the `CallbackData` of an `onEulerFlashLoan` call that the EVC delivers to a Plasma Vault; the vault
///         (`CallbackHandlerLib.handleCallback`) then runs its inner fuse actions and its one token approval
/// @dev The payload is untrusted: the EVC forwards whatever a batch item or an `EVC.call` names. In the vault's own
///      batch, EulerV2BatchFuse validates it (the approval must be a declared, validated pair that is reset after
///      the batch). Any other contract that gets control while the vault executes fuses could call
///      `EVC.call(vault, itself, 0, onEulerFlashLoan(...))`, so the handler accepts the callback only when the EVC
///      on-behalf-of account shares the calling vault's 19-byte address prefix (the vault or one of its
///      sub-accounts). Items the vault sends to itself in `EVC.batch` run as such an account without
///      authentication; any other caller must be the owner or an operator of the vault's accounts.
///      Defense in depth (IL-9697): the handler also rejects the two EVC contexts in which a legitimate callback never
///      runs. In the vault's own batch the vault is both caller and target, so the EVC clears the operator flag; and
///      `EVC.batch` cannot start during `controlCollateral`. So a callback with `isOperatorAuthenticated()` (an
///      operator of a vault sub-account called `EVC.call`) or `isControlCollateralInProgress()` (a controller of a
///      vault sub-account called `EVC.controlCollateral` on the vault as collateral) is never the vault's own batch.
/// @dev Register per vault with `updateCallbackHandler(handler, EVC, onEulerFlashLoan.selector)`; deploy one instance
///      per chain with that chain's EVC. Stateless; the vault calls it with CALL, so `msg.sender` is the vault.
contract CallbackHandlerEuler {
    /// @notice Thrown when the EVC on-behalf-of account does not share the calling vault's address prefix, or the
    ///         callback runs in an operator-authenticated or `controlCollateral` EVC context
    /// @param account The EVC on-behalf-of account of the callback
    /// @custom:error CallbackHandlerEulerUnauthorizedOrigin
    error CallbackHandlerEulerUnauthorizedOrigin(address account);

    /// @notice The Ethereum Vault Connector that delivers the callback to the vault
    IEVC public immutable EVC;

    /// @param evc_ The Ethereum Vault Connector address of this chain
    constructor(address evc_) {
        if (evc_ == address(0)) {
            revert Errors.WrongAddress();
        }
        EVC = IEVC(evc_);
    }

    /// @notice Returns the callback payload after checking that the callback comes from an account of the vault
    /// @dev Reverts when the EVC has no authenticated on-behalf-of account (a call outside an EVC call or batch), and
    ///      with the same error when the EVC authenticated an operator or a `controlCollateral` call is in progress
    /// @param data_ ABI-encoded `CallbackData`
    /// @return The decoded `CallbackData`, executed by the vault
    function onEulerFlashLoan(bytes calldata data_) external view returns (CallbackData memory) {
        (address account, ) = EVC.getCurrentOnBehalfOfAccount(address(0));
        if ((uint160(account) ^ uint160(msg.sender)) >= 0x100) {
            revert CallbackHandlerEulerUnauthorizedOrigin(account);
        }
        if (EVC.isOperatorAuthenticated() || EVC.isControlCollateralInProgress()) {
            revert CallbackHandlerEulerUnauthorizedOrigin(account);
        }
        return abi.decode(data_, (CallbackData));
    }
}
