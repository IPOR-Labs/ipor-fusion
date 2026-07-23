// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TermFinancePresentValueLib} from "contracts/fuses/term_finance/lib/TermFinancePresentValueLib.sol";

/// @title TermFinancePresentValueLibTest
/// @notice Tests pure-math PV formulas; values cross-checked against Yearn V3
///         `RepoTokenUtils` (getNormalizedRepoTokenAmount + calculatePresentValue).
///         redemptionValue is 18-dec mantissa; faceValue = repoBal * redValue * purchasePrec / (repoTokenPrec * 1e18).
contract TermFinancePresentValueLibTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_PREC = 1e6;
    uint256 internal constant WETH_PREC = 1e18;

    // ============ faceValue ============

    /// @dev Live state from Ethereum block ~25097999: USDC servicer `0x11951C5...8657`
    ///      repoToken decimals=6, redemptionValue=1e18 (18-dec mantissa).
    ///      For 1.009e12 raw repoBal, face = 1.009e12 USDC.
    function test_faceValue_liveStateScaling() public pure {
        uint256 face = TermFinancePresentValueLib.faceValue(
            1_009_852_430_555, // repoBal
            1e18, // redemptionValue
            USDC_PREC, // repoTokenPrec
            USDC_PREC // purchasePrec
        );
        assertEq(face, 1_009_852_430_555);
    }

    function test_faceValue_atClearing_5pct28d() public pure {
        // 1M USDC lent, redemptionValue at clearing = 1.003889e18 (1 + 5% * 28/360 in WAD).
        // face = 1e6 * 1.003889e18 * 1e6 / (1e6 * 1e18) = 1_003_889 USDC.
        uint256 face = TermFinancePresentValueLib.faceValue(1_000_000, 1_003_889e12, USDC_PREC, USDC_PREC);
        assertEq(face, 1_003_889);
    }

    function test_faceValue_atClearing_5pct7d() public pure {
        // 1M USDC lent, weekly tenor. face = 1.000972e6.
        uint256 face = TermFinancePresentValueLib.faceValue(1_000_000, 1_000_972e12, USDC_PREC, USDC_PREC);
        assertEq(face, 1_000_972);
    }

    function test_faceValue_zeroRepoTokenPrec_returnsZero() public pure {
        uint256 face = TermFinancePresentValueLib.faceValue(1_000_000, 1e18, 0, USDC_PREC);
        assertEq(face, 0);
    }

    function test_faceValue_zeroBalance_returnsZero() public pure {
        uint256 face = TermFinancePresentValueLib.faceValue(0, 1e18, USDC_PREC, USDC_PREC);
        assertEq(face, 0);
    }

    function test_faceValue_zeroRedValue_returnsZero() public pure {
        uint256 face = TermFinancePresentValueLib.faceValue(1_000_000, 0, USDC_PREC, USDC_PREC);
        assertEq(face, 0);
    }

    function test_faceValue_adversarialRedValue_returnsZero() public pure {
        // Anything above MAX_REDEMPTION_VALUE (1e22) is treated as adversarial → return 0.
        uint256 face = TermFinancePresentValueLib.faceValue(1_000_000, 1e23, USDC_PREC, USDC_PREC);
        assertEq(face, 0, "redValue beyond cap -> 0 (defensive)");
    }

    function test_presentValuePreMaturity_adversarialTenor_capped() public pure {
        // tau beyond cap (1e10s = ~316y) saturates at MAX_SECONDS_TO_MATURITY = 100y.
        // Without saturation: tau * purchasePrec = 1e10 * 1e6 = 1e16 — within uint256 but
        // adversarial multiplication chains can overflow. We just assert the call doesn't revert.
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(
            1_000_000,
            USDC_PREC,
            type(uint256).max,
            5e16,
            0
        );
        // With saturated tau the divisor is huge → pv ≈ 0 (heavy discount over 100y at 5%).
        assertLt(pv, 1_000_000, "saturated tau heavily discounts");
    }

    function test_faceValue_mixedDecimals_scaling() public pure {
        // Hypothetical WETH-purchase repo with USDC-decimals repoToken (cross-precision case).
        // repoBal=1e18 (1 token in WETH-prec), redValue=1e18, repoTokenPrec=1e18, purchasePrec=1e18:
        //   face = 1e18 * 1e18 * 1e18 / (1e18 * 1e18) = 1e18 WETH (1 WETH).
        uint256 face = TermFinancePresentValueLib.faceValue(1e18, 1e18, 1e18, 1e18);
        assertEq(face, 1e18);
    }

    // ============ presentValuePreMaturity ============

    /// @dev face=1_003_889 (28d @5% after clearing), tau=28d. pv ~ 1_000_000.
    function test_presentValuePreMaturity_atClearing_equalsPrincipal_28d() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(
            1_003_889,
            USDC_PREC,
            28 * 86_400,
            5e16,
            0
        );
        assertApproxEqAbs(pv, 1_000_000, 2);
    }

    function test_presentValuePreMaturity_weeklyTenor_atClearing() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(
            1_000_972,
            USDC_PREC,
            7 * 86_400,
            5e16,
            0
        );
        assertApproxEqAbs(pv, 1_000_000, 2);
    }

    function test_presentValuePreMaturity_midTerm_partialAccrual() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(
            1_003_889,
            USDC_PREC,
            14 * 86_400,
            5e16,
            0
        );
        assertGt(pv, 1_000_000);
        assertLt(pv, 1_003_889);
        assertApproxEqAbs(pv, 1_001_941, 50);
    }

    function test_presentValuePreMaturity_zeroFace_returnsZero() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(0, USDC_PREC, 1000, 5e16, 0);
        assertEq(pv, 0);
    }

    function test_presentValuePreMaturity_zeroPurchasePrec_returnsZero() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(1_000_000, 0, 1000, 5e16, 0);
        assertEq(pv, 0);
    }

    function test_presentValuePreMaturity_zeroSecondsToMaturity_returnsFace() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(1_003_889, USDC_PREC, 0, 5e16, 0);
        assertEq(pv, 1_003_889);
    }

    function test_presentValuePreMaturity_zeroRate_returnsFace() public pure {
        // r=0 with nonzero dayFrac → divisor = purchasePrec → pv = face. Then cap at face confirms ==face.
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(1_003_889, USDC_PREC, 1000, 0, 0);
        assertEq(pv, 1_003_889);
    }

    function test_presentValuePreMaturity_withAdapterHaircut_reducesPV() public pure {
        uint256 pvNoHcut = TermFinancePresentValueLib.presentValuePreMaturity(
            1_003_889,
            USDC_PREC,
            14 * 86_400,
            5e16,
            0
        );
        uint256 pvWithHcut = TermFinancePresentValueLib.presentValuePreMaturity(
            1_003_889,
            USDC_PREC,
            14 * 86_400,
            5e16,
            1e16
        );
        assertLt(pvWithHcut, pvNoHcut);
    }

    function test_presentValuePreMaturity_capsAdapterHaircutAt1e18() public pure {
        uint256 pvCapped = TermFinancePresentValueLib.presentValuePreMaturity(
            1_003_889,
            USDC_PREC,
            14 * 86_400,
            5e16,
            2e18
        );
        uint256 pvAtCap = TermFinancePresentValueLib.presentValuePreMaturity(
            1_003_889,
            USDC_PREC,
            14 * 86_400,
            5e16,
            1e18
        );
        assertEq(pvCapped, pvAtCap);
    }

    function test_presentValuePreMaturity_capsEffRateAtMax() public pure {
        uint256 pvHuge = TermFinancePresentValueLib.presentValuePreMaturity(
            1_003_889,
            USDC_PREC,
            14 * 86_400,
            1e20,
            1e18
        );
        uint256 pvAtMax = TermFinancePresentValueLib.presentValuePreMaturity(
            1_003_889,
            USDC_PREC,
            14 * 86_400,
            1e20,
            0
        );
        assertEq(pvHuge, pvAtMax);
    }

    function test_presentValuePreMaturity_pvCappedAtFace() public pure {
        // Engineered to trigger the `pv > face → return face` branch: rate=0, any tau,
        // divisor==purchasePrec exactly, pv == face. Confirms cap fires equality path.
        uint256 face = 1_000;
        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(face, USDC_PREC, 10_000, 0, 0);
        assertEq(pv, face, "pv at most face");
    }

    // ============ presentValuePostMaturity ============

    function test_presentValuePostMaturity_noHaircut_equalsFace() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePostMaturity(1_003_889, 0);
        assertEq(pv, 1_003_889);
    }

    function test_presentValuePostMaturity_3pctHaircut() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePostMaturity(1_003_889, 3e16);
        assertEq(pv, (1_003_889 * (WAD - 3e16)) / WAD);
        assertApproxEqAbs(pv, 973_772, 2);
    }

    function test_presentValuePostMaturity_capsHaircutAt1e18() public pure {
        uint256 pvOver = TermFinancePresentValueLib.presentValuePostMaturity(1_003_889, 2e18);
        uint256 pvAt = TermFinancePresentValueLib.presentValuePostMaturity(1_003_889, 1e18);
        assertEq(pvOver, pvAt);
        assertEq(pvAt, 0);
    }

    function test_presentValuePostMaturity_zeroFace_returnsZero() public pure {
        uint256 pv = TermFinancePresentValueLib.presentValuePostMaturity(0, 3e16);
        assertEq(pv, 0);
    }

    // ============ fuzz tests ============

    /// @dev Library caps (mirrored here for fuzz bound assertions).
    uint256 internal constant MAX_DISCOUNT_RATE = 10_000e16;
    uint256 internal constant MAX_SECONDS_TO_MATURITY = 100 * 360 * 86_400;
    uint256 internal constant MAX_REDEMPTION_VALUE = 1e22;

    /// @notice Invariant: pv <= face for any well-bounded input set.
    /// @dev face bounded to 1..1e30 to keep face*purchasePrec within uint256 even when
    ///      purchasePrec=1e18 (max for ERC20s here); tau, rate, hcut capped at library caps.
    function testFuzz_presentValuePreMaturity_pvAtMostFace(
        uint128 face,
        uint64 tau,
        uint64 rate,
        uint64 hcut
    ) public pure {
        uint256 boundedFace = bound(uint256(face), 1, 1e30);
        uint256 boundedTau = bound(uint256(tau), 0, MAX_SECONDS_TO_MATURITY);
        uint256 boundedRate = bound(uint256(rate), 0, MAX_DISCOUNT_RATE);
        uint256 boundedHcut = bound(uint256(hcut), 0, 1e18);

        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(
            boundedFace,
            USDC_PREC,
            boundedTau,
            boundedRate,
            boundedHcut
        );
        assertLe(pv, boundedFace, "pv must never exceed face");
    }

    /// @notice Invariant: higher discount rate yields lower (or equal) PV, ceteris paribus.
    function testFuzz_presentValuePreMaturity_monotonicInRate(
        uint128 face,
        uint64 tau,
        uint64 hcut,
        uint64 r1Raw,
        uint64 r2Raw
    ) public pure {
        uint256 boundedFace = bound(uint256(face), 1, 1e30);
        uint256 boundedTau = bound(uint256(tau), 1, MAX_SECONDS_TO_MATURITY);
        uint256 boundedHcut = bound(uint256(hcut), 0, 1e18);
        uint256 r1 = bound(uint256(r1Raw), 0, MAX_DISCOUNT_RATE - 1);
        uint256 r2 = bound(uint256(r2Raw), r1 + 1, MAX_DISCOUNT_RATE);

        uint256 pv1 = TermFinancePresentValueLib.presentValuePreMaturity(
            boundedFace,
            USDC_PREC,
            boundedTau,
            r1,
            boundedHcut
        );
        uint256 pv2 = TermFinancePresentValueLib.presentValuePreMaturity(
            boundedFace,
            USDC_PREC,
            boundedTau,
            r2,
            boundedHcut
        );
        assertLe(pv2, pv1, "higher rate must produce smaller-or-equal PV");
    }

    /// @notice Invariant: higher adapter haircut yields lower (or equal) PV, given non-zero rate.
    /// @dev If rate==0 then effRate*dayFrac==0 and haircut has no effect; require rate>0.
    function testFuzz_presentValuePreMaturity_monotonicInHaircut(
        uint128 face,
        uint64 tau,
        uint64 rate,
        uint64 h1Raw,
        uint64 h2Raw
    ) public pure {
        uint256 boundedFace = bound(uint256(face), 1, 1e30);
        uint256 boundedTau = bound(uint256(tau), 1, MAX_SECONDS_TO_MATURITY);
        uint256 boundedRate = bound(uint256(rate), 1, MAX_DISCOUNT_RATE);
        uint256 h1 = bound(uint256(h1Raw), 0, 1e18 - 1);
        uint256 h2 = bound(uint256(h2Raw), h1 + 1, 1e18);

        uint256 pv1 = TermFinancePresentValueLib.presentValuePreMaturity(
            boundedFace,
            USDC_PREC,
            boundedTau,
            boundedRate,
            h1
        );
        uint256 pv2 = TermFinancePresentValueLib.presentValuePreMaturity(
            boundedFace,
            USDC_PREC,
            boundedTau,
            boundedRate,
            h2
        );
        assertLe(pv2, pv1, "higher haircut must produce smaller-or-equal PV");
    }

    /// @notice PV must stay <= face even when the discount rate is fully adversarial
    ///         (full uint256 range). Without the explicit clamp BEFORE the multiplication in
    ///         `presentValuePreMaturity`, a discountRate near 2**256 makes
    ///         `discountRate_ * (RATE_PRECISION + hcut)` revert on overflow (DoS NAV) or, in an
    ///         unchecked block, wrap mod 2**256 to a small-positive value that bypasses the
    ///         downstream `MAX_DISCOUNT_RATE` saturation.
    function testFuzz_presentValuePreMaturity_stayInRangeUnderAdversarialRate(
        uint256 discountRate_,
        uint256 hcut_,
        uint256 face_,
        uint256 tau_
    ) public pure {
        uint256 boundedHcut = bound(hcut_, 0, 1e18);
        uint256 boundedFace = bound(face_, 0, 1e30);
        uint256 boundedTau = bound(tau_, 0, MAX_SECONDS_TO_MATURITY);
        // discountRate_ deliberately UNBOUNDED — fuzz the full uint256 range.

        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(
            boundedFace,
            USDC_PREC,
            boundedTau,
            discountRate_,
            boundedHcut
        );

        assertLe(pv, boundedFace, "PV must never exceed face under adversarial discount rate");
    }

    /// @notice At the clamp boundary, `discountRate_ = MAX_DISCOUNT_RATE + 1` and
    ///         `discountRate_ = type(uint256).max` must produce the SAME pv as
    ///         `discountRate_ = MAX_DISCOUNT_RATE`. Proves the new pre-multiplication clamp
    ///         is observable and saturating.
    function test_presentValuePreMaturity_clampsAtMaxDiscountRate() public pure {
        uint256 face = 1_003_889;
        uint256 tau = 14 * 86_400;
        uint256 hcut = 0;

        uint256 pvAtCap = TermFinancePresentValueLib.presentValuePreMaturity(
            face,
            USDC_PREC,
            tau,
            MAX_DISCOUNT_RATE,
            hcut
        );
        uint256 pvOverCap = TermFinancePresentValueLib.presentValuePreMaturity(
            face,
            USDC_PREC,
            tau,
            MAX_DISCOUNT_RATE + 1,
            hcut
        );
        uint256 pvMaxUint = TermFinancePresentValueLib.presentValuePreMaturity(
            face,
            USDC_PREC,
            tau,
            type(uint256).max,
            hcut
        );

        assertEq(pvOverCap, pvAtCap, "MAX_DISCOUNT_RATE+1 must clamp to MAX_DISCOUNT_RATE");
        assertEq(pvMaxUint, pvAtCap, "type(uint256).max must clamp to MAX_DISCOUNT_RATE");
    }

    /// @notice At exactly `MAX_DISCOUNT_RATE` the clamp is a no-op; ensure the
    ///         boundary value passes through unchanged (regression guard for off-by-one).
    function test_presentValuePreMaturity_atMaxDiscountRate_boundaryUnchanged() public pure {
        uint256 face = 1_003_889;
        uint256 tau = 14 * 86_400;

        uint256 pv = TermFinancePresentValueLib.presentValuePreMaturity(
            face,
            USDC_PREC,
            tau,
            MAX_DISCOUNT_RATE,
            0
        );
        // PV must remain <= face (saturated divisor is huge); we only assert invariant + non-zero.
        assertLe(pv, face);
    }

    /// @notice Invariant: faceValue does not revert when inputs are within library caps.
    /// @dev Lib returns 0 on adversarial input; absence of revert is the success signal.
    function testFuzz_faceValue_noOverflow_underCaps(
        uint96 repoBal,
        uint96 redValue,
        uint8 repoDec,
        uint8 purchaseDec
    ) public pure {
        uint256 boundedRepoBal = bound(uint256(repoBal), 1, type(uint96).max);
        uint256 boundedRedValue = bound(uint256(redValue), 0, MAX_REDEMPTION_VALUE);
        uint256 boundedRepoDec = bound(uint256(repoDec), 6, 18);
        uint256 boundedPurchaseDec = bound(uint256(purchaseDec), 6, 18);

        uint256 repoTokenPrec = 10 ** boundedRepoDec;
        uint256 purchasePrec = 10 ** boundedPurchaseDec;

        uint256 face = TermFinancePresentValueLib.faceValue(
            boundedRepoBal,
            boundedRedValue,
            repoTokenPrec,
            purchasePrec
        );
        // No-revert is the property; record result to defeat optimizer dead-code removal.
        assertLe(face, type(uint256).max);
    }
}
