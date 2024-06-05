// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVault} from "../vaults/PlasmaVault.sol";
import {RewardsManagerStorageLib} from "./RewardsManagerStorageLib.sol";

bytes4 constant DEPOSIT_SELECTOR = PlasmaVault.deposit.selector;
bytes4 constant MINT_SELECTOR = PlasmaVault.mint.selector;
bytes4 constant WITHDRAW_SELECTOR = PlasmaVault.withdraw.selector;
bytes4 constant REDEEM_SELECTOR = PlasmaVault.redeem.selector;

library RedemptionDelayLib {
    error AccountIsLocked(uint256 unlockTime);

    function lockChecks(address account_, bytes4 sig_) internal {
        if (sig_ == WITHDRAW_SELECTOR || sig_ == REDEEM_SELECTOR) {
            uint256 unlockTime = RewardsManagerStorageLib.getRedemptionLocks().redemptionLock[account_];
            if (unlockTime > block.timestamp) {
                revert AccountIsLocked(unlockTime);
            }
        } else if (sig_ == DEPOSIT_SELECTOR || sig_ == MINT_SELECTOR) {
            RewardsManagerStorageLib.setRedemptionLocks(account_);
        }
    }

    function setRedemptionDelay(uint256 delay_) internal {
        RewardsManagerStorageLib.getRedemptionDelay().redemptionDelay = delay_;
    }

    function getAccountLockTime(address account_) internal view returns (uint256) {
        return RewardsManagerStorageLib.getRedemptionLocks().redemptionLock[account_];
    }
}
