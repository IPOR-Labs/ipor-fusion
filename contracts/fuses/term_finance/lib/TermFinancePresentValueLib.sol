// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title TermFinancePresentValueLib
/// @notice Pure-math library for present-value computation of Term Finance TermRepoToken holdings.
/// @dev Derived from term-finance/yearn-v3-term-vault `RepoTokenUtils`. The `faceValue` branch
///      mirrors `getNormalizedRepoTokenAmount` (haircut=0 path) exactly. The pre-maturity PV
///      branch DEVIATES from Yearn's `calculatePresentValue` in how `repoRedemptionHaircut`
///      is applied — see the @dev note on `presentValuePreMaturity` for the rationale.
///      Applies defensive caps on haircut and effective rate to keep arithmetic safe under
///      adversarial inputs from external contracts.
library TermFinancePresentValueLib {
    uint256 internal constant RATE_PRECISION = 1e18;

    /// @dev 360-day count convention; Term Finance uses Actual/360.
    uint256 internal constant THREESIXTY_DAYCOUNT_SECONDS = 360 * 86_400;

    /// @dev Upper bound on the effective discount rate. Matches TermAuctionOfferLocker.MAX_OFFER_PRICE
    ///      (10_000e16 = 10,000%). Cap prevents `effRate * dayFrac / 1e18` from overflowing
    ///      and keeps the divisor strictly positive.
    uint256 internal constant MAX_DISCOUNT_RATE = 10_000e16;

    /// @dev Maximum redemptionValue accepted from `TermRepoToken.redemptionValue()`. Anything
    ///      larger is treated as adversarial input (e.g. malicious Term Finance proxy upgrade
    ///      returning `type(uint256).max`) and causes the substrate to contribute 0 PV instead
    ///      of overflowing the multiplication in `faceValue`. 1e22 = 10,000x RATE_PRECISION,
    ///      far above any plausible legitimate value (real on-chain values are ~1e18 ±10%).
    uint256 internal constant MAX_REDEMPTION_VALUE = 1e22;

    /// @dev Maximum tenor accepted in `presentValuePreMaturity`. Real Term Finance markets are
    ///      weekly to ~4-week tenors; this cap (100 years) handles a malicious `redemptionTimestamp`
    ///      that would otherwise overflow `secondsToMaturity * purchasePrec` in `dayFrac`.
    uint256 internal constant MAX_SECONDS_TO_MATURITY = 100 * 360 * 86_400;

    /// @notice Convert raw TermRepoToken balance to face value in purchase-token units.
    /// @dev Mirrors `RepoTokenUtils.getNormalizedRepoTokenAmount` (Yearn V3 strategy, haircut=0 branch):
    ///      `face = redemptionValue * repoBalance * purchasePrec / (repoTokenPrec * RATE_PRECISION)`.
    /// @param repoBalance_ TermRepoToken balance held by the vault (raw units, `repoTokenPrec` scale)
    /// @param redemptionValue_ TermRepoToken.redemptionValue() — 18-dec mantissa
    /// @param repoTokenPrec_ 10 ** repoToken.decimals()
    /// @param purchasePrec_ 10 ** purchaseToken.decimals()
    /// @return Face value in purchase-token raw units
    function faceValue(
        uint256 repoBalance_,
        uint256 redemptionValue_,
        uint256 repoTokenPrec_,
        uint256 purchasePrec_
    ) internal pure returns (uint256) {
        if (repoTokenPrec_ == 0) return 0;
        if (repoBalance_ == 0 || redemptionValue_ == 0) return 0;
        // Saturate adversarial inputs from upgradable Term Finance proxies so a corrupted
        // redemptionValue cannot overflow the multiplication and revert NAV.
        if (redemptionValue_ > MAX_REDEMPTION_VALUE) return 0;
        return (redemptionValue_ * repoBalance_ * purchasePrec_) / (repoTokenPrec_ * RATE_PRECISION);
    }

    /// @notice Pre-maturity present value with adapter discount rate and conservative haircut.
    /// @dev Formula: `pv = face * purchasePrec / (purchasePrec + effRate * dayFrac / RATE_PRECISION)`,
    ///      then capped at `face` to handle the rate=0 / haircut overshoot cases.
    /// @dev DELIBERATE DEVIATION from Yearn V3 `RepoTokenUtils.calculatePresentValue`:
    ///      Yearn applies `repoRedemptionHaircut` as a face multiplier
    ///      (`face_after = face * (1e18 - hcut) / 1e18`), reducing principal up-front.
    ///      We apply it as a RATE AMPLIFIER instead: `effRate = rate * (1 + hcut) / 1e18`,
    ///      widening the discount. The two formulas converge at `hcut = 0` (the live
    ///      mainnet configuration today, `shortfallHaircutMantissa() == 0`), but diverge
    ///      for non-zero haircuts — e.g. at 5% hcut / 4% APR / 28d tenor, Yearn yields
    ///      `pv ≈ 0.947 * face` while this lib yields `pv ≈ 0.997 * face` (~5pp gap).
    ///      Rationale: rate amplification keeps the haircut effect time-proportional
    ///      (shorter tenors absorb less haircut, longer tenors absorb more), which the
    ///      risk team judged a better fit for the lender NAV semantics than a flat
    ///      face cut. If the Term Finance discount-rate adapter
    ///      ever starts reporting a non-zero `repoRedemptionHaircut` on mainnet, revisit
    ///      this choice and the corresponding NAV impact before relying on this path in
    ///      production.
    /// @param faceInPurchase_ Face value in purchase-token units (output of `faceValue`)
    /// @param purchasePrec_ 10 ** purchaseTokenDecimals
    /// @param secondsToMaturity_ Seconds from now to redemptionTimestamp (must be > 0)
    /// @param discountRate_ Raw adapter discount rate (18-dec mantissa)
    /// @param adapterHaircut_ Adapter's conservative haircut (18-dec mantissa; capped at 1e18)
    /// @return Present value in purchase-token raw units
    function presentValuePreMaturity(
        uint256 faceInPurchase_,
        uint256 purchasePrec_,
        uint256 secondsToMaturity_,
        uint256 discountRate_,
        uint256 adapterHaircut_
    ) internal pure returns (uint256) {
        if (faceInPurchase_ == 0) return 0;
        if (purchasePrec_ == 0) return 0;
        // Saturate adversarial tenor from a corrupted `redemptionTimestamp`. Real markets are
        // weeks-to-months; 100 years is well above any legitimate value and prevents overflow
        // in `secondsToMaturity_ * purchasePrec_` below.
        uint256 tau = secondsToMaturity_ > MAX_SECONDS_TO_MATURITY ? MAX_SECONDS_TO_MATURITY : secondsToMaturity_;

        uint256 hcut = adapterHaircut_ > RATE_PRECISION ? RATE_PRECISION : adapterHaircut_;
        // Explicit clamp BEFORE the multiplication so an adversarial adapter return
        // near 2**256 cannot overflow (revert) or, in an unchecked context, wrap mod 2**256
        // to a small-positive value that bypasses the MAX_DISCOUNT_RATE saturation below.
        if (discountRate_ > MAX_DISCOUNT_RATE) {
            discountRate_ = MAX_DISCOUNT_RATE;
        }
        uint256 effRate = (discountRate_ * (RATE_PRECISION + hcut)) / RATE_PRECISION;
        if (effRate > MAX_DISCOUNT_RATE) {
            effRate = MAX_DISCOUNT_RATE;
        }

        uint256 dayFrac = (tau * purchasePrec_) / THREESIXTY_DAYCOUNT_SECONDS;
        uint256 divisor = purchasePrec_ + (effRate * dayFrac) / RATE_PRECISION;

        uint256 pv = (faceInPurchase_ * purchasePrec_) / divisor;
        // Yearn V3 caps PV at face: protects against rounding overshoot when divisor < purchasePrec
        // (e.g. rate=0 with non-zero dayFrac yields divisor==purchasePrec, pv==face; with any
        // numerical noise pv could marginally exceed face).
        return pv > faceInPurchase_ ? faceInPurchase_ : pv;
    }

    /// @notice At/post-maturity present value: face minus realised default haircut.
    /// @param faceInPurchase_ Face value in purchase-token units
    /// @param shortfallHaircut_ Realised haircut (18-dec mantissa; capped at 1e18 defensively)
    /// @return Present value in purchase-token raw units
    function presentValuePostMaturity(
        uint256 faceInPurchase_,
        uint256 shortfallHaircut_
    ) internal pure returns (uint256) {
        if (faceInPurchase_ == 0) return 0;
        uint256 hcut = shortfallHaircut_ > RATE_PRECISION ? RATE_PRECISION : shortfallHaircut_;
        return (faceInPurchase_ * (RATE_PRECISION - hcut)) / RATE_PRECISION;
    }
}
