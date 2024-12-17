// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Represents a single withdraw request from a user
/// @dev All amounts are stored in underlying token decimals
struct WithdrawRequest {
    /// @dev The requested withdrawal amount in underlying token decimals
    uint128 amount;
    /// @dev Timestamp when the withdraw window expires (requestTimeStamp + withdrawWindowInSeconds)
    uint32 endWithdrawWindowTimestamp;
}

/// @notice Storage structure for mapping user addresses to their withdraw requests
struct WithdrawRequests {
    /// @dev Maps user addresses to their active withdraw requests
    mapping(address account => WithdrawRequest request) requests;
}

/// @notice Configuration for the withdrawal time window
struct WithdrawWindow {
    /// @dev Duration of the withdraw window in seconds
    uint256 withdrawWindowInSeconds;
}

/// @notice Tracks the timestamp of the last funds release
struct ReleaseFunds {
    /// @dev Timestamp of the most recent funds release
    uint256 lastReleaseFundsTimestamp;
}

/// @title WithdrawManagerStorageLib
/// @notice Library managing storage layout and operations for the withdrawal system
/// @dev Uses assembly for storage slot access and implements withdraw request lifecycle
library WithdrawManagerStorageLib {
    using SafeCast for uint256;

    /// @notice Emitted when the withdraw window length is updated
    /// @param withdrawWindowLength New length of the withdraw window in seconds
    event WithdrawWindowLengthUpdated(uint256 withdrawWindowLength);

    /// @notice Emitted when a withdraw request is created or updated
    /// @param account Address of the account making the request
    /// @param amount Amount requested for withdrawal
    /// @param endWithdrawWindow Timestamp when the withdraw window expires
    event WithdrawRequestUpdated(address account, uint256 amount, uint32 endWithdrawWindow);

    /// @notice Emitted when funds are released
    /// @param releaseFunds Timestamp when funds were released
    event ReleaseFundsUpdated(uint256 releaseFunds);

    /// @notice Thrown when attempting to set withdraw window length to zero
    error WithdrawWindowLengthCannotBeZero();

    // Storage slot constants
    /// @dev Storage slot for withdraw window configuration
    bytes32 private constant WITHDRAW_WINDOW_IN_SECONDS =
        0xc98a13e0ed3915d36fc042835990f5c6fbf2b2570bd63878dcd560ca2b767c00;

    /// @dev Storage slot for withdraw requests mapping
    bytes32 private constant WITHDRAW_REQUESTS = 0x5f79d61c9d5139383097775e8e8bbfd941634f6602a18bee02d4f80d80c89f00;

    /// @dev Storage slot for last release funds timestamp
    bytes32 private constant LAST_RELEASE_FUNDS_TIMESTAMP =
        0x6603575a0b471dee79b9613aa260e2a8f3515603a898fdc76d6849fcd1ac7800;

    /// @dev Retrieves the withdraw window configuration from storage
    function _getWithdrawWindowLength() private view returns (WithdrawWindow storage withdrawWindow) {
        assembly {
            withdrawWindow.slot := WITHDRAW_WINDOW_IN_SECONDS
        }
    }

    /// @dev Retrieves the withdraw requests mapping from storage
    function _getWithdrawRequests() private view returns (WithdrawRequests storage requests) {
        assembly {
            requests.slot := WITHDRAW_REQUESTS
        }
    }

    /// @dev Retrieves the release funds timestamp from storage
    function _getReleaseFunds() private view returns (ReleaseFunds storage releaseFundsResult) {
        assembly {
            releaseFundsResult.slot := LAST_RELEASE_FUNDS_TIMESTAMP
        }
    }

    /// @notice Updates the length of the withdraw window
    /// @param withdrawWindowLength_ New length of the withdraw window in seconds
    /// @dev Reverts if the new window length is zero
    function updateWithdrawWindowLength(uint256 withdrawWindowLength_) internal {
        if (withdrawWindowLength_ == 0) {
            revert WithdrawWindowLengthCannotBeZero();
        }

        WithdrawWindow storage withdrawWindow = _getWithdrawWindowLength();
        withdrawWindow.withdrawWindowInSeconds = withdrawWindowLength_;

        emit WithdrawWindowLengthUpdated(withdrawWindowLength_);
    }

    /// @notice Gets the current withdraw window length in seconds
    /// @return Current withdraw window length
    function getWithdrawWindowInSeconds() internal view returns (uint256) {
        return _getWithdrawWindowLength().withdrawWindowInSeconds;
    }

    /// @notice Retrieves a withdraw request for a specific account
    /// @param account_ Address of the account to query
    /// @return WithdrawRequest struct containing the request details
    function getWithdrawRequest(address account_) internal view returns (WithdrawRequest memory) {
        return _getWithdrawRequests().requests[account_];
    }

    /// @notice Creates or updates a withdraw request for an account
    /// @param requester Address creating the withdraw request
    /// @param amount_ Amount to withdraw in underlying token decimals
    /// @dev Sets endWithdrawWindowTimestamp based on current time plus window length
    function updateWithdrawRequest(address requester, uint256 amount_) internal {
        uint256 withdrawWindowLength = getWithdrawWindowInSeconds();
        WithdrawRequest memory request = WithdrawRequest({
            amount: amount_.toUint128(),
            endWithdrawWindowTimestamp: block.timestamp.toUint32() + withdrawWindowLength.toUint32()
        });

        _getWithdrawRequests().requests[requester] = request;

        emit WithdrawRequestUpdated(requester, amount_, request.endWithdrawWindowTimestamp);
    }

    /// @notice Deletes a withdraw request for an account
    /// @param account_ Address whose request should be deleted
    function deleteWithdrawRequest(address account_) internal {
        delete _getWithdrawRequests().requests[account_];
        emit WithdrawRequestUpdated(account_, 0, 0);
    }

    /// @notice Gets the timestamp of the last funds release
    /// @return Timestamp of the last funds release
    function getLastReleaseFundsTimestamp() internal view returns (uint256) {
        return _getReleaseFunds().lastReleaseFundsTimestamp;
    }

    /// @notice Updates the last funds release timestamp
    /// @param timestamp_ New timestamp to set
    function releaseFunds(uint256 timestamp_) internal {
        ReleaseFunds storage releaseFundsLocal = _getReleaseFunds();
        releaseFundsLocal.lastReleaseFundsTimestamp = timestamp_;
        emit ReleaseFundsUpdated(timestamp_);
    }
}
