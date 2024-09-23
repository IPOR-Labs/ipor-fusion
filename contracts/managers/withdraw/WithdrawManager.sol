// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {WithdrawManagerStorageLib} from "./WithdrawManagerStorageLib.sol";
import {WithdrawRequest} from "./WithdrawManagerStorageLib.sol";

struct WithdrawRequestInfo {
    uint256 amount;
    uint256 endWithdrawWindow;
    bool canWithdraw;
    uint256 withdrawWindowLength;
}

contract WithdrawManager is AccessManagedUpgradeable {
    constructor(address accessManager_) {
        initialize(accessManager_);
    }

    function initialize(address accessManager_) internal initializer {
        super.__AccessManaged_init(accessManager_);
    }

    function canWithdraw(address account_, uint256 amount_) external restricted returns (bool) {
        uint256 releaseFoundsTimestamp = WithdrawManagerStorageLib.getReleaseFounds();
        WithdrawRequest memory request = WithdrawManagerStorageLib.getWithdrawRequest(account_);

        if (request.endWithdrawWindow == 0) {
            return false;
        }

        if (
            block.timestamp >= releaseFoundsTimestamp &&
            block.timestamp >= request.endWithdrawWindow - WithdrawManagerStorageLib.getWithdrawWindowLength() &&
            block.timestamp <= request.endWithdrawWindow &&
            request.amount >= amount_
        ) {
            WithdrawManagerStorageLib.deleteWithdrawRequest(account_);
            return true;
        }
        return false;
    }

    function request(uint256 amount) external {
        WithdrawManagerStorageLib.updateWithdrawRequest(amount);
    }

    function releaseFounds() external restricted {
        WithdrawManagerStorageLib.releaseFounds();
    }

    function updateWithdrawWindow(uint256 window) external restricted {
        WithdrawManagerStorageLib.updateWithdrawWindowLength(window);
    }

    function getWithdrawWindow() external view returns (uint256) {
        return WithdrawManagerStorageLib.getWithdrawWindowLength();
    }

    function requestInfo(address account_) external view returns (WithdrawRequestInfo memory) {
        uint256 withdrawWindow = WithdrawManagerStorageLib.getWithdrawWindowLength();
        uint256 releaseFoundsTimestamp = WithdrawManagerStorageLib.getReleaseFounds();
        WithdrawRequest memory request = WithdrawManagerStorageLib.getWithdrawRequest(account_);
        return
            WithdrawRequestInfo({
                amount: request.amount,
                endWithdrawWindow: request.endWithdrawWindow,
                canWithdraw: block.timestamp >= request.endWithdrawWindow - withdrawWindow &&
                    block.timestamp <= request.endWithdrawWindow &&
                    block.timestamp >= releaseFoundsTimestamp,
                withdrawWindowLength: withdrawWindow
            });
    }
}
