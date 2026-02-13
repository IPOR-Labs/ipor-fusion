// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVault} from "../../vaults/PlasmaVault.sol";
import {IporFusionAccessManagersStorageLib} from "./IporFusionAccessManagersStorageLib.sol";

/**
 * @dev Function selectors for vault operations that trigger or are affected by redemption delays
 */
bytes4 constant DEPOSIT_SELECTOR = PlasmaVault.deposit.selector;
bytes4 constant DEPOSIT_WITH_PERMIT_SELECTOR = PlasmaVault.depositWithPermit.selector;
bytes4 constant MINT_SELECTOR = PlasmaVault.mint.selector;
bytes4 constant WITHDRAW_SELECTOR = PlasmaVault.withdraw.selector;
bytes4 constant REDEEM_SELECTOR = PlasmaVault.redeem.selector;
bytes4 constant TRANSFER_FROM_SELECTOR = PlasmaVault.transferFrom.selector;
bytes4 constant TRANSFER_SELECTOR = PlasmaVault.transfer.selector;

/**
 * @title Redemption Delay Library
 * @notice Implements time-based restrictions on withdrawals and redemptions after deposits
 * @dev Provides functionality to enforce cooling periods between deposits and withdrawals
 * to prevent potential manipulation and protect the vault's assets
 * @custom:security-contact security@ipor.io
 */
library RedemptionDelayLib {
    /**
     * @notice Error thrown when an account attempts to withdraw before their lock period expires
     * @param unlockTime The timestamp when the account will be unlocked
     */
    error AccountIsLocked(uint256 unlockTime);

    /**
     * @notice Retrieves the lock time for a specific account
     * @dev Used to check when an account will be able to withdraw or redeem
     * @param account_ The address to check the lock time for
     * @return The timestamp until which the account is locked
     * @custom:security This value should be checked before allowing withdrawals
     */
    function getAccountLockTime(address account_) internal view returns (uint256) {
        return IporFusionAccessManagersStorageLib.getRedemptionLocks().redemptionLock[account_];
    }

    /**
     * @notice Enforces redemption delay rules based on function calls
     * @dev Implements the following rules:
     * 1. For withdrawals/redemptions: Checks if the account is still locked
     * 2. For deposits/mints: Sets a new lock period
     * @param account_ The account performing the operation
     * @param sig_ The function selector of the operation being performed
     * @custom:security Critical function that prevents quick deposit/withdrawal cycles
     * @custom:error-handling Reverts with AccountIsLocked if withdrawal attempted during lock period
     */
    function lockChecks(address account_, bytes4 sig_) internal {
        if (
            sig_ == WITHDRAW_SELECTOR ||
            sig_ == REDEEM_SELECTOR ||
            sig_ == TRANSFER_FROM_SELECTOR ||
            sig_ == TRANSFER_SELECTOR
        ) {
            uint256 unlockTime = IporFusionAccessManagersStorageLib.getRedemptionLocks().redemptionLock[account_];
            if (unlockTime > block.timestamp) {
                revert AccountIsLocked(unlockTime);
            }
        } else if (sig_ == DEPOSIT_SELECTOR || sig_ == MINT_SELECTOR || sig_ == DEPOSIT_WITH_PERMIT_SELECTOR) {
            IporFusionAccessManagersStorageLib.setRedemptionLocks(account_);
        }
    }
}
