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
     * @notice Emitted when an account's redemption lock is refreshed by a deposit or mint
     * @param account The address of the affected account
     * @param redemptionDelay The unlock timestamp effective under the redemption delay at the time of the deposit
     */
    event RedemptionDelayForAccountUpdated(address account, uint256 redemptionDelay);

    /**
     * @notice Retrieves the effective unlock timestamp for a specific account
     * @dev Computed at read time as lock start time (last deposit/mint) + the current
     * redemption delay, so every change of the vault-wide delay immediately moves the
     * unlock time of all accounts, in both directions
     * @param account_ The address to check the lock time for
     * @return The timestamp until which the account is locked under the current redemption delay,
     * possibly in the past when the lock has already expired, 0 if the account never deposited
     * @custom:security This value should be checked before allowing withdrawals
     */
    function getAccountLockTime(address account_) internal view returns (uint256) {
        uint256 lockStartTime = IporFusionAccessManagersStorageLib.getRedemptionLockStartTime(account_);
        if (lockStartTime == 0) {
            return 0;
        }
        return lockStartTime + IporFusionAccessManagersStorageLib.getRedemptionDelay();
    }

    /**
     * @notice Enforces redemption delay rules based on function calls
     * @dev Implements the following rules:
     * 1. For withdrawals/redemptions/transfers: Checks if the account is still locked under the current delay
     * 2. For deposits/mints: Records the lock start time
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
            uint256 unlockTime = getAccountLockTime(account_);
            if (unlockTime > block.timestamp) {
                revert AccountIsLocked(unlockTime);
            }
        } else if (sig_ == DEPOSIT_SELECTOR || sig_ == MINT_SELECTOR || sig_ == DEPOSIT_WITH_PERMIT_SELECTOR) {
            IporFusionAccessManagersStorageLib.setRedemptionLockStartTime(account_);
            emit RedemptionDelayForAccountUpdated(account_, getAccountLockTime(account_));
        }
    }
}
