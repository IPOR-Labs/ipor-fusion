// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {WithdrawManagerStorageLib} from "./WithdrawManagerStorageLib.sol";
import {IWithdrawManagerReleaseFunds} from "./IWithdrawManagerReleaseFunds.sol";
import {WithdrawRequest} from "./WithdrawManagerStorageLib.sol";
import {ContextClient} from "../context/ContextClient.sol";
import {IPlasmaVaultBase} from "../../interfaces/IPlasmaVaultBase.sol";
import {IPlasmaVaultRequestCap} from "../../interfaces/IPlasmaVaultRequestCap.sol";
import {IIporFusionAccessManager} from "../../interfaces/IIporFusionAccessManager.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

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
contract WithdrawManager is Initializable, AccessManagedUpgradeable, ContextClient, IWithdrawManagerReleaseFunds {
    error WithdrawManagerInvalidTimestamp(uint256 timestamp);
    error WithdrawManagerInvalidSharesToRelease(
        uint256 sharesToRelease,
        uint256 shares,
        uint256 plasmaVaultBalanceOfUnallocatedShares
    );
    error WithdrawManagerZeroShares();
    error WithdrawManagerInvalidFee(uint256 fee);
    /// @notice requestShares: the account holds fewer shares than it requests (IL-9531)
    error WithdrawManagerRequestNotBacked(address account, uint256 balance, uint256 shares);
    /// @notice redeemFromRequest: more shares than the account has held without a break since its request (IL-9531)
    error WithdrawManagerRequestCapExceeded(address account, uint256 requestCap, uint256 shares);
    /// @notice requestShares: the WithdrawManager is not wired to its vault (updatePlasmaVaultAddress), so the
    /// request cannot be checked against the balance (IL-9531)
    error WithdrawManagerPlasmaVaultNotSet();
    /// @notice releaseFunds: the reserve exceeds the total supply of the vault shares (IL-9604)
    error WithdrawManagerSharesToReleaseExceedSupply(uint256 sharesToRelease, uint256 totalSupply);
    /// @notice requestShares: the account's current request is covered by the last release and still in its window,
    /// so it cannot be replaced (IL-9652)
    error WithdrawManagerReleasedRequestPending(address account, uint256 shares);

    /// @notice Emitted when an unallocated withdrawal is validated
    /// @param caller Address initiating the withdrawal (PlasmaVault)
    /// @param shares Amount of shares being withdrawn
    /// @param sharesToRelease Current sharesToRelease (reserved for scheduled withdrawals)
    /// @param availableUnallocatedShares Available unallocated shares before this withdrawal
    /// @param feeSharesToBurn Fee shares to be burned (0 if no fee)
    event UnallocatedWithdrawalValidated(
        address indexed caller,
        uint256 shares,
        uint256 sharesToRelease,
        uint256 availableUnallocatedShares,
        uint256 feeSharesToBurn
    );

    /// @notice Constructor that initializes the WithdrawManager with access control
    /// @dev Used when deploying directly without proxy
    /// @param accessManager_ The address of the access control manager that will manage roles and permissions
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address accessManager_) initializer {
        __AccessManaged_init(accessManager_);
    }

    /// @notice Initializes the WithdrawManager with access manager (for cloning)
    /// @param accessManager_ The address of the access control manager
    /// @dev This method is called after cloning to initialize the contract
    function proxyInitialize(address accessManager_) external initializer {
        __AccessManaged_init(accessManager_);
    }

    /**
     * @notice Creates a new withdrawal request
     * @dev Publicly accessible function. The request is backed (IL-9531):
     * - the caller must hold at least `shares_` vault shares (gross, the request fee included);
     * - the vault records a request cap equal to the request (after the fee). A later debit that leaves the caller
     *   below the cap lowers it, and a credit never raises it, so the request redeems only shares held without a
     *   break since it was filed (see `canWithdrawFromRequest`);
     * - when the caller's redemption lock still runs (a deposit within the redemption delay), the request starts
     *   when that lock ends: its window opens then, it joins only releases timestamped after it, and it keeps the
     *   full window. A fresh deposit therefore does not leave through this path sooner than through redeem. Later
     *   deposits to the caller do not move the start, so a third party cannot hold the request; a deposit to the
     *   caller just before it files, also a third party's, postpones the start once, by at most one redemption
     *   delay.
     * The shares are not escrowed: the caller keeps them and can move them, which lowers the cap for good (file a new
     * request to restore it). A new request replaces the previous request and its cap, except a request already covered
     * by the last `releaseFunds` and still inside its window: that one is refused
     * (`WithdrawManagerReleasedRequestPending`, IL-9652; the refusal also applies when that request's cap has dropped
     * to 0, since it keys on the stored request, not on the cap), so overwriting it cannot leave the released
     * reserve behind; redeem it or wait for the end of its window. Apart from the lock at filing time, the redemption delay is not applied to this path.
     * On a vault deployed before IL-9531 (no request caps, see `updatePlasmaVaultAddress`) only the balance check and
     * the lock at filing apply: shares moved away after the request and brought back before the redeem, also by a
     * flash-loan deposit, still redeem it. Keep the operator checks of the runbook (M2-CORE-11) on such vaults
     * @param shares_ The amount requested for redeem, amount of shares to redeem
     * @custom:access Public
     */
    function requestShares(uint256 shares_) external {
        if (shares_ == 0) {
            revert WithdrawManagerZeroShares();
        }

        address account = _msgSender();
        (address plasmaVault, bool vaultKeepsRequestCaps) = WithdrawManagerStorageLib.getPlasmaVault();
        if (plasmaVault == address(0)) {
            revert WithdrawManagerPlasmaVaultNotSet();
        }

        uint256 balance = IERC20(plasmaVault).balanceOf(account);
        if (balance < shares_) {
            revert WithdrawManagerRequestNotBacked(account, balance, shares_);
        }

        WithdrawRequest memory previousRequest = WithdrawManagerStorageLib.getWithdrawRequest(account);
        if (
            previousRequest.shares > 0 &&
            WithdrawManagerStorageLib.getSharesToRelease() > 0 &&
            _canWithdrawFromRequest(
                previousRequest.endWithdrawWindowTimestamp,
                WithdrawManagerStorageLib.getWithdrawWindowInSeconds(),
                WithdrawManagerStorageLib.getLastReleaseFundsTimestamp()
            )
        ) {
            revert WithdrawManagerReleasedRequestPending(account, previousRequest.shares);
        }

        uint256 lockEnd = _lockEndAtRequest(plasmaVault, account);
        uint256 requestedShares = shares_;
        uint256 feeRate = WithdrawManagerStorageLib.getRequestFee();
        if (feeRate > 0) {
            //@dev 1e18 is the precision of the fee rate
            uint256 feeAmount = Math.mulDiv(shares_, feeRate, 1e18);
            requestedShares = shares_ - feeAmount;
            WithdrawManagerStorageLib.updateWithdrawRequest(account, requestedShares, lockEnd);
            IPlasmaVaultBase(plasmaVault).transferRequestSharesFee(account, address(this), feeAmount);
        } else {
            WithdrawManagerStorageLib.updateWithdrawRequest(account, requestedShares, lockEnd);
        }

        if (vaultKeepsRequestCaps) {
            /// @dev Set after the fee transfer, whose debit lowers the cap of the previous request; this one replaces it
            IPlasmaVaultRequestCap(plasmaVault).setRequestCap(account, requestedShares);
        }
    }

    /**
     * @notice Checks if the account can withdraw the specified amount from a request
     * @dev Only callable by PlasmaVault contract (TECH_PLASMA_VAULT_ROLE). On success it debits both the request
     * and the global `sharesToRelease` pool. That pool is shared by all requests filed before the release
     * timestamp and is consumed first come, first served (see `releaseFunds` for choosing the timestamp). Only
     * backed shares can draw on it (IL-9531): the call reverts when `shares_` exceed the request cap kept by the
     * vault (the shares held without a break since the request; only on a vault that keeps request caps, see
     * `updatePlasmaVaultAddress`). A request filed during the requester's redemption
     * lock starts when that lock ends (see `requestShares`). Shares minted later, also within the same transaction,
     * never raise the cap, so a flash loan cannot pass through this path. No other redemption lock applies here
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
            (, bool vaultKeepsRequestCaps) = WithdrawManagerStorageLib.getPlasmaVault();
            if (vaultKeepsRequestCaps) {
                /// @dev msg.sender is the PlasmaVault (TECH_PLASMA_VAULT_ROLE), as in canWithdrawFromUnallocated
                uint256 requestCap = IPlasmaVaultRequestCap(msg.sender).getRequestCap(account_);
                if (shares_ > requestCap) {
                    revert WithdrawManagerRequestCapExceeded(account_, requestCap, shares_);
                }
            }
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
     * - Represents the portion of vault's assets available for immediate withdrawal
     * - Calculated as: vault's total balance - sharesToRelease (shares explicitly released by governance)
     * - Does NOT subtract the sum of all pending withdrawal requests (only sharesToRelease is reserved)
     * - Available for immediate withdrawals without scheduling
     * - Subject to different fee structure than scheduled withdrawals
     * - Can be accessed through standard withdraw/redeem operations
     *
     * Validation Flow:
     * 1. Balance Verification
     *    - Checks PlasmaVault's total underlying token balance
     *    - Subtracts only sharesToRelease (shares explicitly released via releaseFunds)
     *    - Ensures withdrawal amount + sharesToRelease <= total balance
     *    - Prevents double-allocation of released shares
     *
     * 2. Fee Calculation
     *    - Retrieves current withdraw fee rate for unallocated withdrawals
     *    - Calculates fee amount in shares: fee = gross shares x rate, where gross shares are the shares
     *      the caller burns (redeem passes its shares, withdraw passes net shares / (1 - rate))
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
     * - Storage: Fee rate and sharesToRelease
     * - BurnRequestFeeFuse: Fee burning mechanism
     *
     * Important Notes:
     * - Different from scheduled withdrawal system
     * - Immediate withdrawal pathway
     * - Separate fee structure
     * - Only reserves sharesToRelease, NOT all pending withdrawal requests
     * - Pending requests that have not been released by governance do NOT reduce unallocated balance
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

        uint256 feeSharesToBurn;
        if (feeRate > 0) {
            //@dev 1e18 is the precision of the fee rate
            feeSharesToBurn = Math.mulDiv(shares_, feeRate, 1e18);
        }

        emit UnallocatedWithdrawalValidated(
            plasmaVaultAddress,
            shares_,
            sharesToRelease,
            plasmaVaultBalanceOfUnallocatedShares,
            feeSharesToBurn
        );

        return feeSharesToBurn;
    }

    /**
     * @notice Updates the release funds timestamp to allow withdrawals after this point
     * @dev Only callable by accounts with ALPHA_ROLE
     * @param timestamp_ The timestamp to set as the release funds timestamp
     * @param sharesToRelease_ Amount of shares released
     * @dev Reverts if the provided timestamp is in the future or if `sharesToRelease_` exceeds the vault's total
     * supply (IL-9604; skipped while the vault is not wired, see `updatePlasmaVaultAddress`; a sanity bound, not a limit
     * on ALPHA).
     * Each call overwrites the single global
     * `sharesToRelease` quota for every request filed before the timestamp, so the quota is not allocated per
     * request and cannot exclude one. Requests are drawn from it first come, first served, each only for shares
     * held without a break since the request (see `canWithdrawFromRequest`, IL-9531). Choose `timestamp_` right after
     * the newest request `sharesToRelease_` is sized for, not `block.timestamp - 1`: every request filed before the
     * timestamp draws on the pool, also a backed one filed seconds before the release. Release after a NAV refresh
     * @custom:access ALPHA_ROLE
     */
    function releaseFunds(uint256 timestamp_, uint256 sharesToRelease_) external restricted {
        _releaseFunds(timestamp_, sharesToRelease_);
    }

    /// @inheritdoc IWithdrawManagerReleaseFunds
    function releaseFunds(
        uint256 timestamp_,
        uint256 sharesToRelease_,
        uint256 expectedSharesToRelease_
    ) external override restricted {
        uint256 current = WithdrawManagerStorageLib.getSharesToRelease();
        if (current != expectedSharesToRelease_) {
            revert WithdrawManagerSharesToReleaseChanged(expectedSharesToRelease_, current);
        }
        _releaseFunds(timestamp_, sharesToRelease_);
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
     * - Fee is calculated as: gross shares * feeRate / 1e18 (gross = shares burned, fee included)
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

    /**
     * @notice Wires the WithdrawManager to its vault
     * @dev Also records whether the vault keeps request caps (it answers PlasmaVault.getRequestCap, IL-9531). A vault
     * deployed before IL-9531 does not; it can still get this WithdrawManager through UpdateWithdrawManagerMaintenanceFuse,
     * and then has the balance check and the lock at filing, but not the shares-held-since-request check (see
     * `requestShares`). Call it again after a vault upgrade to refresh the mode
     * @param plasmaVaultAddress_ The vault this WithdrawManager serves
     * @custom:access ATOMIST_ROLE
     */
    function updatePlasmaVaultAddress(address plasmaVaultAddress_) external restricted {
        WithdrawManagerStorageLib.setPlasmaVaultAddress(
            plasmaVaultAddress_,
            _vaultKeepsRequestCaps(plasmaVaultAddress_)
        );
    }

    function getPlasmaVaultAddress() public view returns (address) {
        return WithdrawManagerStorageLib.getPlasmaVaultAddress();
    }

    /// @notice Whether the wired vault keeps request caps (IL-9531); false for a vault deployed before IL-9531
    function vaultKeepsRequestCaps() external view returns (bool keepsRequestCaps) {
        (, keepsRequestCaps) = WithdrawManagerStorageLib.getPlasmaVault();
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

    /// @dev IL-9604: the reserve is capped by the vault's total supply, which catches a wrong unit or a slip of a few
    /// orders of magnitude. It does not stop ALPHA from reserving the whole supply
    function _releaseFunds(uint256 timestamp_, uint256 sharesToRelease_) private {
        if (timestamp_ >= block.timestamp) {
            revert WithdrawManagerInvalidTimestamp(timestamp_);
        }
        address plasmaVault = WithdrawManagerStorageLib.getPlasmaVaultAddress();
        /// @dev A manager not wired to its vault (`updatePlasmaVaultAddress`) has no supply to compare with: the bound is
        /// skipped, as no request can be filed on it either (`requestShares` needs the vault)
        if (plasmaVault != address(0)) {
            uint256 totalSupply = IERC20(plasmaVault).totalSupply();
            if (sharesToRelease_ > totalSupply) {
                revert WithdrawManagerSharesToReleaseExceedSupply(sharesToRelease_, totalSupply);
            }
        }
        WithdrawManagerStorageLib.releaseFunds(timestamp_, sharesToRelease_);
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

    /// @dev IL-9531. The end of the account's redemption lock when it files a request: 0 when the lock has ended or the
    /// account is exempt from the redemption delay. Read from the vault's access manager, which records the deposits
    function _lockEndAtRequest(address plasmaVault_, address account_) private view returns (uint256) {
        IIporFusionAccessManager accessManager = IIporFusionAccessManager(IAccessManaged(plasmaVault_).authority());
        uint256 lockEnd = accessManager.getAccountLockTime(account_);
        if (lockEnd <= block.timestamp) {
            return 0;
        }
        /// @dev Access managers deployed before the exemptions (IL-7935) do not have isRedemptionDelayExempt
        (bool success, bytes memory data) = address(accessManager).staticcall(
            abi.encodeWithSelector(IIporFusionAccessManager.isRedemptionDelayExempt.selector, account_)
        );
        if (success && data.length == 32 && abi.decode(data, (bool))) {
            return 0;
        }
        return lockEnd;
    }

    /// @dev IL-9531. True when the vault answers PlasmaVault.getRequestCap with one word: a vault built with request
    /// caps. A vault deployed before IL-9531 reverts (no such function). Probed once, in updatePlasmaVaultAddress
    function _vaultKeepsRequestCaps(address plasmaVault_) private view returns (bool) {
        (bool success, bytes memory data) = plasmaVault_.staticcall(
            abi.encodeWithSelector(IPlasmaVaultRequestCap.getRequestCap.selector, address(0))
        );
        return success && data.length == 32;
    }

    /// @notice Internal function to get the message sender from context
    /// @return The address of the message sender
    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }
}
