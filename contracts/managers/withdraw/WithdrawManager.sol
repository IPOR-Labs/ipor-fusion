// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {WithdrawManagerStorageLib} from "./WithdrawManagerStorageLib.sol";
import {WithdrawRequest} from "./WithdrawManagerStorageLib.sol";

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
contract WithdrawManager is AccessManagedUpgradeable {
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
        WithdrawManagerStorageLib.updateWithdrawRequest(msg.sender, amount_);
    }

    function releaseFunds() external restricted {
        WithdrawManagerStorageLib.releaseFunds();
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
        return
            block.timestamp >= endWithdrawWindowTimestamp - withdrawWindow &&
            block.timestamp <= endWithdrawWindowTimestamp &&
            block.timestamp >= releaseFundsTimestamp;
    }
}
