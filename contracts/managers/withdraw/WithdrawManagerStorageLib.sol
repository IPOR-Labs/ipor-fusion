// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

struct WithdrawRequest {
    /// @dev The amount of the request, in underlying token decimals
    uint128 amount;
    /// @dev The end of the withdraw window, to calculate requestTimeStamp +  withdrawWindowInSeconds;
    uint32 endWithdrawWindowTimestamp;
}

struct WithdrawRequests {
    mapping(address account => WithdrawRequest request) requests;
}

struct WithdrawWindow {
    /// @dev The length of the withdraw window, in seconds
    uint256 withdrawWindowInSeconds;
}

struct ReleaseFunds {
    /// @dev The last time the funds were released
    uint256 lastReleaseFundsTimestamp;
}

library WithdrawManagerStorageLib {
    using SafeCast for uint256;

    event WithdrawWindowLengthUpdated(uint256 withdrawWindowLength);
    event WithdrawRequestUpdated(address account, uint256 amount, uint32 endWithdrawWindow);
    event ReleaseFundsUpdated(uint256 releaseFunds);

    error WithdrawWindowLengthCannotBeZero();

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.withdrawWindowLength")) - 1)) & ~bytes32(uint256(0xff)); TODO update
    bytes32 private constant WITHDRAW_WINDOW_IN_SECONDS =
        0x396fcc76a9b5b2fd5e6b074a9e52f50f355590ed8495194e4303f1c99aee5900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.withdrawRequests")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant WITHDRAW_REQUESTS = 0x5f79d61c9d5139383097775e8e8bbfd941634f6602a18bee02d4f80d80c89f00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.lastReleaseFunds")) - 1)) & ~bytes32(uint256(0xff)); TODO update
    bytes32 private constant LAST_RELEASE_FUNDS_TIMESTAMP =
        0x515911132aa14e230ad5245b1622bd7ca9c33d320ff7e4eb38ef95aeffc9eb00;

    function _getWithdrawWindowLength() private view returns (WithdrawWindow storage withdrawWindow) {
        assembly {
            withdrawWindow.slot := WITHDRAW_WINDOW_IN_SECONDS
        }
    }

    function _getWithdrawRequests() private view returns (WithdrawRequests storage requests) {
        assembly {
            requests.slot := WITHDRAW_REQUESTS
        }
    }

    function _getReleaseFunds() private view returns (ReleaseFunds storage releaseFunds) {
        assembly {
            releaseFunds.slot := LAST_RELEASE_FUNDS_TIMESTAMP
        }
    }

    function updateWithdrawWindowLength(uint256 withdrawWindowLength_) internal {
        if (withdrawWindowLength_ == 0) {
            revert WithdrawWindowLengthCannotBeZero();
        }

        WithdrawWindow storage withdrawWindow = _getWithdrawWindowLength();
        withdrawWindow.withdrawWindowInSeconds = withdrawWindowLength_;

        emit WithdrawWindowLengthUpdated(withdrawWindowLength_);
    }

    function getWithdrawWindowInSeconds() internal view returns (uint256) {
        return _getWithdrawWindowLength().withdrawWindowInSeconds;
    }

    function getWithdrawRequest(address account_) internal view returns (WithdrawRequest memory) {
        return _getWithdrawRequests().requests[account_];
    }

    function updateWithdrawRequest(address requester, uint256 amount_) internal {
        uint256 withdrawWindowLength = getWithdrawWindowInSeconds();
        WithdrawRequest memory request = WithdrawRequest({
            amount: amount_.toUint128(),
            endWithdrawWindowTimestamp: block.timestamp.toUint32() + withdrawWindowLength.toUint32()
        });

        _getWithdrawRequests().requests[requester] = request;

        emit WithdrawRequestUpdated(requester, amount_, request.endWithdrawWindowTimestamp);
    }

    function deleteWithdrawRequest(address account_) internal {
        delete _getWithdrawRequests().requests[account_];
        emit WithdrawRequestUpdated(account_, 0, 0);
    }

    function getLastReleaseFundsTimestamp() internal view returns (uint256) {
        return _getReleaseFunds().lastReleaseFundsTimestamp;
    }

    function releaseFunds() internal {
        ReleaseFunds storage releaseFunds = _getReleaseFunds();
        releaseFunds.lastReleaseFundsTimestamp = block.timestamp;
        emit ReleaseFundsUpdated(block.timestamp);
    }
}
