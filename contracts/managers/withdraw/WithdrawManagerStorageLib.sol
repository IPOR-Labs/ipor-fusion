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
    uint32 lastReleaseFundsTimestamp;
    /// @dev Amount of funds released
    uint128 amountToRelease;
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
    /// @param releaseTimestamp Timestamp when funds were released
    /// @param amountToRelease Amount of funds released
    event ReleaseFundsUpdated(uint32 releaseTimestamp, uint128 amountToRelease);

    /// @notice Thrown when attempting to set withdraw window length to zero
    error WithdrawWindowLengthCannotBeZero();
    /// @notice Thrown when attempting to release funds with an invalid amount
    error WithdrawManagerInvalidAmountToRelease(uint256 amount_);

    // Storage slot constants
    /// @dev Storage slot for withdraw window configuration
    bytes32 private constant WITHDRAW_WINDOW_IN_SECONDS =
        0xc98a13e0ed3915d36fc042835990f5c6fbf2b2570bd63878dcd560ca2b767c00;

    /// @dev Storage slot for withdraw requests mapping
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.withdraw.manager.wirgdraw.requests")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WITHDRAW_REQUESTS = 0x88d141dcaacfb8523e39ee7fba7c6f591450286f42f9c7069cc072812d539200;

    // todo: update bytes32 hash
    /// @dev Storage slot for last release funds timestamp
    bytes32 private constant LAST_RELEASE_FUNDS = 0x6603575a0b471dee79b9613aa260e2a8f3515603a898fdc76d6849fcd1ac7800;

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
            releaseFundsResult.slot := LAST_RELEASE_FUNDS
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
    /// @param requester_ Address creating the withdraw request
    /// @param amount_ Amount to withdraw in underlying token decimals
    /// @dev Sets endWithdrawWindowTimestamp based on current time plus window length
    function updateWithdrawRequest(address requester_, uint256 amount_) internal {
        uint256 withdrawWindowLength = getWithdrawWindowInSeconds();
        WithdrawRequest memory request = WithdrawRequest({
            amount: amount_.toUint128(),
            endWithdrawWindowTimestamp: block.timestamp.toUint32() + withdrawWindowLength.toUint32()
        });

        _getWithdrawRequests().requests[requester_] = request;

        emit WithdrawRequestUpdated(requester_, amount_, request.endWithdrawWindowTimestamp);
    }

    /// @notice Deletes a withdraw request for an account
    /// @param account_ Address whose request should be deleted
    /// @param amount_ Amount of funds released
    function deleteWithdrawRequest(address account_, uint256 amount_) internal {
        delete _getWithdrawRequests().requests[account_];
        ReleaseFunds storage releaseFundsLocal = _getReleaseFunds();
        uint128 approvedAmountToRelase = releaseFundsLocal.amountToRelease;

        if (approvedAmountToRelase >= amount_) {
            releaseFundsLocal.amountToRelease = approvedAmountToRelase - amount_.toUint128();
            emit WithdrawRequestUpdated(account_, amount_, 0);
        } else {
            revert WithdrawManagerInvalidAmountToRelease(amount_);
        }
    }

    /// @notice Gets the timestamp of the last funds release
    /// @return Timestamp of the last funds release
    function getLastReleaseFundsTimestamp() internal view returns (uint256) {
        return _getReleaseFunds().lastReleaseFundsTimestamp;
    }

    function getAmountToRelease() internal view returns (uint256) {
        return uint256(_getReleaseFunds().amountToRelease);
    }

    /// @notice Updates the last funds release timestamp
    /// @param timestamp_ New timestamp to set
    /// @param amountToRelease_ Amount of funds released
    function releaseFunds(uint256 timestamp_, uint256 amountToRelease_) internal {
        ReleaseFunds storage releaseFundsLocal = _getReleaseFunds();
        releaseFundsLocal.lastReleaseFundsTimestamp = timestamp_.toUint32();
        releaseFundsLocal.amountToRelease = amountToRelease_.toUint128();
        emit ReleaseFundsUpdated(timestamp_.toUint32(), amountToRelease_.toUint128());
    }
}
