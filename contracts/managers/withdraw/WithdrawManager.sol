// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {WithdrawManagerStorageLib} from "./WithdrawManagerStorageLib.sol";
import {WithdrawRequest} from "./WithdrawManagerStorageLib.sol";
import {ContextClient} from "../context/ContextClient.sol";
import {IPlasmaVaultBase} from "../../interfaces/IPlasmaVaultBase.sol";

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
    error WithdrawManagerInvalidTimestamp(uint256 timestamp);
    error WithdrawManagerInvalidSharesToRelease(
        uint256 sharesToRelease,
        uint256 shares,
        uint256 plasmaVaultBalanceOfUnallocatedShares
    );
    error WithdrawManagerZeroShares();
    error WithdrawManagerInvalidFee(uint256 fee);

    constructor(address accessManager_) initializer {
        super.__AccessManaged_init(accessManager_);
    }

    /**
     * @notice Creates a new withdrawal request
     * @dev Publicly accessible function
     * @param shares_ The amount requested for redeem, amount of shares to redeem
     * @custom:access Public
     */
    function requestShares(uint256 shares_) external {
        if (shares_ == 0) {
            revert WithdrawManagerZeroShares();
        }

        uint256 feeRate = WithdrawManagerStorageLib.getRequestFee();
        if (feeRate > 0) {
            //@dev 1e18 is the precision of the fee rate
            uint256 feeAmount = Math.mulDiv(shares_, feeRate, 1e18);
            WithdrawManagerStorageLib.updateWithdrawRequest(_msgSender(), shares_ - feeAmount);
            IPlasmaVaultBase(getPlasmaVaultAddress()).transferRequestSharesFee(_msgSender(), address(this), feeAmount);
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
            _canWithdrawFromRequest(
                request.endWithdrawWindowTimestamp,
                WithdrawManagerStorageLib.getWithdrawWindowInSeconds(),
                releaseFundsTimestamp
            ) && request.shares >= shares_
        ) {
            WithdrawManagerStorageLib.decreaseSharesFromWithdrawRequest(account_, shares_);
            WithdrawManagerStorageLib.decreaseSharesToRelease(shares_);
            return true;
        }
        return false;
    }

    /**
     * @notice Validates and calculates withdrawal fee for unallocated balance withdrawals
     * @dev Only callable by PlasmaVault contract (TECH_PLASMA_VAULT_ROLE)
     *
     * Unallocated Balance:
     * - Represents the portion of vault's assets not committed to pending withdrawal requests
     * - Calculated as: vault's total balance - sum of all pending withdrawal requests
     * - Available for immediate withdrawals without scheduling
     * - Subject to different fee structure than scheduled withdrawals
     * - Can be accessed through standard withdraw/redeem operations
     *
     * Validation Flow:
     * 1. Balance Verification
     *    - Checks PlasmaVault's total underlying token balance
     *    - Subtracts total shares pending for scheduled withdrawals
     *    - Ensures withdrawal amount + pending releases <= total unallocated balance
     *    - Prevents double-allocation of shares
     *
     * 2. Fee Calculation
     *    - Retrieves current withdraw fee rate for unallocated withdrawals
     *    - Calculates fee amount in shares
     *    - Uses WAD precision (18 decimals)
     *    - Returns 0 if no fee configured
     *
     * Security Features:
     * - Role-based access control
     * - Balance sufficiency checks
     * - Share conversion safety
     * - Withdrawal limit enforcement
     * - Protection against over-allocation
     *
     * Integration Points:
     * - PlasmaVault: Main caller and balance source
     * - ERC4626: Share/asset conversion
     * - Storage: Fee rate and pending withdrawals
     * - BurnRequestFeeFuse: Fee burning mechanism
     *
     * Important Notes:
     * - Different from scheduled withdrawal system
     * - Immediate withdrawal pathway
     * - Separate fee structure
     * - Must maintain withdrawal request safety
     * - Critical for vault liquidity management
     *
     * Error Cases:
     * - Insufficient unallocated balance
     * - Invalid share calculations
     * - Unauthorized caller
     * - Balance allocation conflicts
     *
     * @param shares_ Amount of shares attempting to withdraw from unallocated balance
     * @return feeSharesToBurn Amount of shares to be burned as fee (0 if no fee)
     * @custom:access TECH_PLASMA_VAULT_ROLE
     */
    function canWithdrawFromUnallocated(uint256 shares_) external restricted returns (uint256) {
        address plasmaVaultAddress = msg.sender;
        uint256 feeRate = WithdrawManagerStorageLib.getWithdrawFee();
        uint256 balanceOfPlasmaVault = ERC4626(ERC4626(plasmaVaultAddress).asset()).balanceOf(plasmaVaultAddress);
        uint256 plasmaVaultBalanceOfUnallocatedShares = ERC4626(plasmaVaultAddress).convertToShares(
            balanceOfPlasmaVault
        );
        uint256 sharesToRelease = WithdrawManagerStorageLib.getSharesToRelease();

        if (sharesToRelease > 0 && plasmaVaultBalanceOfUnallocatedShares < sharesToRelease + shares_) {
            revert WithdrawManagerInvalidSharesToRelease(
                sharesToRelease,
                shares_,
                plasmaVaultBalanceOfUnallocatedShares
            );
        }
        if (feeRate > 0) {
            //@dev 1e18 is the precision of the fee rate
            return Math.mulDiv(shares_, feeRate, 1e18);
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

    function getSharesToRelease() external view returns (uint256) {
        return WithdrawManagerStorageLib.getSharesToRelease();
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
     * @notice Updates the fee rate for withdrawals from unallocated balance
     * @dev Only callable by accounts with ATOMIST_ROLE
     *
     * Fee System:
     * - Fee rate is specified in WAD (18 decimals)
     * - 1e18 represents 100% fee
     * - Fee is calculated as: amount * feeRate / 1e18
     * - Collected fees are burned through BurnRequestFeeFuse
     *
     * Access Control:
     * - Restricted to ATOMIST_ROLE
     * - Critical protocol parameter
     * - Part of fee management system
     *
     * Integration Points:
     * - Used in canWithdrawFromUnallocated
     * - Affects withdrawal costs
     * - Impacts protocol revenue
     * - Connected to burn mechanism
     *
     * Security Considerations:
     * - Maximum fee rate capped at 100%
     * - State updates through storage library
     * - Event emission for tracking
     * - Access controlled operation
     *
     * Use Cases:
     * - Protocol fee adjustment
     * - Revenue model updates
     * - Market condition responses
     * - Economic parameter tuning
     *
     * @param fee_ The new fee rate in WAD (18 decimals precision, 1e18 = 100%)
     * @custom:access WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE
     */
    function updateWithdrawFee(uint256 fee_) external restricted {
        //@dev 1e18 is the 100% of the fee rate
        if (fee_ > 1e18) {
            revert WithdrawManagerInvalidFee(fee_);
        }
        WithdrawManagerStorageLib.setWithdrawFee(fee_);
    }

    function getWithdrawFee() external view returns (uint256) {
        return WithdrawManagerStorageLib.getWithdrawFee();
    }

    /**
     * @notice Updates the fee rate for withdrawal requests
     * @dev Only callable by accounts with ATOMIST_ROLE
     *
     * Fee System:
     * - Fee rate is specified in WAD (18 decimals)
     * - 1e18 represents 100% fee
     * - Fee is calculated as: shares * feeRate / 1e18
     * - Fees are transferred to WithdrawManager during requestShares
     *
     * Access Control:
     * - Restricted to ATOMIST_ROLE
     * - Critical protocol parameter
     * - Part of request fee management system
     *
     * Integration Points:
     * - Used in requestShares function
     * - Affects request costs
     * - Impacts protocol revenue
     * - Integrates with transferRequestSharesFee
     *
     * Security Considerations:
     * - Maximum fee rate capped at 100%
     * - State updates through storage library
     * - Event emission for tracking
     * - Access controlled operation
     *
     * Use Cases:
     * - Request fee adjustment
     * - Withdrawal request cost management
     * - Protocol revenue optimization
     * - Market condition adaptation
     *
     * Related Components:
     * - WithdrawManagerStorageLib
     * - PlasmaVaultBase (for fee transfers)
     * - BurnRequestFeeFuse (eventual fee burning)
     * - Access control system
     *
     * @param fee_ The new request fee rate in WAD (18 decimals precision, 1e18 = 100%)
     * @custom:access WITHDRAW_MANAGER_REQUEST_FEE_ROLE
     */
    function updateRequestFee(uint256 fee_) external restricted {
        /// @dev 1e18 is the 100% of the fee rate
        if (fee_ > 1e18) {
            revert WithdrawManagerInvalidFee(fee_);
        }
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
                canWithdraw: _canWithdrawFromRequest(
                    request.endWithdrawWindowTimestamp,
                    withdrawWindow,
                    releaseFundsTimestamp
                ),
                withdrawWindowInSeconds: withdrawWindow
            });
    }

    function _canWithdrawFromRequest(
        uint256 endWithdrawWindowTimestamp_,
        uint256 withdrawWindow_,
        uint256 releaseFundsTimestamp_
    ) private view returns (bool) {
        /// @dev User who never requested a withdrawal can withdraw immediately, but can't withdraw from request
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
