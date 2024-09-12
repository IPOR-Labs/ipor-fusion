// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct WithdrawRequest {
    /// @dev The amount of the request, in underlying token decimals
    uint128 amount;
    /// @dev The end of the withdraw window, to calculate requestTimeStamp +  withdrawWindowLength;
    uint32 endWithdrawWindow;
}

struct WithdrawRequests {
    mapping(address account => WithdrawRequest request) requests;
}

struct WithdrawWindow {
    /// @dev The length of the withdraw window, in seconds
    uint256 withdrawWindowLength;
}

struct ReleaseFounds {
    /// @dev The last time the funds were released
    uint256 lastReleaseFounds;
}

library WithdrawManagerStorageLib {
    using SafeCast for uint256;

    event WithdrawWindowLengthUpdated(uint256 withdrawWindowLength);
    event WithdrawRequestUpdated(address account, uint256 amount, uint32 endWithdrawWindow);

    error WithdrawWindowLengthCannotBeZero();

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.withdrawWindowLength")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant WITHDRAW_WINDOW_LENGTH =
        0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc00; // TODO: change this

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.withdrawRequests")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant WITHDRAW_REQUESTS = 0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc11; // TODO: change this

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.lastReleaseFounds")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant LAST_RELEASE_FOUNDS =
    0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc22; // TODO: change this

    function _getWithdrawWindowLength() private view returns (WithdrawWindow storage withdrawWindow) {
        assembly {
            withdrawWindow.slot := WITHDRAW_WINDOW_LENGTH
        }
    }

    function _getWithdrawRequests() private view returns (WithdrawRequests storage requests) {
        assembly {
            requests.slot := WITHDRAW_REQUESTS
        }
    }

    function _getReleaseFounds() private view returns (ReleaseFounds storage releaseFounds) {
        assembly {
            releaseFounds.slot := LAST_RELEASE_FOUNDS
        }
    }

    function updateWithdrawWindowLength(uint256 withdrawWindowLength_) internal {
        if (withdrawWindowLength_ == 0) {
            revert WithdrawWindowLengthCannotBeZero();
        }

        WithdrawWindow storage withdrawWindow = _getWithdrawWindowLength();
        withdrawWindow.withdrawWindowLength = withdrawWindowLength_;

        emit WithdrawWindowLengthUpdated(withdrawWindowLength_);
    }

    function getWithdrawWindowLength() internal view returns (uint256) {
        return _getWithdrawWindowLength().withdrawWindowLength;
    }

    function getWithdrawRequest(address account_) internal view returns (WithdrawRequest memory) {
        return _getWithdrawRequests().requests[account_];
    }

    function updateWithdrawRequest(uint256 amount_) internal {
        uint256 withdrawWindowLength = getWithdrawWindowLength();
        WithdrawRequest memory request =  WithdrawRequest({
            amount: amount_.toUint128(),
            endWithdrawWindow: block.timestamp.toUint32() + withdrawWindowLength.toUint32()
        });

        _getWithdrawRequests().requests[msg.sender] = request;

        emit WithdrawRequestUpdated(msg.sender, amount_, request.endWithdrawWindow);
    }

    function releaseFounds() internal {
        ReleaseFounds storage releaseFounds = _getReleaseFounds();
        releaseFounds.lastReleaseFounds = block.timestamp;
    }
}
