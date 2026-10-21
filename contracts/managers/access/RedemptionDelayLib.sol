// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVault} from "../../vaults/PlasmaVault.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
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
 * to prevent potential manipulation and protect the vault's assets. An owner-managed set of exempt
 * accounts behaves as if the vault-wide delay were 0 on exit (withdraw, redeem, transfer, transferFrom);
 * the exemption is evaluated at exit time, so granting and revoking take effect immediately
 * @custom:risk An exempt address can deposit and transfer fresh shares to a never-deposited address, which can
 * then withdraw at once. The lock check sees only the address the vault passes (caller, share owner, from), so
 * exempting a contract that acts for many users (a wrapper, router, zap or ContextManager-relayed path) exempts
 * all of its users at once. An exemption also removes the same-block deposit -> withdraw guard that a 1-second
 * delay provides. Only exempt trusted, specific addresses
 * @custom:security-contact security@ipor.io
 */
library RedemptionDelayLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @notice Error thrown when an account attempts to withdraw before their lock period expires
     * @param unlockTime The timestamp when the account will be unlocked
     */
    error AccountIsLocked(uint256 unlockTime);

    /**
     * @notice Emitted when an account's redemption lock is refreshed by a deposit or mint
     * @dev `unlockTime` is a snapshot under the redemption delay in force at the time of the deposit - it becomes
     * stale as soon as governance changes the delay. Indexers must persist `lockStartTime` and recompute the
     * unlock as lockStartTime + the delay from the latest IporFusionAccessManager.RedemptionDelayUpdated event
     * (or read getAccountLockTime on demand), never cache `unlockTime`
     * @param account The address of the affected account
     * @param lockStartTime The timestamp of the deposit or mint, the only durable value
     * @param unlockTime lockStartTime + the redemption delay at the time of the deposit (informational snapshot)
     */
    event RedemptionDelayForAccountUpdated(address account, uint256 lockStartTime, uint256 unlockTime);

    /**
     * @notice Emitted for every address of every setRedemptionDelayExemption call
     * @dev Also emitted when the state did not change (already exempt / not exempt)
     * @param account The address whose exemption was set
     * @param exempt True when the address was added to the exemptions, false when it was removed
     */
    event RedemptionDelayExemptionUpdated(address account, bool exempt);

    /**
     * @notice Retrieves the effective unlock timestamp for a specific account
     * @dev Computed at read time as lock start time (last deposit/mint) + the current
     * redemption delay, so every change of the vault-wide delay immediately moves the
     * unlock time of all accounts, in both directions. Exemption-agnostic: also returned for exempt accounts.
     * Frontends combine it with isRedemptionDelayExempt
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
     * 3. Exempt accounts pass the exit check of rule 1 (the exemption set is read only when the account
     * would otherwise revert, so a normal unlocked exit costs no extra storage read)
     * Gas: the lock start is written and the event emitted on EVERY deposit/mint, also when the redemption
     * delay is 0 (no early return). This is a deliberate cost (~20k gas on an account's first deposit, ~3-5k
     * afterwards, plus the event) accepted so that a later increase of the delay reaches accounts that
     * deposited while it was 0
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
            if (unlockTime > block.timestamp && !isRedemptionDelayExempt(account_)) {
                revert AccountIsLocked(unlockTime);
            }
        } else if (sig_ == DEPOSIT_SELECTOR || sig_ == MINT_SELECTOR || sig_ == DEPOSIT_WITH_PERMIT_SELECTOR) {
            IporFusionAccessManagersStorageLib.setRedemptionLockStartTime(account_);
            emit RedemptionDelayForAccountUpdated(account_, block.timestamp, getAccountLockTime(account_));
        }
    }

    /**
     * @notice Adds or removes a batch of accounts to/from the redemption delay exemptions
     * @dev Access control is performed by the caller. Reverts for the whole batch on a zero address.
     * Emits RedemptionDelayExemptionUpdated for every address, also when the state did not change.
     * An empty batch is a no-op and emits nothing. There is no cap on the batch length.
     * @param accounts_ The accounts to update
     * @param exempt_ True to exempt the accounts, false to remove the exemption
     */
    function setRedemptionDelayExemption(address[] calldata accounts_, bool exempt_) internal {
        EnumerableSet.AddressSet storage accounts = IporFusionAccessManagersStorageLib
            .getRedemptionDelayExemptions()
            .accounts;
        uint256 length = accounts_.length;
        address account;
        for (uint256 i; i < length; ++i) {
            account = accounts_[i];
            if (account == address(0)) {
                revert Errors.WrongAddress();
            }
            if (exempt_) {
                accounts.add(account);
            } else {
                accounts.remove(account);
            }
            emit RedemptionDelayExemptionUpdated(account, exempt_);
        }
    }

    /**
     * @notice Checks whether an account is exempt from the redemption delay
     * @param account_ The address to check
     * @return True when the account is exempt
     */
    function isRedemptionDelayExempt(address account_) internal view returns (bool) {
        return IporFusionAccessManagersStorageLib.getRedemptionDelayExemptions().accounts.contains(account_);
    }

    /**
     * @notice Retrieves all exempt accounts
     * @return The full list of exempt accounts, in EnumerableSet order
     */
    function getRedemptionDelayExemptions() internal view returns (address[] memory) {
        return IporFusionAccessManagersStorageLib.getRedemptionDelayExemptions().accounts.values();
    }

    /**
     * @notice Retrieves the number of exempt accounts
     * @return The number of exempt accounts
     */
    function getRedemptionDelayExemptionsCount() internal view returns (uint256) {
        return IporFusionAccessManagersStorageLib.getRedemptionDelayExemptions().accounts.length();
    }

    /**
     * @notice Retrieves a page of exempt accounts
     * @dev The order is the EnumerableSet order and is not stable across removals, so read all pages in
     * one block. Returns an empty array when offset_ >= count or limit_ is 0.
     * @param offset_ Index of the first account to return
     * @param limit_ Maximum number of accounts to return
     * @return page The requested page of exempt accounts
     */
    function getRedemptionDelayExemptionsAt(
        uint256 offset_,
        uint256 limit_
    ) internal view returns (address[] memory page) {
        EnumerableSet.AddressSet storage accounts = IporFusionAccessManagersStorageLib
            .getRedemptionDelayExemptions()
            .accounts;
        uint256 total = accounts.length();

        if (offset_ >= total) {
            return new address[](0);
        }

        uint256 size = total - offset_;
        if (size > limit_) {
            size = limit_;
        }

        page = new address[](size);
        for (uint256 i; i < size; ++i) {
            page[i] = accounts.at(offset_ + i);
        }
    }
}
