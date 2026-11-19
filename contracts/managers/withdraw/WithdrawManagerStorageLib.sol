// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Represents a single withdraw request from a user
/// @dev All amounts are stored in underlying token decimals
struct WithdrawRequest {
    /// @dev The requested withdrawal shares
    uint128 shares;
    /// @dev Timestamp when the withdraw window expires (requestTimeStamp + withdrawWindowInSeconds). The request time
    /// is the filing time, or the end of the requester's redemption lock when it was still locked at filing (IL-9531)
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

struct RequestFee {
    /// @dev The fee amount in 18 decimals precision
    uint256 fee;
}

struct WithdrawFee {
    /// @dev The fee amount in 18 decimals precision
    uint256 fee;
}

struct PlasmaVaultAddress {
    /// @dev The address of the plasma vault
    address plasmaVault;
    /// @dev Whether the vault keeps request caps (PlasmaVault.getRequestCap, IL-9531). False for a vault deployed before
    /// IL-9531 that got this WithdrawManager later (UpdateWithdrawManagerMaintenanceFuse). Same slot as the address
    bool vaultKeepsRequestCaps;
}

/// @notice Tracks the timestamp of the last funds release
struct ReleaseFunds {
    /// @dev Timestamp of the most recent funds release
    uint32 lastReleaseFundsTimestamp;
    /// @dev Amount of funds released
    uint128 sharesToRelease;
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
    /// @param shares Number of shares requested for withdrawal
    /// @param endWithdrawWindow Timestamp when the withdraw window expires
    event WithdrawRequestUpdated(address account, uint256 shares, uint32 endWithdrawWindow);

    /// @notice Emitted when shares are released for withdrawal
    /// @param releaseTimestamp Timestamp when shares were released
    /// @param sharesToRelease Number of shares released for withdrawal
    event ReleaseFundsUpdated(uint32 releaseTimestamp, uint128 sharesToRelease);

    /// @notice Thrown when attempting to set withdraw window length to zero
    error WithdrawWindowLengthCannotBeZero();
    /// @notice Thrown when attempting to set withdraw window length above MAX_WITHDRAW_WINDOW
    /// @param withdrawWindowLength Requested length of the withdraw window in seconds
    /// @param maxWithdrawWindow Maximum allowed length of the withdraw window in seconds
    error WithdrawWindowLengthAboveMaximum(uint256 withdrawWindowLength, uint256 maxWithdrawWindow);
    /// @notice Thrown when attempting to release funds with an invalid amount
    error WithdrawManagerInvalidSharesToRelease(uint256 amount_);

    /// @notice Thrown when attempting to set plasma vault address to zero
    error PlasmaVaultAddressCannotBeZero();

    /// @notice Emitted when the request fee is updated
    /// @param fee New fee amount
    event RequestFeeUpdated(uint256 fee);

    /// @notice Emitted when the withdraw fee is updated
    /// @param fee New fee amount
    event WithdrawFeeUpdated(uint256 fee);

    /// @notice Emitted when the plasma vault address is updated
    /// @param plasmaVaultAddress New plasma vault address
    event PlasmaVaultAddressUpdated(address plasmaVaultAddress);

    /// @notice Emitted with every plasma vault address update: whether that vault keeps request caps (IL-9531)
    /// @param vaultKeepsRequestCaps False for a vault deployed before IL-9531 (no shares-held-since-request check)
    event VaultRequestCapsSupportUpdated(bool vaultKeepsRequestCaps);

    /// @notice Thrown when attempting to release funds with an invalid timestamp
    error WithdrawManagerInvalidTimestamp(uint256 lastReleaseFundsTimestamp, uint256 newReleaseFundsTimestamp);

    /// @notice Maximum allowed length of the withdraw window (IL-9675)
    /// @dev A longer window is a configuration mistake that would otherwise surface later, as a revert in every request
    uint256 internal constant MAX_WITHDRAW_WINDOW = 365 days;

    // Storage slot constants
    /// @dev Storage slot for withdraw window configuration
    bytes32 private constant WITHDRAW_WINDOW_IN_SECONDS =
        0xc98a13e0ed3915d36fc042835990f5c6fbf2b2570bd63878dcd560ca2b767c00;

    /// @dev Storage slot for withdraw requests mapping
    bytes32 private constant WITHDRAW_REQUESTS = 0x5f79d61c9d5139383097775e8e8bbfd941634f6602a18bee02d4f80d80c89f00;

    /// @dev Storage slot for last release funds
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.withdraw.manager.wirgdraw.requests")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAST_RELEASE_FUNDS = 0x88d141dcaacfb8523e39ee7fba7c6f591450286f42f9c7069cc072812d539200;

    /// @dev Storage slot for request fee todo check if this is correct
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.withdraw.manager.requests.fee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REQUEST_FEE = 0x97f346e04a16e2eb518a1ffef159e6c87d3eaa2076a90372e699cdb1af482400;

    /// @dev Storage slot for withdraw fee
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.withdraw.manager.withdraw.fee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WITHDRAW_FEE = 0x1dc9c20e1601df7037c9a39067c6ecf51e88a43bc6cd86f115a2c29716b36600;

    /// @dev Storage slot for plasma vault address
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.withdraw.manager.plasma.vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PLASMA_VAULT_ADDRESS = 0xeb1948ad07cc64342983d8dc0a37729fcf2d17dcf49a1e3705ff0fa01e7d9400;

    function getRequestFee() internal view returns (uint256) {
        return _getRequestFee().fee;
    }

    function setRequestFee(uint256 fee_) internal {
        RequestFee storage requestFee = _getRequestFee();
        requestFee.fee = fee_;

        emit RequestFeeUpdated(fee_);
    }

    function getWithdrawFee() internal view returns (uint256) {
        return _getWithdrawFee().fee;
    }

    function setWithdrawFee(uint256 fee_) internal {
        WithdrawFee storage withdrawFee = _getWithdrawFee();
        withdrawFee.fee = fee_;

        emit WithdrawFeeUpdated(fee_);
    }

    /// @notice Updates the length of the withdraw window
    /// @param withdrawWindowLength_ New length of the withdraw window in seconds
    /// @dev Reverts if the new window length is zero or greater than MAX_WITHDRAW_WINDOW (365 days inclusive)
    function updateWithdrawWindowLength(uint256 withdrawWindowLength_) internal {
        if (withdrawWindowLength_ == 0) {
            revert WithdrawWindowLengthCannotBeZero();
        }
        if (withdrawWindowLength_ > MAX_WITHDRAW_WINDOW) {
            revert WithdrawWindowLengthAboveMaximum(withdrawWindowLength_, MAX_WITHDRAW_WINDOW);
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
    /// @param shares_ Shares to withdraw
    /// @param lockEndTimestamp_ End of the requester's redemption lock at filing time, 0 if not locked (IL-9531)
    /// @dev Sets endWithdrawWindowTimestamp to the request time plus window length. The request time is the current
    /// time, or the lock end when it is later: a request filed during the lock starts when the lock ends (IL-9531)
    function updateWithdrawRequest(address requester_, uint256 shares_, uint256 lockEndTimestamp_) internal {
        uint256 withdrawWindowLength = getWithdrawWindowInSeconds();
        uint256 requestTimestamp = lockEndTimestamp_ > block.timestamp ? lockEndTimestamp_ : block.timestamp;
        WithdrawRequest memory request = WithdrawRequest({
            shares: shares_.toUint128(),
            endWithdrawWindowTimestamp: requestTimestamp.toUint32() + withdrawWindowLength.toUint32()
        });

        _getWithdrawRequests().requests[requester_] = request;

        emit WithdrawRequestUpdated(requester_, request.shares, request.endWithdrawWindowTimestamp);
    }

    function decreaseSharesFromWithdrawRequest(address account_, uint256 shares_) internal {
        WithdrawRequest storage request = _getWithdrawRequests().requests[account_];
        if (request.shares >= shares_) {
            request.shares -= shares_.toUint128();
            emit WithdrawRequestUpdated(account_, request.shares, request.endWithdrawWindowTimestamp);
        }
    }

    /// @notice Deletes a withdraw request for an account
    /// @param account_ Address whose request should be deleted
    /// @param amount_ Amount of funds released
    function deleteWithdrawRequest(address account_, uint256 amount_) internal {
        ReleaseFunds storage releaseFundsLocal = _getReleaseFunds();
        uint128 approvedAmountToRelase = releaseFundsLocal.sharesToRelease;

        if (approvedAmountToRelase >= amount_) {
            releaseFundsLocal.sharesToRelease = approvedAmountToRelase - amount_.toUint128();
            emit WithdrawRequestUpdated(account_, 0, 0);
        } else {
            revert WithdrawManagerInvalidSharesToRelease(amount_);
        }
        delete _getWithdrawRequests().requests[account_];
    }

    /// @notice Gets the timestamp of the last funds release
    /// @return Timestamp of the last funds release
    function getLastReleaseFundsTimestamp() internal view returns (uint256) {
        return _getReleaseFunds().lastReleaseFundsTimestamp;
    }

    function getSharesToRelease() internal view returns (uint256) {
        return uint256(_getReleaseFunds().sharesToRelease);
    }

    /// @notice Updates the last funds release timestamp
    /// @param newReleaseFundsTimestamp_ New release funds timestamp to set
    /// @param sharesToRelease_ Amount of funds released
    function releaseFunds(uint256 newReleaseFundsTimestamp_, uint256 sharesToRelease_) internal {
        ReleaseFunds storage releaseFundsLocal = _getReleaseFunds();

        uint256 lastReleaseFundsTimestamp = releaseFundsLocal.lastReleaseFundsTimestamp;

        if (lastReleaseFundsTimestamp > newReleaseFundsTimestamp_) {
            revert WithdrawManagerInvalidTimestamp(lastReleaseFundsTimestamp, newReleaseFundsTimestamp_);
        }

        releaseFundsLocal.lastReleaseFundsTimestamp = newReleaseFundsTimestamp_.toUint32();
        releaseFundsLocal.sharesToRelease = sharesToRelease_.toUint128();

        emit ReleaseFundsUpdated(newReleaseFundsTimestamp_.toUint32(), sharesToRelease_.toUint128());
    }

    function decreaseSharesToRelease(uint256 shares_) internal {
        ReleaseFunds storage releaseFundsLocal = _getReleaseFunds();
        if (releaseFundsLocal.sharesToRelease >= shares_) {
            releaseFundsLocal.sharesToRelease -= shares_.toUint128();
            emit ReleaseFundsUpdated(releaseFundsLocal.lastReleaseFundsTimestamp, releaseFundsLocal.sharesToRelease);
        } else {
            revert WithdrawManagerInvalidSharesToRelease(shares_);
        }
    }

    function setPlasmaVaultAddress(address plasmaVaultAddress_, bool vaultKeepsRequestCaps_) internal {
        if (plasmaVaultAddress_ == address(0)) {
            revert PlasmaVaultAddressCannotBeZero();
        }

        PlasmaVaultAddress storage plasmaVaultAddress = _getPlasmaVaultAddress();
        plasmaVaultAddress.plasmaVault = plasmaVaultAddress_;
        plasmaVaultAddress.vaultKeepsRequestCaps = vaultKeepsRequestCaps_;

        emit PlasmaVaultAddressUpdated(plasmaVaultAddress_);
        emit VaultRequestCapsSupportUpdated(vaultKeepsRequestCaps_);
    }

    function getPlasmaVaultAddress() internal view returns (address) {
        return _getPlasmaVaultAddress().plasmaVault;
    }

    /// @notice The plasma vault address and whether that vault keeps request caps, in one storage read (IL-9531)
    function getPlasmaVault() internal view returns (address plasmaVault, bool vaultKeepsRequestCaps) {
        PlasmaVaultAddress storage plasmaVaultAddress = _getPlasmaVaultAddress();
        return (plasmaVaultAddress.plasmaVault, plasmaVaultAddress.vaultKeepsRequestCaps);
    }

    function _getRequestFee() private pure returns (RequestFee storage requestFee) {
        assembly {
            requestFee.slot := REQUEST_FEE
        }
    }

    function _getWithdrawFee() private pure returns (WithdrawFee storage withdrawFee) {
        assembly {
            withdrawFee.slot := WITHDRAW_FEE
        }
    }

    /// @dev Retrieves the withdraw window configuration from storage
    function _getWithdrawWindowLength() private pure returns (WithdrawWindow storage withdrawWindow) {
        assembly {
            withdrawWindow.slot := WITHDRAW_WINDOW_IN_SECONDS
        }
    }

    /// @dev Retrieves the withdraw requests mapping from storage
    function _getWithdrawRequests() private pure returns (WithdrawRequests storage requests) {
        assembly {
            requests.slot := WITHDRAW_REQUESTS
        }
    }

    /// @dev Retrieves the release funds timestamp from storage
    function _getReleaseFunds() private pure returns (ReleaseFunds storage releaseFundsResult) {
        assembly {
            releaseFundsResult.slot := LAST_RELEASE_FUNDS
        }
    }

    function _getPlasmaVaultAddress() private pure returns (PlasmaVaultAddress storage plasmaVaultAddress) {
        assembly {
            plasmaVaultAddress.slot := PLASMA_VAULT_ADDRESS
        }
    }
}
