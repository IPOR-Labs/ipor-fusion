// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockTermRepoLocker} from "./MockTermRepoLocker.sol";
import {MockTermRepoToken} from "./MockTermRepoToken.sol";

contract MockTermRepoServicer {
    address public termRepoToken;
    address public termRepoLocker;
    address public termRepoCollateralManager;
    address public purchaseToken;
    uint256 public maturityTimestamp;
    uint256 public redemptionTimestamp;
    uint256 public endOfRepurchaseWindow;
    uint256 public shortfallHaircutMantissa;

    /// @dev Borrower => outstanding repurchase obligation (face value, purchase-token raw units).
    mapping(address => uint256) internal _obligation;
    /// @dev When true, `submitRepurchasePayment` reverts (used to test propagation).
    bool public submitRepurchasePaymentReverts;
    /// @dev When true, `submitRepurchasePayment` rejects an amount strictly greater than the
    ///      outstanding obligation (mirrors the conservative live `TermRepoServicer` behaviour
    ///      where overpayment is rejected rather than partially capped). When false, the mock
    ///      caps the pull at the obligation and accepts the call without revert. See
    ///      `TermFinanceRepurchaseFuseTest` overpayment scenario for the test usage.
    bool public revertOnOverpayment;

    function setTermRepoToken(address v_) external {
        termRepoToken = v_;
    }

    function setTermRepoLocker(address v_) external {
        termRepoLocker = v_;
    }

    function setTermRepoCollateralManager(address v_) external {
        termRepoCollateralManager = v_;
    }

    function setPurchaseToken(address v_) external {
        purchaseToken = v_;
    }

    function setRedemptionTimestamp(uint256 v_) external {
        redemptionTimestamp = v_;
    }

    function setMaturityTimestamp(uint256 v_) external {
        maturityTimestamp = v_;
    }

    function setEndOfRepurchaseWindow(uint256 v_) external {
        endOfRepurchaseWindow = v_;
    }

    function setShortfallHaircutMantissa(uint256 v_) external {
        shortfallHaircutMantissa = v_;
    }

    /// @notice Seed the outstanding repurchase obligation for a given borrower.
    function setBorrowerRepurchaseObligation(address borrower_, uint256 amount_) external {
        _obligation[borrower_] = amount_;
    }

    function setSubmitRepurchasePaymentReverts(bool v_) external {
        submitRepurchasePaymentReverts = v_;
    }

    function setRevertOnOverpayment(bool v_) external {
        revertOnOverpayment = v_;
    }

    /// @notice Read the borrower's outstanding repurchase obligation (face value).
    function getBorrowerRepurchaseObligation(address borrower_) external view returns (uint256) {
        return _obligation[borrower_];
    }

    /// @notice Test helper: mints servicer-side and pays out as if servicer.redeemTermRepoTokens
    ///         were called. Burns from caller (vault) and transfers purchase token from `termRepoLocker`.
    function redeemTermRepoTokens(address redeemer_, uint256 amount_) external {
        // Burn repoToken from caller side.
        MockTermRepoToken(termRepoToken).burn(redeemer_, amount_);
        uint256 payout = (amount_ * (1e18 - shortfallHaircutMantissa)) / 1e18;
        if (payout > 0) {
            // Transfer purchase token from termRepoLocker (test will deal it to locker).
            // In a real flow `termRepoLocker` is its own escrow contract; here we use
            // the address slot as a pre-funded holder.
            IERC20(purchaseToken).transferFrom(termRepoLocker, redeemer_, payout);
        }
    }

    /// @notice Test helper mirroring the live `TermRepoServicer.submitRepurchasePayment` flow:
    ///         pulls `effectiveAmount` of `purchaseToken` from `msg.sender` (the borrower under
    ///         fuse delegatecall — i.e. the harness/vault) via the per-Term `TermRepoLocker`.
    /// @dev `effectiveAmount = min(amount_, obligation)` when `revertOnOverpayment` is false (the
    ///      mock cap-the-pull behaviour). When `revertOnOverpayment` is true the call reverts
    ///      with the live Servicer's `RepurchaseAmountTooHigh` reason if `amount_ > obligation`.
    function submitRepurchasePayment(uint256 amount_) external {
        if (submitRepurchasePaymentReverts) revert("MockTermRepoServicer: submitRepurchasePayment reverts");
        uint256 obligation = _obligation[msg.sender];
        uint256 effective = amount_;
        if (amount_ > obligation) {
            if (revertOnOverpayment) revert("MockTermRepoServicer: RepurchaseAmountTooHigh");
            effective = obligation;
        }
        if (effective > 0 && termRepoLocker != address(0) && purchaseToken != address(0)) {
            // Mirror live impl: Servicer orchestrates the pull through the per-Term Locker.
            // The borrower's approval target is the locker — verifies the fuse approves
            // `termRepoLocker` (not the servicer) for `transferFrom` to succeed.
            MockTermRepoLocker(termRepoLocker).transferTokenFromWallet(msg.sender, purchaseToken, effective);
        }
        _obligation[msg.sender] = obligation - effective;
    }
}
