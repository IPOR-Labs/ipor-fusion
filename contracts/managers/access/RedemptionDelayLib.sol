// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVault} from "../../vaults/PlasmaVault.sol";
import {IporFusionAccessManagersStorageLib} from "./IporFusionAccessManagersStorageLib.sol";

bytes4 constant DEPOSIT_SELECTOR = PlasmaVault.deposit.selector;
bytes4 constant DEPOSIT_WITH_PERMIT_SELECTOR = PlasmaVault.depositWithPermit.selector;
bytes4 constant MINT_SELECTOR = PlasmaVault.mint.selector;
bytes4 constant WITHDRAW_SELECTOR = PlasmaVault.withdraw.selector;
bytes4 constant REDEEM_SELECTOR = PlasmaVault.redeem.selector;

/// @title Library for the redemption delay responsible for locking accounts for withdraw and redeem functions after deposit or mint functions.
library RedemptionDelayLib {
    error AccountIsLocked(uint256 unlockTime);

    /// @notice Get the account lock time for a redemption function (withdraw, redeem)
    /// @param account_ The account to check the lock time
    /// @return The lock time in seconds
    /// @dev The lock time is the time the account is locked for withdraw and redeem functions after deposit or mint functions
    function getAccountLockTime(address account_) internal view returns (uint256) {
        return IporFusionAccessManagersStorageLib.getRedemptionLocks().redemptionLock[account_];
    }

    /// @notice Check if account is locked for a specific function (correlation withdraw, redeem functions to deposit, mint functions)
    /// @dev When deposit or mint functions are called, the account is locked for withdraw and redeem functions for a specific time defined by the redemption delay.
    function lockChecks(address account_, bytes4 sig_) internal {
        if (sig_ == WITHDRAW_SELECTOR || sig_ == REDEEM_SELECTOR) {
            uint256 unlockTime = IporFusionAccessManagersStorageLib.getRedemptionLocks().redemptionLock[account_];
            if (unlockTime > block.timestamp) {
                revert AccountIsLocked(unlockTime);
            }
        } else if (sig_ == DEPOSIT_SELECTOR || sig_ == MINT_SELECTOR || sig_ == DEPOSIT_WITH_PERMIT_SELECTOR) {
            IporFusionAccessManagersStorageLib.setRedemptionLocks(account_);
        }
    }
}
