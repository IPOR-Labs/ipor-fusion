// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IExtTermController} from "./ext/IExtTermController.sol";
import {IExtTermRepoServicer} from "./ext/IExtTermRepoServicer.sol";

/// @notice Data for submitting a borrower repurchase payment via TermRepoServicer.
/// @dev `amount` is the purchase-token raw units to repay; the Servicer caps the pull at the
///      outstanding `getBorrowerRepurchaseObligation(vault)` natively. The fuse measures the
///      pre/post purchase-token balance delta and emits the actual amount paid (handles
///      `amount > obligation`, partial repayment, and any future Servicer impl that pulls less
///      than the requested amount).
///
///      `submitRepurchasePayment(uint256)` takes
///      only `amount` — the borrower identity is `msg.sender`, which under the fuse's
///      delegatecall is the PlasmaVault.
/// @param servicer Substrate key — TermRepoServicer proxy that holds the borrower's repurchase
///        obligation; resolved on-chain to its paired `termRepoLocker` (approval target) and
///        `purchaseToken` (the asset transferred).
/// @param amount Purchase-token raw units the alpha intends to repay. May be less than, equal to,
///        or greater than the outstanding obligation; the Servicer caps the pull natively and the
///        event records the actually-spent delta.
struct TermFinanceRepurchaseFuseEnterData {
    address servicer;
    uint256 amount;
}

/// @title TermFinanceRepurchaseFuse
/// @author IPOR Labs
/// @notice Borrower-side fuse that submits a (partial or full) repurchase payment to a Term
///         Finance `TermRepoServicer`, settling the PlasmaVault's outstanding borrower debt
///         denominated in the Term Repo's purchase token.
/// @dev Approval flow (verified against the live `TermRepoServicer` impl): the Servicer pulls the
///      purchase token via `TermRepoLocker.transferTokenFromWallet(borrower, ...)`, so the
///      approval target is the per-Term `TermRepoLocker` (`IExtTermRepoServicer.termRepoLocker()`),
///      NOT the Servicer itself. This mirrors `TermFinanceCollateralFuse.enter` (approve the
///      locker, call the orchestrator) and `TermFinanceOfferFuse.enter` (approve the locker for
///      offer-side purchase token pulls).
///
///      Repurchase window: the Servicer ABI exposes `endOfRepurchaseWindow()` as the post-maturity
///      deadline for borrower settlement. `block.timestamp >= endOfRepurchaseWindow()` puts the
///      borrower in default territory (collateral becomes liquidatable by Term liquidators); the
///      fuse early-reverts with a clean selector instead of letting the call drift into a
///      Term-layer revert with an ambiguous reason string. The check is strict `<` (i.e. `block.timestamp >= endTimestamp`
///      reverts; the boundary instant counts as the start of default).
///
///      Partial repayment is supported natively: `amount` may be less than the outstanding
///      obligation. The Servicer also handles `amount > obligation` by capping the pull at the
///      obligation (excess is either refunded or rejected depending on the concrete impl — the
///      `IExtTermRepoServicer.submitRepurchasePayment` NatSpec records this); the fuse measures
///      the pre/post purchase-token balance delta on the vault and emits the actual `amountPaid`.
///
///      No `exit()` is exposed — a repurchase payment is irreversible once accepted by the
///      Servicer (funds flow into the Term Repo's escrow / lender redemption pot). Burning
///      vault-held TermRepoTokens to cancel debt (`burnCollapseExposure`) is declared on the
///      extended interface but out of scope for v2 (see `IExtTermRepoServicer` L25-30 NatSpec).
///
///      WithdrawManager check: `_assertWithdrawManagerSet()` runs as the FIRST statement of
///      `enter`, BEFORE substrate / controller / window validation, BEFORE any external call,
///      and BEFORE any state write. The check is NOT in the constructor because
///      `PlasmaVaultStorageLib.getWithdrawManager()` would read the deployer's storage during
///      construction (delegatecall context is not available at deploy time), so a constructor
///      check would universally revert. Codifies the non-negotiable invariant that a vault
///      without a WithdrawManager could allow withdrawals at any time, bypassing the Term
///      Finance maturity timeline and underwatering the vault. Mirror of `BurnRequestFeeFuse.enter`
///      and `TermFinanceCollateralFuse._assertWithdrawManagerSet`.
///
///      Servicer deployment guard: `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)`
///      runs as step 2 of the validation pipeline (after the IPOR-side substrate allowlist),
///      blocking impersonation by lookalike contracts even if the substrate allowlist was
///      misconfigured upstream. Mirror of `TermFinanceRedeemFuse.enter` and
///      `TermFinanceCollateralFuse._assertServicerTermDeployed`.
contract TermFinanceRepurchaseFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted on a successful repurchase payment with the measured purchase-token delta
    ///         and the remaining outstanding borrower obligation read after the call.
    /// @param version Address of this fuse instance (event-only version tag).
    /// @param servicer TermRepoServicer proxy that received the payment.
    /// @param amountPaid Actual purchase-token raw units pulled by the Servicer
    ///        (= pre-balance - post-balance on the vault). May differ from
    ///        `TermFinanceRepurchaseFuseEnterData.amount` if the Servicer capped the pull at the
    ///        outstanding obligation.
    /// @param remainingObligation Outstanding face-value debt for the vault after the payment,
    ///        read via `IExtTermRepoServicer.getBorrowerRepurchaseObligation(vault)`. Zero on a
    ///        full repayment.
    event TermFinanceRepurchased(
        address version,
        address servicer,
        uint256 amountPaid,
        uint256 remainingObligation
    );

    /// @notice Reverts when the PlasmaVault has no WithdrawManager configured.
    /// @dev Codifies the non-functional requirement: a vault without a WithdrawManager
    ///      could allow withdrawals at any time, bypassing the Term Finance maturity timeline.
    ///      Borrower obligations are irrevocable once a bid clears; releasing assets to LPs
    ///      before maturity would leave the vault unable to cover the repurchase.
    error TermFinanceRepurchaseFuseWithdrawManagerRequired();

    /// @notice Reverts when `servicer` is not in the vault's `TERM_FINANCE` market substrate
    ///         allowlist (as a `SERVICER`-typed substrate).
    /// @param servicer The non-allowlisted servicer that was passed in calldata.
    error TermFinanceRepurchaseFuseUnsupportedMarket(address servicer);

    /// @notice Reverts when `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)` returns
    ///         false — i.e. the Term Finance evergreen controller does not recognise `servicer`
    ///         as a live, deployed `TermRepoServicer`.
    /// @param servicer The servicer address that failed the controller deployment check.
    error TermFinanceRepurchaseFuseTermNotDeployed(address servicer);

    /// @notice Reverts when `enter` is called with `amount == 0`.
    error TermFinanceRepurchaseFuseZeroAmount();

    /// @notice Reverts when the vault has no outstanding repurchase obligation on `servicer`
    ///         (nothing to repay) — observability guard.
    /// @param servicer The servicer whose obligation for the vault is zero.
    error TermFinanceRepurchaseFuseNoObligation(address servicer);

    /// @notice Reverts when `block.timestamp >= endOfRepurchaseWindow()` on the servicer — the
    ///         repurchase deadline has lapsed and the borrower is in default.
    /// @param nowTs Block timestamp at the time of the call.
    /// @param endOfRepurchaseWindow The repurchase deadline returned by the servicer.
    error TermFinanceRepurchaseFuseWindowClosed(uint256 nowTs, uint256 endOfRepurchaseWindow);

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;

    /// @notice PlasmaVault market id assigned to Term Finance.
    uint256 public immutable MARKET_ID;

    /// @notice Live Term Finance `TermController` proxy used to verify that each servicer passed
    ///         in calldata is a Term-recognised deployment.
    address public immutable TERM_CONTROLLER;

    /// @notice Initialise immutables.
    /// @dev `marketId_ > 0` and `termController_ != address(0)` are required; market id 0 is the
    ///      sentinel for "unconfigured", and a zero controller would silently disable the per-call
    ///      `isTermDeployed` guard.
    ///      The WithdrawManager check is intentionally NOT performed here — see contract NatSpec
    ///      for the rationale (delegatecall context unavailable at deploy time).
    /// @param marketId_ PlasmaVault market id assigned to Term Finance.
    /// @param termController_ Term Finance evergreen `TermController` proxy address.
    constructor(uint256 marketId_, address termController_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        if (termController_ == address(0)) revert Errors.WrongAddress();

        VERSION = address(this);
        MARKET_ID = marketId_;
        TERM_CONTROLLER = termController_;
    }

    /// @notice Submit a borrower repurchase payment to a Term Finance `TermRepoServicer`.
    /// @dev Validation and execution order (all-or-nothing; any failure reverts atomically):
    ///      0. `_assertWithdrawManagerSet()` — non-negotiable runtime invariant.
    ///      1. `data_.amount > 0` — zero-amount calls are a no-op and reverted explicitly for
    ///         observability (instead of silently passing through to a Servicer no-op).
    ///      2. Servicer substrate allowlist (typed `SERVICER`, TYPE byte 0x00) via
    ///         `PlasmaVaultConfigLib.isSubstrateAsAssetGranted`. The legacy
    ///         `addressToBytes32(servicer)` encoding decodes to TYPE 0x00 naturally
    ///         (see `TermFinanceSubstrateLib`), so this check is interoperable with the
    ///         lender-side substrates.
    ///      3. `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)` — Term Finance
    ///         evergreen controller deployment guard.
    ///      4. Repurchase window guard: `block.timestamp < endOfRepurchaseWindow()`. Strict `<`
    ///         — the boundary instant is
    ///         already inside the default window where collateral may be seized by liquidators.
    ///      5. Resolve the approval target (`termRepoLocker`) and the asset to approve
    ///         (`purchaseToken`) from the servicer. Cached in local variables to avoid re-fetching.
    ///      6. Snapshot `purchaseTokenBalanceBefore` on the vault for delta measurement.
    ///      7. `forceApprove(termRepoLocker, data_.amount)` — the approval target is the per-Term
    ///         `TermRepoLocker` because `submitRepurchasePayment` pulls via
    ///         `TermRepoLocker.transferTokenFromWallet(borrower, purchaseToken, amount)`
    ///         (verified live).
    ///      8. `submitRepurchasePayment(data_.amount)` on the servicer. `msg.sender` under
    ///         delegatecall is the PlasmaVault, so the Servicer credits the payment against the
    ///         vault's outstanding obligation.
    ///      9. `forceApprove(termRepoLocker, 0)` — defensive cleanup. The Servicer is expected to
    ///         consume exactly the pulled amount, but a zero-reset guards against any future impl
    ///         that partial-pulls and leaves dangling allowance.
    ///     10. Compute `amountPaid = balanceBefore - balanceAfter` (the Servicer pulls strictly
    ///         non-negative). Read `remainingObligation` via
    ///         `getBorrowerRepurchaseObligation(address(this))` for the emitted event.
    ///     11. Emit `TermFinanceRepurchased(VERSION, servicer, amountPaid, remainingObligation)`.
    ///
    ///      No symmetric `exit()` is exposed — repurchase payments are irreversible at the Term
    ///      layer.
    /// @param data_ Calldata struct — see `TermFinanceRepurchaseFuseEnterData` NatSpec.
    function enter(TermFinanceRepurchaseFuseEnterData calldata data_) external {
        _assertWithdrawManagerSet();

        if (data_.amount == 0) revert TermFinanceRepurchaseFuseZeroAmount();

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.servicer)) {
            revert TermFinanceRepurchaseFuseUnsupportedMarket(data_.servicer);
        }

        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(data_.servicer)) {
            revert TermFinanceRepurchaseFuseTermNotDeployed(data_.servicer);
        }

        uint256 endTimestamp = IExtTermRepoServicer(data_.servicer).endOfRepurchaseWindow();
        if (block.timestamp >= endTimestamp) {
            revert TermFinanceRepurchaseFuseWindowClosed(block.timestamp, endTimestamp);
        }

        address termRepoLocker = IExtTermRepoServicer(data_.servicer).termRepoLocker();
        address purchaseToken = IExtTermRepoServicer(data_.servicer).purchaseToken();

        // Clamp the payment to the outstanding obligation BEFORE approving/paying
        // so an over-sized `amount` (e.g. type(uint256).max) can never over-pay — the cap is
        // enforced fuse-side and does not rely on the Term servicer impl capping the pull
        // itself (its NatSpec leaves "excess refunded OR rejected" impl-defined). A vault with
        // no debt has nothing to repurchase.
        uint256 obligationBefore = IExtTermRepoServicer(data_.servicer).getBorrowerRepurchaseObligation(
            address(this)
        );
        if (obligationBefore == 0) revert TermFinanceRepurchaseFuseNoObligation(data_.servicer);
        uint256 payAmount = data_.amount > obligationBefore ? obligationBefore : data_.amount;

        uint256 balanceBefore = IERC20(purchaseToken).balanceOf(address(this));

        ERC20(purchaseToken).forceApprove(termRepoLocker, payAmount);

        IExtTermRepoServicer(data_.servicer).submitRepurchasePayment(payAmount);

        ERC20(purchaseToken).forceApprove(termRepoLocker, 0);

        uint256 amountPaid = balanceBefore - IERC20(purchaseToken).balanceOf(address(this));
        uint256 remainingObligation = IExtTermRepoServicer(data_.servicer).getBorrowerRepurchaseObligation(
            address(this)
        );

        emit TermFinanceRepurchased(VERSION, data_.servicer, amountPaid, remainingObligation);
    }

    /// @notice Reverts unless the vault has a WithdrawManager configured.
    /// @dev See contract NatSpec for the runtime-vs-constructor rationale. Read directly from the
    ///      canonical storage slot via `PlasmaVaultStorageLib.getWithdrawManager()` — during fuse
    ///      delegatecall the slot is read from PlasmaVault storage (the intended context).
    function _assertWithdrawManagerSet() private view {
        if (PlasmaVaultStorageLib.getWithdrawManager().manager == address(0)) {
            revert TermFinanceRepurchaseFuseWithdrawManagerRequired();
        }
    }
}
