// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {WithdrawManagerStorageLib} from "./WithdrawManagerStorageLib.sol";
import {WithdrawRequest} from "./WithdrawManagerStorageLib.sol";
import {ContextClient} from "../context/ContextClient.sol";
import {IPlasmaVaultBase} from "../../interfaces/IPlasmaVaultBase.sol";

import {console2} from "forge-std/console2.sol";

struct WithdrawRequestInfo {
    uint256 shares;
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
    error WithdrawManagerInvalidAmountToRelease(
        uint256 amountToRelease,
        uint256 shares_,
        uint256 plasmaVaultBalanceOfUnallocatedShears
    );
    constructor(address accessManager_) initializer {
        super.__AccessManaged_init(accessManager_);
    }

    /**
     * @notice Creates a new withdrawal request
     * @dev Publicly accessible function
     * @param shares_ The amount requested for redeem, amount of shares to redeem
     * @custom:access Public
     */
    function request(uint256 shares_) external {
        uint256 feeRate = WithdrawManagerStorageLib.getRequestFee();
        if (feeRate > 0) {
            uint256 feeAmount = Math.mulDiv(shares_, feeRate, 1e18);
            WithdrawManagerStorageLib.updateWithdrawRequest(_msgSender(), shares_ - feeAmount);
            IPlasmaVaultBase(getPlasmaVaultAddress()).transferRequestFee(_msgSender(), address(this), feeAmount);
        } else {
            WithdrawManagerStorageLib.updateWithdrawRequest(_msgSender(), shares_);
        }
    }

    /**
     * @notice Checks if the account can withdraw the specified amount from a request
     * @dev Only callable by PlasmaVault contract (TECH_PLASMA_VAULT_ROLE)
     * @param account_ The address of the account to check
     * @param shares_ The amount to check for withdrawal
     * @return bool True if the account can withdraw the specified amount, false otherwise
     * @custom:access TECH_PLASMA_VAULT_ROLE
     */
    function canWithdrawFromRequest(address account_, uint256 shares_) external restricted returns (bool) {
        uint256 releaseFundsTimestamp = WithdrawManagerStorageLib.getLastReleaseFundsTimestamp();
        WithdrawRequest memory request = WithdrawManagerStorageLib.getWithdrawRequest(account_);

        if (
            _canWithdraw(
                request.endWithdrawWindowTimestamp,
                WithdrawManagerStorageLib.getWithdrawWindowInSeconds(),
                releaseFundsTimestamp
            ) && request.shares >= shares_
        ) {
            WithdrawManagerStorageLib.decreaseWithdrawRequest(account_, shares_);
            WithdrawManagerStorageLib.decreaseSharesToRelease(shares_);
            return true;
        }
        return false;
    }

    function canWithdrawFromUnallocated(
        address account_,
        uint256 shares_
    ) external restricted returns (uint256 feeSharesToBurn) {
        uint256 feeRate = WithdrawManagerStorageLib.getWithdrawFee();
        uint256 balanceOfPlasmaVault = ERC4626(ERC4626(msg.sender).asset()).balanceOf(msg.sender);
        uint256 plasmaVaultBalanceOfUnallocatedShears = ERC4626(msg.sender).convertToShares(balanceOfPlasmaVault);
        uint256 amountToRelease = WithdrawManagerStorageLib.getAmountToRelease();

        if (plasmaVaultBalanceOfUnallocatedShears < amountToRelease + shares_) {
            revert WithdrawManagerInvalidAmountToRelease(
                amountToRelease,
                shares_,
                plasmaVaultBalanceOfUnallocatedShears
            );
        }
        if (feeRate > 0) {
            uint256 feeAmount = Math.mulDiv(shares_, feeRate, 1e18);
            return feeAmount;
        }
        return 0;
    }

    /**
     * @notice Updates the release funds timestamp to allow withdrawals after this point
     * @dev Only callable by accounts with ALPHA_ROLE
     * @param timestamp_ The timestamp to set as the release funds timestamp
     * @param sharesToRelease_ Amount of shares released
     * @dev Reverts if the provided timestamp is in the future
     * @custom:access ALPHA_ROLE
     */
    function releaseFunds(uint256 timestamp_, uint256 sharesToRelease_) external restricted {
        if (timestamp_ < block.timestamp) {
            WithdrawManagerStorageLib.releaseFunds(timestamp_, sharesToRelease_);
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

    function getSharesReleased() external view returns (uint256) {
        return WithdrawManagerStorageLib.getAmountToRelease();
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

    function updateWithdrawFee(uint256 fee_) external restricted {
        WithdrawManagerStorageLib.setWithdrawFee(fee_);
    }

    function getWithdrawFee() external view returns (uint256) {
        return WithdrawManagerStorageLib.getWithdrawFee();
    }

    function updateRequestFee(uint256 fee_) external restricted {
        WithdrawManagerStorageLib.setRequestFee(fee_);
    }

    function getRequestFee() external view returns (uint256) {
        return WithdrawManagerStorageLib.getRequestFee();
    }

    function updatePlasmaVaultAddress(address plasmaVaultAddress_) external restricted {
        WithdrawManagerStorageLib.setPlasmaVaultAddress(plasmaVaultAddress_);
    }

    function getPlasmaVaultAddress() public view returns (address) {
        return WithdrawManagerStorageLib.getPlasmaVaultAddress();
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
                shares: request.shares,
                endWithdrawWindowTimestamp: request.endWithdrawWindowTimestamp,
                canWithdraw: _canWithdraw(request.endWithdrawWindowTimestamp, withdrawWindow, releaseFundsTimestamp),
                withdrawWindowInSeconds: withdrawWindow
            });
    }

    function _canWithdraw(
        uint256 endWithdrawWindowTimestamp_,
        uint256 withdrawWindow_,
        uint256 releaseFundsTimestamp_
    ) private view returns (bool) {
        if (endWithdrawWindowTimestamp_ < withdrawWindow_) {
            return false;
        }

        uint256 requestTimestamp_ = endWithdrawWindowTimestamp_ - withdrawWindow_;

        return
            block.timestamp >= requestTimestamp_ &&
            block.timestamp <= endWithdrawWindowTimestamp_ &&
            requestTimestamp_ < releaseFundsTimestamp_;
    }

    /// @notice Internal function to get the message sender from context
    /// @return The address of the message sender
    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }
}
