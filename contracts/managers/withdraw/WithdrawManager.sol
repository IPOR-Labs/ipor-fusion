// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {WithdrawManagerStorageLib} from "./WithdrawManagerStorageLib.sol";
import {WithdrawRequest} from "./WithdrawManagerStorageLib.sol";
import {ContextClient} from "../context/ContextClient.sol";

struct WithdrawRequestInfo {
    uint256 amount;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
}
/**
 * @title WithdrawManager
 * @notice Manages withdrawal requests and their processing for the IPOR Fusion protocol
 * @dev This contract handles the scheduling and execution of withdrawals with specific time windows
 *
 * Access Control:
 * - TECH_PLASMA_VAULT_ROLE: Required for canWithdrawAndUpdate
 * - ALPHA_ROLE: Required for releaseFunds
 * - ATOMIST_ROLE: Required for updateWithdrawWindow
 * - PUBLIC_ROLE: Can call request, getLastReleaseFundsTimestamp, getWithdrawWindow, and requestInfo
 */
contract WithdrawManager is AccessManagedUpgradeable, ContextClient {
    error WithdrawManagerInvalidTimestamp(uint256 timestamp_);

    constructor(address accessManager_) initializer {
        super.__AccessManaged_init(accessManager_);
    }

    /**
     * @notice Checks if the account can withdraw the specified amount and updates the withdraw request
     * @dev Only callable by PlasmaVault contract (TECH_PLASMA_VAULT_ROLE)
     * @param account_ The address of the account to check
     * @param amount_ The amount to check for withdrawal
     * @return bool True if the account can withdraw the specified amount, false otherwise
     * @custom:access TECH_PLASMA_VAULT_ROLE
     */
    function canWithdrawAndUpdate(address account_, uint256 amount_) external restricted returns (bool) {
        uint256 releaseFundsTimestamp = WithdrawManagerStorageLib.getLastReleaseFundsTimestamp();
        WithdrawRequest memory request = WithdrawManagerStorageLib.getWithdrawRequest(account_);

        if (request.endWithdrawWindowTimestamp == 0) {
            return false;
        }

        if (
            _canWithdraw(
                request.endWithdrawWindowTimestamp,
                WithdrawManagerStorageLib.getWithdrawWindowInSeconds(),
                releaseFundsTimestamp
            ) && request.amount >= amount_
        ) {
            WithdrawManagerStorageLib.deleteWithdrawRequest(account_);
            return true;
        }
        return false;
    }

    /**
     * @notice Creates a new withdrawal request
     * @dev Publicly accessible function
     * @param amount_ The amount requested for withdrawal
     * @custom:access Public
     */
    function request(uint256 amount_) external {
        WithdrawManagerStorageLib.updateWithdrawRequest(_msgSender(), amount_);
    }

    /**
     * @notice Updates the release funds timestamp to allow withdrawals after this point
     * @dev Only callable by accounts with ALPHA_ROLE
     * @param timestamp_ The timestamp to set as the release funds timestamp
     * @dev Reverts if the provided timestamp is in the future
     * @custom:access ALPHA_ROLE
     */
    function releaseFunds(uint256 timestamp_) external restricted {
        if (timestamp_ < block.timestamp) {
            WithdrawManagerStorageLib.releaseFunds(timestamp_);
        } else {
            revert WithdrawManagerInvalidTimestamp(timestamp_);
        }
    }

    /**
     * @notice Gets the last timestamp when funds were released for withdrawals
     * @dev Publicly accessible function
     * @return uint256 The timestamp of the last funds release
     * @custom:access Public
     */
    function getLastReleaseFundsTimestamp() external view returns (uint256) {
        return WithdrawManagerStorageLib.getLastReleaseFundsTimestamp();
    }

    /**
     * @notice Updates the withdrawal window duration
     * @dev Only callable by accounts with ATOMIST_ROLE
     * @param window_ The new withdrawal window duration in seconds
     * @custom:access ATOMIST_ROLE
     */
    function updateWithdrawWindow(uint256 window_) external restricted {
        WithdrawManagerStorageLib.updateWithdrawWindowLength(window_);
    }

    /**
     * @notice Gets the current withdrawal window duration
     * @dev Publicly accessible function
     * @return uint256 The withdrawal window duration in seconds
     * @custom:access Public
     */
    function getWithdrawWindow() external view returns (uint256) {
        return WithdrawManagerStorageLib.getWithdrawWindowInSeconds();
    }

    /**
     * @notice Gets detailed information about a withdrawal request
     * @dev Publicly accessible function
     * @param account_ The address to get withdrawal request information for
     * @return WithdrawRequestInfo Struct containing withdrawal request details
     * @custom:access Public
     */
    function requestInfo(address account_) external view returns (WithdrawRequestInfo memory) {
        uint256 withdrawWindow = WithdrawManagerStorageLib.getWithdrawWindowInSeconds();
        uint256 releaseFundsTimestamp = WithdrawManagerStorageLib.getLastReleaseFundsTimestamp();
        WithdrawRequest memory request = WithdrawManagerStorageLib.getWithdrawRequest(account_);
        return
            WithdrawRequestInfo({
                amount: request.amount,
                endWithdrawWindowTimestamp: request.endWithdrawWindowTimestamp,
                canWithdraw: _canWithdraw(request.endWithdrawWindowTimestamp, withdrawWindow, releaseFundsTimestamp),
                withdrawWindowInSeconds: withdrawWindow
            });
    }

    function _canWithdraw(
        uint256 endWithdrawWindowTimestamp,
        uint256 withdrawWindow,
        uint256 releaseFundsTimestamp
    ) private view returns (bool) {
        /// @dev endWithdrawWindowTimestamp - withdrawWindow = moment when user did request for withdraw
        return
            block.timestamp >= endWithdrawWindowTimestamp - withdrawWindow &&
            block.timestamp <= endWithdrawWindowTimestamp &&
            endWithdrawWindowTimestamp - withdrawWindow < releaseFundsTimestamp;
    }

    /// @notice Internal function to get the message sender from context
    /// @return The address of the message sender
    function _msgSender() internal view override returns (address) {
        return getSenderFromContext();
    }
}
