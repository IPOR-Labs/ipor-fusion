// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {WithdrawManagerStorageLib} from "./WithdrawManagerStorageLib.sol";
import {WithdrawRequest} from "./WithdrawManagerStorageLib.sol";
import {ContextClient} from "../context/ContextClient.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";

struct WithdrawRequestInfo {
    uint256 amount;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
}
/**
 * @title WithdrawManager
 * @dev Manages withdrawal requests and their processing, ensuring that withdrawals are only allowed within specified windows and conditions.
 */
contract WithdrawManager is AccessManagedUpgradeable, ContextClient {
    error WithdrawManagerInvalidTimestamp(uint256 timestamp_);

    constructor(address accessManager_) {
        initialize(accessManager_);
    }

    function initialize(address accessManager_) internal initializer {
        super.__AccessManaged_init(accessManager_);
    }

    /**
     * @notice Checks if the account can withdraw the specified amount and updates the withdraw request.
     * @dev This function can only be executed by `plasmaVault` with role TECH_PLASMA_VAULT_ROLE.
     * @param account_ The address of the account to check.
     * @param amount_ The amount to check for withdrawal.
     * @return bool True if the account can withdraw the specified amount, false otherwise.
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

    function request(uint256 amount_) external {
        WithdrawManagerStorageLib.updateWithdrawRequest(_msgSender(), amount_);
    }

    /**
     * @notice Updates the release funds timestamp to allow withdrawals after this point
     * @dev This function can only be executed by accounts with the required role (restricted)
     * @param timestamp_ The timestamp to set as the release funds timestamp
     * @dev Reverts if the provided timestamp is in the future
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
     * @dev This function can be called by anyone to check when funds were last released
     * @return uint256 The timestamp of the last funds release
     */
    function getLastReleaseFundsTimestamp() external view returns (uint256) {
        return WithdrawManagerStorageLib.getLastReleaseFundsTimestamp();
    }

    function updateWithdrawWindow(uint256 window_) external restricted {
        WithdrawManagerStorageLib.updateWithdrawWindowLength(window_);
    }

    function getWithdrawWindow() external view returns (uint256) {
        return WithdrawManagerStorageLib.getWithdrawWindowInSeconds();
    }

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

    function _msgSender() internal view override returns (address) {
        return getSenderFromContext();
    }

    /**
     * @dev Reverts if the caller is not allowed to call the function identified by a selector. Panics if the calldata
     * is less than 4 bytes long.
     */
    function _checkCanCall(address caller_, bytes calldata data_) internal override {
        bytes4 sig = bytes4(data_[0:4]);
        // @dev for context manager 87ef0b87 - setupContext, db99bddd - clearContext
        if (sig == bytes4(0x87ef0b87) || sig == bytes4(0xdb99bddd)) {
            caller_ = msg.sender;
        }

        AccessManagedStorage storage $ = _getAccessManagedStorage();
        (bool immediate, uint32 delay) = AuthorityUtils.canCallWithDelay(
            authority(),
            caller_,
            address(this),
            bytes4(data_[0:4])
        );
        if (!immediate) {
            if (delay > 0) {
                $._consumingSchedule = true;
                IAccessManager(authority()).consumeScheduledOp(caller_, data_);
                $._consumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller_);
            }
        }
    }
}
