// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Errors} from "../../libraries/errors/Errors.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IExtTermAuctionBidLocker} from "./ext/IExtTermAuctionBidLocker.sol";
import {IExtTermAuctionOfferLocker} from "./ext/IExtTermAuctionOfferLocker.sol";
import {IExtTermDiscountRateAdapter} from "./ext/IExtTermDiscountRateAdapter.sol";
import {IExtTermRepoCollateralManager} from "./ext/IExtTermRepoCollateralManager.sol";
import {IExtTermRepoServicer} from "./ext/IExtTermRepoServicer.sol";
import {IExtTermRepoToken} from "./ext/IExtTermRepoToken.sol";
import {TermFinancePendingBidsStorageLib} from "./lib/TermFinancePendingBidsStorageLib.sol";
import {TermFinancePendingOffersStorageLib} from "./lib/TermFinancePendingOffersStorageLib.sol";
import {TermFinancePresentValueLib} from "./lib/TermFinancePresentValueLib.sol";
import {TermFinanceSubstrateLib} from "./lib/TermFinanceSubstrateLib.sol";

/// @title TermFinanceBalanceFuse
/// @author IPOR Labs
/// @notice Reports PlasmaVault's net value in the Term Finance market in WAD-USD across both
///         the lender side (held `TermRepoToken` PV, pending offers) and the borrower side
///         (locked collateral, pending bid locked collateral, outstanding debt).
/// @dev Signed-int aggregation:
///        +heldRepoTokenPV (≥0)           — lender side
///        +pendingOffersValueWad (≥0)     — lender side
///        +lockedCollateralValueWad (≥0)  — borrower side
///        +pendingBidsCollateralWad (≥0)  — borrower side
///        −outstandingDebtPvValueWad (≥0) — borrower side (returned as negative)
///      Aggregation is performed in straight-line internal code: `balanceOf` iterates the
///      servicer substrates and delegates each leg to `_signedValueForServicerInternal`. No
///      external self-call is used — under PlasmaVault delegatecall semantics `address(this)`
///      is the vault (NOT this fuse), so a `try this.fn(...)` would hit the vault fallback
///      and degrade every leg to zero unconditionally. Instead each FOREIGN Term Finance
///      call (collateral manager probe, accepted-token count, locked offer / bid read,
///      adapter discount rate / haircut, shortfall haircut, servicer topology) is wrapped in
///      its own `try/catch` at the call site (`_tryReadCollateralManager`,
///      `_tryReadAcceptedCollateralCount`, `_tryReadLockedOfferAmount`,
///      `_tryReadLockedBidIsLive`, `_tryGetDiscountRate`, `_tryGetRepoRedemptionHaircut`,
///      `_tryReadShortfallHaircut`, `_tryReadServicerTopology`, `_tryReadPurchaseToken`,
///      `_tryReadRepoToken`, `_tryReadEndOfRepurchaseWindow`, and the explicit `try` around
///      `IExtTermRepoServicer.getBorrowerRepurchaseObligation` in `_debtValueWadForServicer`).
///      A single broken servicer leg degrades to 0 without affecting other legs.
///
///      The reverts that DO propagate out of `balanceOf` are:
///        - `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer)` — propagates
///          when ANY leg's oracle read FAILS (revert OR returns 0) AND the servicer carries
///          TRACKED exposure (held repo position, pending offers in storage, pending bids
///          in storage, any locked collateral balance > 0, or positive debt obligation).
///          UNTRACKED legs degrade silently to 0 — a single mis-configured oracle on an
///          unused servicer cannot brick `balanceOf`. The collateral-side helpers
///          (`_heldTermRepoTokenPv`, `_pendingOffersValueWad`,
///          `_pendingBidsValueWadForServicer`, `_lockedCollateralValueWad`) return
///          `(bool ok, uint256 valueWad, bool hasAnyPosition)` so the aggregator can detect
///          "tracked-but-priced-zero" cases (e.g. positive locked collateral whose oracle
///          returned 0). Oracle calls flow through `_tryGetAssetPrice` which normalises
///          BOTH failure modes (production `UnsupportedAsset` / `UnexpectedPriceResult`
///          reverts AND mock-style zero returns) into a uniform `ok == false`. The
///          debt-side `_debtPvWad` is reached only when `obligationFace > 0`
///          (tracked-by-construction) so it re-raises this error directly on oracle
///          failure.
///        - `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer(servicer)` — propagates
///          from `_debtValueWadForServicer` ONLY when the borrower-side
///          `getBorrowerRepurchaseObligation` read fails AND the vault has tracked exposure
///          (prior collateral value > 0 OR pending bids tracked in storage). Without
///          tracked exposure the leg silently degrades to 0. This is the second per-leg
///          revert that intentionally propagates to freeze ERC4626 share math.
///        - `TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(servicer)` — propagates
///          from `_debtPvWad` when ANY supporting read (purchase token / repo token /
///          end-of-repurchase-window / Adapter-B discount rate) fails while the borrower
///          is tracked-by-construction (`obligationFace > 0`). Silently zeroing the
///          negative debt leg in that state would open an ERC4626 share-mint window.
///          Mirrors the same fail-fast posture as the other tracked-leg reverts.
///        - `Errors.WrongAddress` — propagates from `balanceOf` itself when the PlasmaVault
///          price oracle middleware address is unset (a misconfiguration NAV signal, not a
///          per-leg failure).
/// @dev Defensive saturation: each per-servicer signed leg is clamped to ±`MAX_VALUE_PER_LEG = 1e36`
///      before the signed sum so that `int256` arithmetic cannot overflow even under
///      adversarial oracle returns. Final aggregation is converted to `uint256` via
///      `SafeCast.toUint256` which reverts on net-negative — matching `AaveV3BalanceFuse` /
///      `MorphoBalanceFuse` and preventing the ERC4626 share-mint attack window on the
///      borrower side.
contract TermFinanceBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @notice Reverts when an oracle returns 0 for ANY leg's pricing path on a TRACKED
    ///         servicer (held repo position, pending offers, pending bids in storage,
    ///         locked collateral, or positive debt obligation).
    /// @dev Untracked legs degrade silently to 0, tracked legs propagate as
    ///      NAV-blocking. The fail-fast posture matches
    ///      `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer`: silently
    ///      under-reporting collateral or over-reporting equity on a tracked borrower opens
    ///      an ERC4626 share-mint attack window. Off-chain monitoring inspects the
    ///      substrate config + accepted-collateral-token list to find the misconfigured
    ///      oracle entry. The token diagnostic is intentionally omitted: pricing may fail at
    ///      one of several call sites within a single leg and the servicer-substrate is the
    ///      authoritative key for triage.
    /// @param servicer Servicer substrate whose tracked leg failed price reading.
    error TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(address servicer);

    /// @notice Reverts when the borrower-side `getBorrowerRepurchaseObligation` read fails on
    ///         a servicer where the vault has positive tracked exposure (collateral locked or
    ///         pending bids).
    /// @dev This is one of two per-leg reverts that intentionally propagate out of
    ///      `balanceOf` (the other is
    ///      `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked`).
    ///      Debt-leg failure semantics: silently zeroing debt for a tracked borrower
    ///      would over-report equity (collateral + pending bids still contribute positive
    ///      while the negative debt leg disappears) and open a share-mint attack window.
    ///      The revert intentionally propagates so ERC4626 share math freezes until the
    ///      proxy issue is resolved.
    /// @param servicer Servicer whose debt read failed despite tracked exposure.
    error TermFinanceBalanceFuseDebtReadFailedForTrackedServicer(address servicer);

    /// @notice Reverts when the discount-rate or supporting topology read fails inside
    ///         `_debtPvWad` for a tracked borrower (positive `obligationFace`).
    /// @dev Mirror for the discount-rate, purchase-token, repo-token, and
    ///      end-of-repurchase-window reads that feed the borrower-side PV. Silent zeroing
    ///      of the debt leg while the collateral / pending bids legs remain positive opens
    ///      an ERC4626 share-mint attack window — the revert intentionally propagates so
    ///      NAV freezes until the proxy / adapter issue is resolved. Off-chain monitoring
    ///      keys on the servicer to triage which dependency (Adapter-B vs servicer proxy)
    ///      regressed.
    /// @param servicer Servicer whose debt PV inputs failed despite positive obligation.
    error TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(address servicer);

    /// @notice Reverts when the collateral-manager probe (`termRepoCollateralManager()` /
    ///         `numOfAcceptedCollateralTokens()` / accepted-count sanity) fails for a servicer
    ///         the vault has exposure to.
    /// @dev The probe runs BEFORE any leg is valued and gates the WHOLE servicer leg. A bare
    ///      `return 0` there silently zeroes EVERY leg — including the CM-independent held-repo
    ///      PV, pending offers, and the negative debt leg — bypassing the tracked
    ///      gates and opening the same share-mint / over-withdrawal window those gates close.
    ///      When the vault has detectable exposure (pending storage, held repo balance, or a
    ///      positive debt obligation) the revert intentionally propagates to freeze share math.
    /// @param servicer Servicer whose collateral-manager probe failed despite vault exposure.
    error TermFinanceBalanceFuseCollateralManagerReadFailedForTrackedServicer(address servicer);

    /// @notice Reverts when the Adapter-B `repoRedemptionHaircut` is non-zero for a held
    ///         (lender) position.
    /// @dev The lender held-PV path discounts via a rate-amplification haircut convention
    ///      (`effRate = rate * (1 + haircut)`) that OVER-reports NAV (~5pp) relative to Yearn's
    ///      face-cut once the adapter reports a non-zero `repoRedemptionHaircut` (it is `0` on
    ///      mainnet today). Rather than silently over-report a tracked held position, freeze
    ///      share math until the convention is revisited (see the `TermFinancePresent
    ///      ValueLib.presentValuePreMaturity` deviation note). Borrower debt PV is unaffected
    ///      (Convention B passes `adapterHaircut = 0`).
    /// @param servicer Servicer whose adapter reported a non-zero repoRedemptionHaircut.
    error TermFinanceBalanceFuseNonZeroRepoRedemptionHaircut(address servicer);

    /// @notice WAD-USD per-leg saturation bound used to prevent `int256` overflow in the
    ///         signed-int aggregation.
    /// @dev `1e36` is 18-dec WAD scaled by another 18 decimals of token
    ///      precision headroom. Applied symmetrically to the collateral and debt legs.
    int256 internal constant MAX_VALUE_PER_LEG = 1e36;

    /// @dev Unsigned mirror of `MAX_VALUE_PER_LEG` for uint256 comparisons before negation.
    ///      Kept in sync with `MAX_VALUE_PER_LEG`; if either is changed, both must change.
    uint256 internal constant MAX_VALUE_PER_LEG_UINT = 1e36;

    /// @notice Hard cap on the number of collateral tokens enumerated per servicer leg.
    /// @dev Live verification 2026-05-15 measured 1 accepted collateral token on the
    ///      probed Term Repo; typical deployments use 1–3 tokens. The cap of 8
    ///      provides comfortable headroom while preventing OOG bombs from a malicious /
    ///      misconfigured CollateralManager proxy upgrade.
    uint8 internal constant MAX_COLLATERAL_TOKENS_PER_SERVICER = 8;

    /// @notice Upper bound on `IERC20Metadata(token).decimals()` accepted by the NAV math.
    /// @dev `10 ** decimals` is the unit-precision factor used in PV math. An
    ///      adversarial / mis-upgraded token reporting `decimals() >= 78` overflows
    ///      `uint256` (10**78 > 2**256) and a value >= 30 already produces 1e30 which is
    ///      well past any real-world precision (USDC=6, WETH=18, the largest real token
    ///      uses 24). The cap of 30 protects every PV call site from a permanent NAV
    ///      brick while leaving headroom for any plausible future token. Out-of-range
    ///      decimals degrade the leg via the tracked gate (same path as a price-
    ///      zero on a tracked servicer).
    uint8 internal constant MAX_TOKEN_DECIMALS = 30;

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;
    /// @notice PlasmaVault market id assigned to Term Finance (see `IporFusionMarkets.TERM_FINANCE`).
    uint256 public immutable MARKET_ID;
    /// @notice Live Term Finance `TermController` proxy address used for `isTermDeployed` checks.
    address public immutable TERM_CONTROLLER;
    /// @notice Live Term Finance `TermDiscountRateAdapter` proxy (Adapter-B) used for pre-maturity PV.
    address public immutable DISCOUNT_RATE_ADAPTER;

    /// @notice Initialise immutables. All addresses must be non-zero, marketId must be > 0.
    /// @param marketId_ PlasmaVault market id (must equal `IporFusionMarkets.TERM_FINANCE` in practice).
    /// @param termController_ Term Finance evergreen controller proxy.
    /// @param discountRateAdapter_ Term Finance discount-rate adapter proxy (Adapter-B).
    constructor(uint256 marketId_, address termController_, address discountRateAdapter_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        if (termController_ == address(0)) revert Errors.WrongAddress();
        if (discountRateAdapter_ == address(0)) revert Errors.WrongAddress();

        VERSION = address(this);
        MARKET_ID = marketId_;
        TERM_CONTROLLER = termController_;
        DISCOUNT_RATE_ADAPTER = discountRateAdapter_;
    }

    /// @inheritdoc IMarketBalanceFuse
    /// @dev Iterates the substrate list, filters out `COLLATERAL_TOKEN` substrates (only
    ///      `SERVICER`-typed entries contribute to NAV — collateral-token substrates are
    ///      pure allowlist entries consumed by the action fuses), and aggregates each
    ///      servicer's signed valuation via the internal `_signedValueForServicerInternal`
    ///      helper (no external self-call — see file-level NatSpec for rationale).
    ///      Per-leg saturation to ±`MAX_VALUE_PER_LEG` keeps `int256` arithmetic safe under
    ///      adversarial oracle returns. The final signed accumulator is converted via
    ///      `SafeCast.toUint256` which reverts on net-negative — see the net-negative
    ///      rationale on `balanceOf`.
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory rawSubstrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 substrateCount = rawSubstrates.length;
        if (substrateCount == 0) return 0;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracleMiddleware == address(0)) revert Errors.WrongAddress();

        address plasmaVault = address(this);
        int256 totalValueWad;

        for (uint256 i; i < substrateCount; ++i) {
            bytes32 raw = rawSubstrates[i];
            // TYPE-byte filter: only SERVICER (0x00) substrates contribute to NAV.
            // COLLATERAL_TOKEN (0x01) substrates are allowlist entries consumed by action
            // fuses and would decode to a truncated keccak hash if treated as an address.
            if (!TermFinanceSubstrateLib.isServicerSubstrate(raw)) continue;

            address servicer = PlasmaVaultConfigLib.bytes32ToAddress(raw);
            if (servicer == address(0)) continue;

            int256 leg = _signedValueForServicerInternal(servicer, plasmaVault, priceOracleMiddleware);

            // Saturate per leg to ±MAX_VALUE_PER_LEG to keep int256 arithmetic safe
            // under adversarial oracle returns (mirrors PresentValueLib saturation).
            if (leg > MAX_VALUE_PER_LEG) leg = MAX_VALUE_PER_LEG;
            if (leg < -MAX_VALUE_PER_LEG) leg = -MAX_VALUE_PER_LEG;
            totalValueWad += leg;
        }

        // SafeCast.toUint256 reverts on negative input. Net-negative is treated as
        // ERC4626 insolvency signal — share math freezes, monitoring fires, recovery is
        // explicit via emergency procedures.
        return totalValueWad.toUint256();
    }

    /// @notice Internal per-servicer signed valuation entry point.
    /// @dev Probes the collateral manager and the accepted-collateral-token count via
    ///      try/catch helpers; if either fails the leg silently degrades to 0 (same effect
    ///      as the pre-refactor outer-catch swallow). A cap breach on
    ///      `numOfAcceptedCollateralTokens() > MAX_COLLATERAL_TOKENS_PER_SERVICER` also
    ///      silently degrades the leg — the cap is anti-griefing only, the unsigned 0 leg
    ///      matches the pre-refactor "catch consumes cap revert" behaviour and avoids a new
    ///      revert path leaking out of `balanceOf`.
    /// @dev Two reverts intentionally propagate out of this function:
    ///        (1) `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer` — raised
    ///            from `_debtValueWadForServicer` when a tracked borrower's debt-read fails.
    ///        (2) `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked` — raised
    ///            from `_collateralValueWadWithGate` / `_debtPvWad` when any oracle read
    ///            fails on a tracked servicer.
    ///      Both are intentional NAV-blocking signals (share-math freeze) and are NOT
    ///      wrapped in try/catch.
    /// @param servicer_ Servicer substrate to value.
    /// @param plasmaVault_ Vault address (== `address(this)` under delegatecall).
    /// @param priceOracleMiddleware_ Cached PlasmaVault oracle middleware address.
    /// @return Signed WAD-USD contribution from this servicer (can be negative).
    function _signedValueForServicerInternal(
        address servicer_,
        address plasmaVault_,
        address priceOracleMiddleware_
    ) internal view returns (int256) {
        // The collateral-manager probe gates the WHOLE servicer leg. On failure
        // we must NOT blanket-zero it — that would silently drop the CM-independent held-repo,
        // pending-offer, and negative debt legs and bypass the tracked gates.
        // Degrade to 0 only for a servicer with no detectable exposure; otherwise freeze.
        (bool cmOk, address collateralManager) = _tryReadCollateralManager(servicer_);
        if (!cmOk || collateralManager == address(0)) {
            return _gateOnCollateralManagerProbeFailure(servicer_, plasmaVault_);
        }

        (bool countOk, uint8 acceptedCollateralCount) = _tryReadAcceptedCollateralCount(collateralManager);
        if (!countOk || acceptedCollateralCount > MAX_COLLATERAL_TOKENS_PER_SERVICER) {
            return _gateOnCollateralManagerProbeFailure(servicer_, plasmaVault_);
        }

        return
            _signedValueForServicerImpl(
                servicer_,
                plasmaVault_,
                priceOracleMiddleware_,
                collateralManager,
                acceptedCollateralCount
            );
    }

    /// @notice Per-servicer signed valuation body. Sums collateral-side legs (≥0) with the
    ///         debt leg (≤0); gates a re-raise when a tracked leg priced to zero.
    /// @dev Sign convention:
    ///        collateral aggregation (held repo PV + pending offers + pending bids locked
    ///          collateral + actively locked collateral) → non-negative `int256`.
    ///        debt aggregation → non-positive `int256` (returned as negative).
    /// @dev Tracked-vs-untracked gate: each collateral-side helper returns
    ///      `(bool ok, uint256 valueWad, bool hasAnyPosition)` so the aggregator can
    ///      distinguish "no tracked exposure at all" (silently zero on price failure) from
    ///      "tracked but priced to zero by a broken oracle" (must re-raise). The combined
    ///      tracked signal is OR of: cheap pre-call storage signal (`_hasTrackedExposure`),
    ///      the `hasAnyPosition` flag from each helper, and positive `sum`. A debt
    ///      obligation `> 0` is tracked by construction and handled inside `_debtPvWad`.
    /// @param servicer_ Servicer substrate.
    /// @param plasmaVault_ Vault address.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @param collateralManager_ TermRepoCollateralManager paired with `servicer_`.
    /// @param acceptedCollateralCount_ `cm.numOfAcceptedCollateralTokens()`.
    /// @return Per-servicer signed WAD-USD valuation.
    function _signedValueForServicerImpl(
        address servicer_,
        address plasmaVault_,
        address priceOracleMiddleware_,
        address collateralManager_,
        uint8 acceptedCollateralCount_
    ) internal view returns (int256) {
        // Aggregate collateral-side value with the tracked-vs-untracked oracle gate
        // applied in `_collateralValueWadWithGate`. The split keeps the stack depth manageable
        // (four (ok, value, hasPosition) tuples + cumulative signals overflow the 16-slot
        // limit when inlined alongside the debt leg in a single frame).
        uint256 collateralSum = _collateralValueWadWithGate(
            servicer_,
            plasmaVault_,
            priceOracleMiddleware_,
            collateralManager_,
            acceptedCollateralCount_
        );

        int256 collateralValue = collateralSum.toInt256();
        int256 debtValue = _debtValueWadForServicer(
            servicer_,
            plasmaVault_,
            priceOracleMiddleware_,
            collateralValue
        );

        return collateralValue + debtValue;
    }

    /// @notice Aggregate the four collateral-side legs and apply the oracle gate.
    /// @dev Each helper returns `(bool ok, uint256 valueWad, bool hasAnyPosition)`. We
    ///      accumulate the values, OR the `hasAnyPosition` flags into a single tracked
    ///      signal, and OR the `!ok` bits into a single anyPriceZero signal. The
    ///      pre-call storage signal `_hasTrackedExposure(servicer_)` covers the case where
    ///      every priced leg returned `(true, 0)` but the vault still has tracked bids in
    ///      storage. If `anyPriceZero && (trackedPre || trackedFromLegs || sum > 0)` we
    ///      re-raise; otherwise an untracked price-zero degrades silently to a 0 leg.
    /// @param servicer_ Servicer substrate.
    /// @param plasmaVault_ Vault address.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @param collateralManager_ Paired CollateralManager.
    /// @param acceptedCollateralCount_ `cm.numOfAcceptedCollateralTokens()`.
    /// @return Aggregate collateral-side WAD-USD value as a non-negative `uint256`. Reverts
    ///         iff tracked + priced-zero.
    function _collateralValueWadWithGate(
        address servicer_,
        address plasmaVault_,
        address priceOracleMiddleware_,
        address collateralManager_,
        uint8 acceptedCollateralCount_
    ) internal view returns (uint256) {
        bool anyPriceZero;
        bool trackedFromLegs;
        uint256 sum;
        {
            (bool ok1, uint256 v1, bool hasHeld) = _heldTermRepoTokenPv(
                servicer_,
                plasmaVault_,
                priceOracleMiddleware_
            );
            if (!ok1) anyPriceZero = true;
            if (hasHeld) trackedFromLegs = true;
            sum += v1;
        }
        {
            (bool ok2, uint256 v2, bool hasOffers) = _pendingOffersValueWad(servicer_, priceOracleMiddleware_);
            if (!ok2) anyPriceZero = true;
            if (hasOffers) trackedFromLegs = true;
            sum += v2;
        }
        {
            (bool ok3, uint256 v3, bool hasBids) = _pendingBidsValueWadForServicer(servicer_, priceOracleMiddleware_);
            if (!ok3) anyPriceZero = true;
            if (hasBids) trackedFromLegs = true;
            sum += v3;
        }
        {
            (bool ok4, uint256 v4, bool hasLocked) = _lockedCollateralValueWad(
                plasmaVault_,
                priceOracleMiddleware_,
                collateralManager_,
                acceptedCollateralCount_
            );
            if (!ok4) anyPriceZero = true;
            if (hasLocked) trackedFromLegs = true;
            sum += v4;
        }

        if (anyPriceZero) {
            // Cheap pre-call tracked signal: any pending bid in vault-owned storage means the
            // vault has expressed borrower intent regardless of the Term proxy state. Matches
            // the `_hasTrackedExposure` signal used by the debt-leg gate.
            bool trackedPre = _hasTrackedExposure(servicer_);
            if (trackedPre || trackedFromLegs || sum > 0) {
                revert TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer_);
            }
            // Untracked + priced zero: silently degrade. The debt leg's tracked-exposure
            // gate keeps its semantics unchanged.
        }

        return sum;
    }

    /// @notice Held TermRepoToken present value for a single servicer (lender-side leg).
    /// @dev Returns `(ok, valueWad, hasAnyPosition)` where `hasAnyPosition` signals
    ///      that the vault holds a non-zero balance of the servicer's repo token (regardless
    ///      of pricing success). `ok == false` signals that the IPOR oracle returned
    ///      `price == 0` for the purchase token — propagated to the caller for tracked-vs-
    ///      untracked gating.
    /// @param servicer_ Servicer substrate.
    /// @param plasmaVault_ Vault address.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @return ok False iff a pricing-side oracle returned `price == 0`.
    /// @return valueWad WAD-USD value of the held TermRepoToken position (0 on `ok == false`).
    /// @return hasAnyPosition True iff the vault holds a positive balance of the repo token.
    function _heldTermRepoTokenPv(
        address servicer_,
        address plasmaVault_,
        address priceOracleMiddleware_
    ) internal view returns (bool ok, uint256 valueWad, bool hasAnyPosition) {
        // Probe the repoToken address with the standalone wrapper so we
        // can read the vault's held balance EVEN WHEN the broader topology read fails
        // (e.g. one of `purchaseToken` / `decimals` / `redemptionValue` reverts). Without
        // this, a selectively-paused proxy on those neighbouring reads would silently
        // zero the held leg and bypass the tracked gate for a vault that holds a positive
        // repoToken balance without any pending-storage signal.
        (bool rtOk, address repoTokenAddr) = _tryReadRepoToken(servicer_);
        if (!rtOk || repoTokenAddr == address(0)) {
            // Servicer cannot even surface its repoToken — no held read possible. Degrade
            // silently; caller's storage signal (`_hasTrackedExposure`) still gates other
            // legs if pending state exists.
            return (true, 0, false);
        }
        (bool balOk, uint256 repoBal) = _tryReadRepoTokenBalance(repoTokenAddr, plasmaVault_);
        if (!balOk) {
            // Held balance unreadable. Signal `hasAnyPosition = true` so the caller's
            // tracked gate fires — we cannot prove a held position is zero, and silently
            // zeroing a potentially-positive held leg is the failure mode the tracked
            // gate is designed to prevent.
            return (false, 0, true);
        }
        if (repoBal == 0) return (true, 0, false);

        (bool topologyOk, ServicerTopology memory top) = _tryReadServicerTopology(servicer_);
        // Topology fail with non-zero held balance is a tracked-but-unpriced condition: we know the
        // vault has a tracked held position but cannot price it. Re-raise via `ok=false`.
        if (!topologyOk) return (false, 0, true);

        // hasAnyPosition is set as soon as the vault holds a non-zero balance — this is what
        // makes the "tracked-but-priced-zero" edge case re-raise correctly when the oracle
        // returns 0.
        hasAnyPosition = true;

        uint256 price;
        uint256 priceCombinedDecimals;
        {
            (bool priceOk, uint256 p, uint256 pDec) = _tryGetAssetPrice(priceOracleMiddleware_, top.purchaseToken);
            if (!priceOk) return (false, 0, hasAnyPosition);
            price = p;
            priceCombinedDecimals = uint256(top.purchaseDec) + pDec;
        }

        uint256 pvHeld = _heldPvInPurchase(servicer_, top, repoBal);
        if (pvHeld == 0) return (true, 0, hasAnyPosition);

        return (true, IporMath.convertToWad(pvHeld * price, priceCombinedDecimals), hasAnyPosition);
    }

    /// @notice Compute the held position's PV in purchase-token raw units. Extracted from
    ///         `_heldTermRepoTokenPv` to keep that function under the 16-slot stack limit
    ///         after introducing the third return slot for the tracked-signal flag.
    /// @param servicer_ Servicer substrate.
    /// @param top_ Topology snapshot returned by `_tryReadServicerTopology`.
    /// @param repoBal_ Vault's repo-token balance.
    /// @return pvInPurchase PV of the held position in purchase-token raw units.
    function _heldPvInPurchase(
        address servicer_,
        ServicerTopology memory top_,
        uint256 repoBal_
    ) internal view returns (uint256 pvInPurchase) {
        uint256 purchasePrec = 10 ** uint256(top_.purchaseDec);
        uint256 repoTokenPrec = 10 ** uint256(top_.repoTokenDec);
        uint256 faceInPurchase = TermFinancePresentValueLib.faceValue(
            repoBal_,
            top_.redValue,
            repoTokenPrec,
            purchasePrec
        );
        return _pvForFace(servicer_, top_.repoToken, top_.tred, purchasePrec, faceInPurchase);
    }

    /// @notice Pending offers WAD-USD value for a single servicer (lender-side leg, flat
    ///         `lockedAmount` — Option A).
    /// @dev Returns `(ok, valueWad, hasAnyPosition)` where `hasAnyPosition == true`
    ///      iff there is AT LEAST ONE pending offer entry in vault-owned storage (mirrors
    ///      `_pendingBidsValueWadForServicer` — storage presence is authoritative). `ok ==
    ///      false` signals the purchase-token oracle returned `price == 0` (or reverted)
    ///      whenever the storage has entries, regardless of whether a live entry could be
    ///      confirmed on the locker. This closes the offers-asymmetry window where a broken
    ///      locker would short-circuit the helper before the price read, leaving
    ///      `anyPriceZero` unset at the caller and silently degrading NAV on a tracked
    ///      servicer.
    ///      Each id carries its own `offerLocker` so cross-cycle offers are read against
    ///      the correct locker. Authoritative amount comes from storage,
    ///      but the live-check on each id pruning stale entries from the VALUE sum is
    ///      preserved: cleared / cancelled / refunded ids contribute 0 to `valueWad` even
    ///      though they still keep `hasAnyPosition = true` until cleanup runs.
    /// @param servicer_ Servicer substrate.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @return ok False iff the purchase-token oracle returned `price == 0` (or reverted)
    ///         while storage carries at least one entry for this servicer.
    /// @return valueWad WAD-USD value of pending offers for this servicer.
    /// @return hasAnyPosition True iff at least one pending offer entry exists in storage.
    function _pendingOffersValueWad(
        address servicer_,
        address priceOracleMiddleware_
    ) internal view returns (bool ok, uint256 valueWad, bool hasAnyPosition) {
        (
            address[] memory pendingLockers,
            bytes32[] memory pendingIds,
            uint256[] memory pendingAmounts
        ) = TermFinancePendingOffersStorageLib.getPendingOffersForServicer(servicer_);

        uint256 pendingCount = pendingIds.length;
        if (pendingCount == 0) return (true, 0, false);

        // Storage entry presence alone signals tracked exposure — matches `_hasTrackedExposure`
        // and `_pendingBidsValueWadForServicer`. This is what lets the tracked gate fire when
        // the locker proxy is broken (so no live entry can be confirmed) AND the oracle
        // returns 0 — without this, `anyPriceZero` would stay false at the caller because
        // no leg queried the oracle.
        hasAnyPosition = true;

        // Wrap servicer read in try/catch and treat the
        // `address(0)` / revert paths as tracked-but-unpriced signals — a paused or upgraded servicer
        // proxy must NOT silently zero out a tracked pending-offer leg (that was the
        // pre-fix behaviour and the exact failure mode the tracked gate was designed to catch).
        (bool ptOk, address purchaseToken) = _tryReadPurchaseToken(servicer_);
        if (!ptOk || purchaseToken == address(0)) return (false, 0, hasAnyPosition);

        // Always query the oracle when storage has entries. A failed oracle on a tracked
        // servicer is a NAV-blocking signal regardless of whether a live offer can be
        // confirmed on the locker (tracked gate + offers-asymmetry follow-up).
        (bool priceOk, uint256 price, uint256 priceDecimals) = _tryGetAssetPrice(
            priceOracleMiddleware_,
            purchaseToken
        );
        if (!priceOk) return (false, 0, hasAnyPosition);

        uint256 priceCombinedDecimals = uint256(IERC20Metadata(purchaseToken).decimals()) + priceDecimals;
        valueWad = _sumLivePendingOffers(pendingLockers, pendingIds, pendingAmounts, price, priceCombinedDecimals);
        ok = true;
    }

    /// @notice Inner value-loop for `_pendingOffersValueWad`. Walks the three parallel arrays,
    ///         skips stale / zero-locker / cleared entries, and sums the WAD value of each
    ///         live entry using its STORAGE amount and the cached purchase-token price.
    /// @dev Extracted to keep `_pendingOffersValueWad` under the 16-slot stack limit after
    ///      adding the third return tuple slot for the tracked-signal flag.
    /// @param pendingLockers Parallel array of locker addresses (one per entry).
    /// @param pendingIds Parallel array of offer ids.
    /// @param pendingAmounts Parallel array of storage amounts (authoritative).
    /// @param price Cached purchase-token oracle price mantissa.
    /// @param priceCombinedDecimals Purchase-token decimals + price decimals.
    /// @return valueWad Aggregate WAD-USD value of live pending offers.
    function _sumLivePendingOffers(
        address[] memory pendingLockers,
        bytes32[] memory pendingIds,
        uint256[] memory pendingAmounts,
        uint256 price,
        uint256 priceCombinedDecimals
    ) internal view returns (uint256 valueWad) {
        uint256 pendingCount = pendingIds.length;
        for (uint256 j; j < pendingCount; ++j) {
            address offerLocker = pendingLockers[j];
            if (offerLocker == address(0)) continue;
            // `callOk` only signals that the staticcall to `lockedOffer` did not revert; it
            // does NOT imply the offer is still locked. The "still-locked" decision is the
            // composite check `callOk && onChainAmount != 0` below.
            (bool callOk, uint256 onChainAmount) = _tryReadLockedOfferAmount(offerLocker, pendingIds[j]);
            if (!callOk || onChainAmount == 0) {
                // Cleared / refunded / cancelled / broken proxy — value sits elsewhere.
                continue;
            }
            // Authoritative amount comes from storage; on-chain read only signals "still locked".
            valueWad += IporMath.convertToWad(pendingAmounts[j] * price, priceCombinedDecimals);
        }
    }

    /// @notice Pending-bids locked-collateral WAD-USD value for a single servicer.
    /// @dev Returns `(ok, valueWad, hasAnyPosition)` where `hasAnyPosition == true`
    ///      iff there is AT LEAST ONE pending bid entry in vault-owned storage (regardless of
    ///      on-chain liveness or pricing success). Storage entries authoritatively signal
    ///      borrower intent — even a stale entry whose locker reverts represents a leg the
    ///      vault has not yet resolved. `ok == false` signals a per-token oracle returned
    ///      `price == 0` somewhere in the priced bids; the caller decides whether to
    ///      re-raise based on the combined tracked signal.
    ///      Mirror of `_pendingOffersValueWad` for the borrower side. Reads bids from
    ///      `TermFinancePendingBidsStorageLib`; each entry carries a per-bid `bidLocker`
    ///      and parallel `collateralTokens` / `collateralAmounts`
    ///      arrays. The live `lockedBid` query is used purely as a "still locked" signal
    ///      (canonical predicate `bidder != 0 && amount != 0`).
    /// @param servicer_ Servicer substrate.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @return ok False iff at least one priced token had `price == 0`.
    /// @return valueWad Aggregate WAD-USD value of all live pending bids' collateral.
    /// @return hasAnyPosition True iff at least one pending bid entry exists in storage.
    function _pendingBidsValueWadForServicer(
        address servicer_,
        address priceOracleMiddleware_
    ) internal view returns (bool ok, uint256 valueWad, bool hasAnyPosition) {
        (
            address[] memory bidLockers,
            bytes32[] memory bidIds,
            ,
            address[][] memory collateralTokens,
            uint256[][] memory collateralAmounts
        ) = TermFinancePendingBidsStorageLib.getPendingBidsForServicer(servicer_);

        uint256 pendingCount = bidIds.length;
        if (pendingCount == 0) return (true, 0, false);

        // Storage entry presence alone signals tracked exposure — matches `_hasTrackedExposure`.
        hasAnyPosition = true;

        ok = true;
        for (uint256 j; j < pendingCount; ++j) {
            (bool legOk, uint256 legValue) = _pendingBidLegValueWad(
                priceOracleMiddleware_,
                bidLockers[j],
                bidIds[j],
                collateralTokens[j],
                collateralAmounts[j]
            );
            if (!legOk) ok = false;
            valueWad += legValue;
        }
    }

    /// @notice WAD-USD value of a single pending bid leg (skips if stale).
    /// @dev Returns `(ok, valueWad)` where `ok == false` signals a per-token oracle
    ///      returned `price == 0` somewhere in this bid's collateral list. Split out of
    ///      `_pendingBidsValueWadForServicer` to avoid stack-too-deep in the double-loop body.
    ///      Applies the canonical stale-bid predicate then prices every (token, amount)
    ///      pair via `_priceTokenAmountWadGuarded`.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @param bidLocker_ Locker bound to the bid at lockBids time.
    /// @param bidId_ Pending bid id.
    /// @param tokens_ Per-bid collateral tokens (parallel to `amounts_`).
    /// @param amounts_ Per-bid collateral amounts (parallel to `tokens_`).
    /// @return ok False iff at least one priced (token, amount) had `price == 0`.
    /// @return valueWad WAD-USD value of this bid's locked collateral (0 if stale or arrays mismatch).
    function _pendingBidLegValueWad(
        address priceOracleMiddleware_,
        address bidLocker_,
        bytes32 bidId_,
        address[] memory tokens_,
        uint256[] memory amounts_
    ) internal view returns (bool ok, uint256 valueWad) {
        if (bidLocker_ == address(0)) return (true, 0);

        // Canonical stale-bid predicate: prune iff bidder == 0 OR amount == 0.
        (bool callOk, bool isLive) = _tryReadLockedBidIsLive(bidLocker_, bidId_);
        if (!callOk || !isLive) return (true, 0);

        uint256 tokenCount = tokens_.length;
        // Defensive: storage lib guarantees parallel arrays, but bail if mismatched.
        if (tokenCount != amounts_.length) return (true, 0);

        ok = true;
        for (uint256 k; k < tokenCount; ++k) {
            (bool legOk, uint256 legValue) = _priceTokenAmountWadGuarded(
                priceOracleMiddleware_,
                tokens_[k],
                amounts_[k]
            );
            if (!legOk) ok = false;
            valueWad += legValue;
        }
    }

    /// @notice Convert a `(token, amount)` pair to WAD-USD at the IPOR oracle, with a
    ///         non-reverting "oracle failed" signal for the tracked gating.
    /// @dev Normalises BOTH oracle failure modes (returns 0 OR reverts with
    ///      `UnsupportedAsset` / `UnexpectedPriceResult` per `PriceOracleMiddleware`) into
    ///      `(false, 0)`. The try/catch makes the policy uniform regardless of how the
    ///      oracle reports missing entries — required for the production middleware which
    ///      reverts on missing prices.
    ///      Returns `(true, 0)` for `token == address(0)` or `amount == 0` (no pricing
    ///      needed, no failure). Returns `(false, 0)` on any oracle revert or zero price.
    ///      Returns `(true, value)` otherwise. Callers aggregate the `ok` bits and re-raise
    ///      the tracked-only error at the per-servicer aggregator.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @param token_ Token to price.
    /// @param amount_ Token raw amount.
    /// @return ok False iff a non-zero amount of a real token failed to price.
    /// @return valueWad WAD-USD value of `amount_` of `token_` (0 on failure).
    function _priceTokenAmountWadGuarded(
        address priceOracleMiddleware_,
        address token_,
        uint256 amount_
    ) internal view returns (bool ok, uint256 valueWad) {
        if (token_ == address(0) || amount_ == 0) return (true, 0);

        uint256 price;
        uint256 priceDecimals;
        try IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(token_) returns (uint256 p, uint256 pDec) {
            price = p;
            priceDecimals = pDec;
        } catch {
            return (false, 0);
        }
        if (price == 0) return (false, 0);

        uint8 tokenDec = IERC20Metadata(token_).decimals();
        uint256 priceCombinedDecimals = uint256(tokenDec) + priceDecimals;
        return (true, IporMath.convertToWad(amount_ * price, priceCombinedDecimals));
    }

    /// @notice Actively locked collateral WAD-USD value for a single servicer (borrower side,
    ///         post-clearing legs).
    /// @dev Returns `(ok, valueWad, hasAnyPosition)` where `hasAnyPosition == true`
    ///      iff at least one accepted collateral token has a positive `getCollateralBalance`
    ///      for the vault — the cheap on-chain signal that the vault has BORROWER side
    ///      exposure, regardless of pricing success. `ok == false` signals a per-token oracle
    ///      returned `price == 0` somewhere in the enumeration; the caller decides whether to
    ///      re-raise based on the combined tracked signal.
    ///      Enumerates `cm.collateralTokens(i)` for `i in [0..n)` (where `n` is bounded by
    ///      `MAX_COLLATERAL_TOKENS_PER_SERVICER`), reads `cm.getCollateralBalance(vault, t)`,
    ///      and prices each via the IPOR oracle. Each `cm.collateralTokens(i)` /
    ///      `cm.getCollateralBalance(vault, t)` pair is wrapped in try/catch so a misreporting
    ///      proxy (OOB on the reported count, or any other read revert) degrades the entire
    ///      locked-collateral leg to 0 without bubbling out of `balanceOf` (mirror of the
    ///      pre-refactor outer-catch behaviour but localised here per the file-level NatSpec).
    /// @param plasmaVault_ Vault address.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @param collateralManager_ Paired CollateralManager.
    /// @param acceptedCollateralCount_ `cm.numOfAcceptedCollateralTokens()`.
    /// @return ok False iff at least one priced token had `price == 0`.
    /// @return valueWad Aggregate WAD-USD value of actively locked collateral.
    /// @return hasAnyPosition True iff at least one accepted token has a positive balance.
    function _lockedCollateralValueWad(
        address plasmaVault_,
        address priceOracleMiddleware_,
        address collateralManager_,
        uint8 acceptedCollateralCount_
    ) internal view returns (bool ok, uint256 valueWad, bool hasAnyPosition) {
        if (acceptedCollateralCount_ == 0) return (true, 0, false);

        ok = true;
        for (uint256 i; i < acceptedCollateralCount_; ++i) {
            (bool tokenOk, address token) = _tryReadCollateralToken(collateralManager_, i);
            // A mid-loop proxy misreport MUST preserve any prior `hasAnyPosition`
            // accumulated in earlier iterations and propagate `ok=false` so the caller's
            // tracked gate fires. Pre-fix the early-return discarded both signals, opening
            // a share-mint window when a CollateralManager proxy mis-reports token i for
            // a vault that had a positive balance at indices 0..i-1.
            if (!tokenOk) return (false, 0, hasAnyPosition);
            (bool balOk, uint256 balance) = _tryReadCollateralBalance(collateralManager_, plasmaVault_, token);
            if (!balOk) return (false, 0, hasAnyPosition);
            if (balance > 0) {
                hasAnyPosition = true;
            }
            (bool priceOk, uint256 legValue) = _priceTokenAmountWadGuarded(priceOracleMiddleware_, token, balance);
            if (!priceOk) ok = false;
            valueWad += legValue;
        }
    }

    /// @notice Compute the borrower debt leg in WAD-USD as a NON-POSITIVE `int256` (or 0).
    /// @dev Tracked-position-gated revert semantics ("Debt-leg failure semantics"):
    ///        - If `getBorrowerRepurchaseObligation` SUCCEEDS:
    ///            face > 0 → PV-discount via `TermFinancePresentValueLib.presentValuePreMaturity`
    ///                       with `adapterHaircut_ = 0` (Convention B — same math as
    ///                       borrower-debt PV), multiply by purchase-token oracle price
    ///                       (reverts on `price == 0`), negate, return.
    ///            face == 0 → no debt, return 0.
    ///        - If `getBorrowerRepurchaseObligation` REVERTS:
    ///            tracked exposure (prior collateral value > 0 OR pending bids tracked)
    ///              → revert with `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer`.
    ///            no tracked exposure → return 0.
    /// @param servicer_ Servicer substrate.
    /// @param plasmaVault_ Vault address.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @param priorCollateralValue_ Aggregate of the collateral legs (passed in to detect
    ///        tracked exposure without re-reading any external state).
    /// @return Signed WAD-USD debt contribution (always ≤ 0).
    function _debtValueWadForServicer(
        address servicer_,
        address plasmaVault_,
        address priceOracleMiddleware_,
        int256 priorCollateralValue_
    ) internal view returns (int256) {
        bool obligationOk;
        uint256 obligationFace;
        try IExtTermRepoServicer(servicer_).getBorrowerRepurchaseObligation(plasmaVault_) returns (uint256 face) {
            obligationOk = true;
            obligationFace = face;
        } catch {
            obligationOk = false;
        }

        if (obligationOk) {
            if (obligationFace == 0) return 0;
            uint256 pvWad = _debtPvWad(servicer_, priceOracleMiddleware_, obligationFace);
            // Saturate the raw uint256 to MAX_VALUE_PER_LEG before negating so the unary
            // minus on int256 stays within range. The outer `balanceOf` loop re-saturates
            // each per-servicer leg too — this is belt-and-braces.
            if (pvWad > MAX_VALUE_PER_LEG_UINT) return -MAX_VALUE_PER_LEG;
            return -pvWad.toInt256();
        }

        // Obligation read reverted. Did we have tracked exposure on this servicer?
        bool trackedBorrower = priorCollateralValue_ > 0 || _hasTrackedExposure(servicer_);
        if (trackedBorrower) {
            revert TermFinanceBalanceFuseDebtReadFailedForTrackedServicer(servicer_);
        }
        return 0;
    }

    /// @notice Convert a face debt value (purchase-token raw units) to WAD-USD present value.
    /// @dev Uses Convention B: PV-discounts the face via the lender-side
    ///      `presentValuePreMaturity` helper with `adapterHaircut_ = 0` (the borrower side
    ///      does NOT take `repoRedemptionHaircut`; that haircut is lender-only). Math is
    ///      identical to lender-side held-token PV (face is face).
    /// @dev Seconds-to-maturity is computed with an explicit zero floor against
    ///      `endOfRepurchaseWindow` so a NAV read after the repurchase window closes does
    ///      NOT underflow (Solidity 0.8.30 reverts on `uint256` underflow). Zero seconds
    ///      collapses the PV formula to `pv = face` exactly — matching the post-maturity
    ///      "no time discount" semantics without a separate code path.
    /// @param servicer_ Servicer substrate.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @param faceDebt_ Face debt in purchase-token raw units (output of
    ///        `IExtTermRepoServicer.getBorrowerRepurchaseObligation`).
    /// @return WAD-USD PV of the debt (always ≥ 0).
    function _debtPvWad(
        address servicer_,
        address priceOracleMiddleware_,
        uint256 faceDebt_
    ) internal view returns (uint256) {
        // `_debtPvWad` is invoked only when `obligationFace > 0`
        // (borrower tracked-by-construction). Any failure of the supporting servicer or
        // adapter reads MUST revert with the dedicated diagnostic — silently zeroing the
        // negative debt leg while collateral / pending bids remain positive opens an
        // ERC4626 share-mint attack window.
        (bool ptOk, address purchaseToken) = _tryReadPurchaseToken(servicer_);
        if (!ptOk || purchaseToken == address(0)) {
            revert TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(servicer_);
        }

        uint256 pvInPurchase = _debtPvInPurchase(servicer_, purchaseToken, faceDebt_);
        if (pvInPurchase == 0) return 0;

        (bool priceOk, uint256 price, uint256 priceDecimals) = _tryGetAssetPrice(priceOracleMiddleware_, purchaseToken);
        // `_debtPvWad` is only called when `obligationFace > 0` — the borrower
        // position is tracked by construction. We normalise oracle failure (revert OR zero
        // price) into the tracked diagnostic so off-chain monitoring sees a uniform error.
        if (!priceOk) revert TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer_);

        uint256 priceCombinedDecimals = uint256(IERC20Metadata(purchaseToken).decimals()) + priceDecimals;
        return IporMath.convertToWad(pvInPurchase * price, priceCombinedDecimals);
    }

    /// @notice Helper extracted from `_debtPvWad` to keep stack usage under the 16-slot
    ///         limit after the try/catch additions.
    /// @dev Computes the borrower-side PV in purchase-token raw units. Reverts (via the
    ///      tracked-borrower diagnostic) on any supporting read failure — see `_debtPvWad`
    ///      for the rationale. Convention B: `adapterHaircut = 0`.
    /// @param servicer_ Servicer substrate.
    /// @param purchaseToken_ Purchase token already resolved by the caller.
    /// @param faceDebt_ Face debt in purchase-token raw units.
    /// @return PV in purchase-token raw units.
    function _debtPvInPurchase(
        address servicer_,
        address purchaseToken_,
        uint256 faceDebt_
    ) internal view returns (uint256) {
        // Cap purchase-token decimals to prevent `10 ** dec` overflow when an
        // adversarial / mis-upgraded purchaseToken reports an out-of-range value. The
        // tracked-borrower diagnostic is the right surface for this — silently zeroing
        // the debt leg would open the same share-mint window the rest of `_debtPvWad`
        // already guards against.
        uint8 purchaseDec = IERC20Metadata(purchaseToken_).decimals();
        if (purchaseDec > MAX_TOKEN_DECIMALS) {
            revert TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(servicer_);
        }
        uint256 purchasePrec = 10 ** uint256(purchaseDec);

        (bool endOk, uint256 endTimestamp) = _tryReadEndOfRepurchaseWindow(servicer_);
        if (!endOk) {
            revert TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(servicer_);
        }
        // Zero-floor: explicit branch prevents Solidity 0.8.30 unsigned underflow once
        // `block.timestamp >= endTimestamp` (post-repurchase-window NAV reads must still
        // succeed; the zero-seconds path collapses to `pv = face`).
        uint256 secondsToMaturity = block.timestamp >= endTimestamp ? 0 : endTimestamp - block.timestamp;

        // Discount rate from Adapter-B keyed by the servicer's TermRepoToken. Both reads
        // are wrapped in try/catch; on failure we re-raise with the tracked-borrower
        // diagnostic. Pre-fix behaviour silently degraded debt to 0 — that
        // path is intentionally removed.
        (bool rtOk, address repoToken) = _tryReadRepoToken(servicer_);
        if (!rtOk || repoToken == address(0)) {
            revert TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(servicer_);
        }
        (bool rateOk, uint256 discountRate) = _tryGetDiscountRate(repoToken);
        if (!rateOk) {
            revert TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(servicer_);
        }

        return
            TermFinancePresentValueLib.presentValuePreMaturity(
                faceDebt_,
                purchasePrec,
                secondsToMaturity,
                discountRate,
                0 // Convention B: borrower debt does NOT take repoRedemptionHaircut.
            );
    }

    /// @notice Cheap predicate: does the vault have any tracked Term Finance exposure on this
    ///         servicer (pending bids OR pending offers tracked in vault-owned storage)?
    /// @dev Used by `_collateralValueWadWithGate` (oracle-zero gate) and
    ///      `_debtValueWadForServicer` (debt-read-failed gate). Both rely on this
    ///      signal to distinguish "tracked-but-broken" (re-raise) from "untracked"
    ///      (silently degrade to 0). The collateral and held-repo legs already carry their
    ///      own `hasAnyPosition` flags from on-chain reads; this helper adds the storage
    ///      signals which are AUTHORITATIVE even when the matching Term proxy is broken
    ///      (locker reverts on `lockedOffer` / `lockedBid`). Pending offers are stored on
    ///      `enter` by `TermFinanceOfferFuse`; pending bids are stored on `enter` by
    ///      `TermFinanceBidFuse`. Both clean up on cleared-on-chain / cancelled paths.
    /// @param servicer_ Servicer substrate.
    /// @return True iff the vault has at least one pending bid OR pending offer tracked in
    ///         storage for this servicer.
    function _hasTrackedExposure(address servicer_) internal view returns (bool) {
        return
            TermFinancePendingBidsStorageLib.length(servicer_) > 0 ||
            TermFinancePendingOffersStorageLib.length(servicer_) > 0;
    }

    /// @notice Decision for a collateral-manager probe failure: revert if the vault
    ///         has detectable exposure to `servicer_`, otherwise degrade the leg to 0.
    /// @dev Used by `_signedValueForServicerInternal` when `termRepoCollateralManager()` /
    ///      `numOfAcceptedCollateralTokens()` revert or the accepted-count is out of range — a
    ///      broken / paused / upgraded CM or servicer proxy threat model. Freezing
    ///      a servicer with exposure matches the tracked-gate philosophy; degrading an
    ///      unused (granted-but-empty) servicer keeps a misconfigured proxy from bricking NAV.
    /// @param servicer_ Servicer whose CM probe failed.
    /// @param plasmaVault_ Vault address (held-balance / obligation reads target it).
    /// @return Always 0 when it returns; reverts when exposure is detected.
    function _gateOnCollateralManagerProbeFailure(
        address servicer_,
        address plasmaVault_
    ) internal view returns (int256) {
        if (_servicerHasExposure(servicer_, plasmaVault_)) {
            revert TermFinanceBalanceFuseCollateralManagerReadFailedForTrackedServicer(servicer_);
        }
        return 0;
    }

    /// @notice Cheap, CM-independent detection of whether the vault holds any Term Finance
    ///         position on `servicer_`. Used only by the collateral-manager-probe gate.
    /// @dev Three signals, none of which require the (failed) collateral manager:
    ///        1. pending offers / bids in vault-owned storage (`_hasTrackedExposure`);
    ///        2. a non-zero held TermRepoToken balance — or an UNREADABLE balance, which is
    ///           treated as exposure (we cannot prove the held leg is zero, mirroring
    ///           `_heldTermRepoTokenPv`'s own `!balOk → tracked` behaviour);
    ///        3. a positive outstanding borrower repurchase obligation (debt leg).
    ///      A read that simply succeeds with zero is NOT exposure, so an unused servicer with a
    ///      merely-broken collateral manager still degrades to 0.
    /// @param servicer_ Servicer substrate.
    /// @param plasmaVault_ Vault address.
    /// @return True iff the vault appears to hold a position on this servicer.
    function _servicerHasExposure(address servicer_, address plasmaVault_) internal view returns (bool) {
        if (_hasTrackedExposure(servicer_)) return true;

        (bool rtOk, address repoToken) = _tryReadRepoToken(servicer_);
        if (rtOk && repoToken != address(0)) {
            (bool balOk, uint256 repoBal) = _tryReadRepoTokenBalance(repoToken, plasmaVault_);
            if (!balOk || repoBal > 0) return true;
        }

        try IExtTermRepoServicer(servicer_).getBorrowerRepurchaseObligation(plasmaVault_) returns (uint256 face) {
            if (face > 0) return true;
        } catch {
            // Obligation unreadable: do NOT treat as exposure here. If the vault truly had a
            // tracked debt, signal (1) or (2) would have caught it, or the debt leg's own
            // gate fires on the normal path; freezing every granted-but-broken servicer on an
            // unreadable obligation alone would over-restrict.
        }

        return false;
    }

    /// @notice Cached, per-call snapshot of every Term-Finance datum needed to value one
    ///         servicer's held TermRepoToken position. Each field is read with a try/catch
    ///         guard via `_tryReadServicerTopology`.
    /// @param repoToken `TermRepoToken` proxy paired with the servicer.
    /// @param purchaseToken Underlying borrow/lend ERC20 of the Term Repo.
    /// @param repoTokenDec Decimals of `repoToken`.
    /// @param purchaseDec Decimals of `purchaseToken`.
    /// @param redValue Redemption value of one `repoToken` unit at maturity (WAD mantissa).
    /// @param tred Servicer redemption timestamp (unix seconds).
    struct ServicerTopology {
        address repoToken;
        address purchaseToken;
        uint8 repoTokenDec;
        uint8 purchaseDec;
        uint256 redValue;
        uint256 tred;
    }

    /// @notice Discount face value to present value, branching on maturity.
    /// @dev Pre-maturity uses `TermFinancePresentValueLib.presentValuePreMaturity` with the
    ///      adapter discount rate and adapter conservative haircut. Post-maturity uses
    ///      `presentValuePostMaturity` with the servicer's realised default haircut.
    /// @param servicer_ Servicer (post-maturity branch reads its shortfall haircut).
    /// @param repoToken_ TermRepoToken to query the adapter for (pre-maturity branch).
    /// @param tred_ Servicer's redemption timestamp.
    /// @param purchasePrec_ `10 ** purchaseToken.decimals()`.
    /// @param faceInPurchase_ Face value already converted to purchase-token units.
    /// @return PV in purchase-token raw units; 0 on any try/catch failure.
    function _pvForFace(
        address servicer_,
        address repoToken_,
        uint256 tred_,
        uint256 purchasePrec_,
        uint256 faceInPurchase_
    ) internal view returns (uint256) {
        if (block.timestamp >= tred_) {
            (bool ok, uint256 hcut) = _tryReadShortfallHaircut(servicer_);
            if (!ok) return 0;
            return TermFinancePresentValueLib.presentValuePostMaturity(faceInPurchase_, hcut);
        }

        (bool rateOk, uint256 rate) = _tryGetDiscountRate(repoToken_);
        if (!rateOk) return 0;

        (bool haircutOk, uint256 adapterHcut) = _tryGetRepoRedemptionHaircut(repoToken_);
        if (!haircutOk) adapterHcut = 0;

        // The pre-maturity lender PV applies the haircut as a RATE amplifier
        // (`effRate = rate * (1 + haircut)`), a deliberate deviation from Yearn's face-cut that
        // OVER-reports NAV (~5pp) once `repoRedemptionHaircut` is non-zero (it is 0 on mainnet
        // today). Freeze share math rather than silently over-report a tracked held position
        // until the convention is revisited. A reverting adapter haircut read is treated as 0
        // above (existing Option-B fallback), so this only fires on a genuine non-zero value.
        if (adapterHcut > 0) revert TermFinanceBalanceFuseNonZeroRepoRedemptionHaircut(servicer_);

        return
            TermFinancePresentValueLib.presentValuePreMaturity(
                faceInPurchase_,
                purchasePrec_,
                tred_ - block.timestamp,
                rate,
                adapterHcut
            );
    }

    /// @notice Read every field needed for held-RepoToken PV from a single servicer, with
    ///         each call wrapped in try/catch so a malicious/upgraded proxy degrades to a
    ///         zero contribution at the held-token leg.
    /// @param servicer_ Substrate key.
    /// @return ok True if every field was read successfully.
    /// @return top Filled topology snapshot (only valid when `ok == true`).
    function _tryReadServicerTopology(address servicer_) internal view returns (bool ok, ServicerTopology memory top) {
        try IExtTermRepoServicer(servicer_).termRepoToken() returns (address rt) {
            top.repoToken = rt;
        } catch {
            return (false, top);
        }
        if (top.repoToken == address(0)) return (false, top);

        try IExtTermRepoServicer(servicer_).purchaseToken() returns (address pt) {
            top.purchaseToken = pt;
        } catch {
            return (false, top);
        }
        if (top.purchaseToken == address(0)) return (false, top);

        try IExtTermRepoToken(top.repoToken).decimals() returns (uint8 d) {
            top.repoTokenDec = d;
        } catch {
            return (false, top);
        }
        // Adversarial decimals (>= MAX_TOKEN_DECIMALS) overflow the `10 ** dec`
        // precision factor used downstream in PV math and would permanently brick the
        // held-token leg. Degrade via the topology-fail path so the tracked gate fires for tracked
        // exposure (mirrors the same path as any other proxy-misreport).
        if (top.repoTokenDec > MAX_TOKEN_DECIMALS) return (false, top);

        try IERC20Metadata(top.purchaseToken).decimals() returns (uint8 d) {
            top.purchaseDec = d;
        } catch {
            return (false, top);
        }
        if (top.purchaseDec > MAX_TOKEN_DECIMALS) return (false, top);

        try IExtTermRepoToken(top.repoToken).redemptionValue() returns (uint256 rv) {
            top.redValue = rv;
        } catch {
            return (false, top);
        }
        // An out-of-range `redemptionValue` (> MAX_REDEMPTION_VALUE) makes
        // `TermFinancePresentValueLib.faceValue` return 0 as an overflow guard, which would
        // route a TRACKED held position (repoBal > 0) through the silent `pvHeld == 0 →
        // (true, 0)` branch and under-report NAV (share-mint window). Treat an adversarial /
        // corrupted redemptionValue as a topology failure (mirrors the MAX_TOKEN_DECIMALS
        // handling above) so the held leg returns `ok = false` and the tracked gate
        // re-raises instead of silently zeroing.
        if (top.redValue > TermFinancePresentValueLib.MAX_REDEMPTION_VALUE) return (false, top);

        try IExtTermRepoServicer(servicer_).redemptionTimestamp() returns (uint256 t) {
            top.tred = t;
        } catch {
            return (false, top);
        }

        ok = true;
    }

    /// @notice Probe `IExtTermRepoServicer(servicer).purchaseToken()` with try/catch.
    /// @dev Callers (`_pendingOffersValueWad`, `_debtPvWad`) used
    ///      to invoke this read directly, which let a paused / upgraded servicer revert
    ///      bubble out of `balanceOf` for the entire vault. The wrapper lets each caller
    ///      decide its own degrade-vs-revert policy (tracked gate for lender legs,
    ///      `TermFinanceBalanceFuseDebtRateFailedForTrackedServicer` for the tracked
    ///      borrower leg).
    /// @param servicer_ Servicer substrate.
    /// @return ok True if the call succeeded.
    /// @return purchaseToken Purchase token address (zero on failure).
    function _tryReadPurchaseToken(address servicer_) internal view returns (bool ok, address purchaseToken) {
        try IExtTermRepoServicer(servicer_).purchaseToken() returns (address pt) {
            return (true, pt);
        } catch {
            return (false, address(0));
        }
    }

    /// @notice Probe `IExtTermRepoServicer(servicer).termRepoToken()` with try/catch.
    /// @dev See `_tryReadPurchaseToken` rationale.
    /// @param servicer_ Servicer substrate.
    /// @return ok True if the call succeeded.
    /// @return repoToken Repo token address (zero on failure).
    function _tryReadRepoToken(address servicer_) internal view returns (bool ok, address repoToken) {
        try IExtTermRepoServicer(servicer_).termRepoToken() returns (address rt) {
            return (true, rt);
        } catch {
            return (false, address(0));
        }
    }

    /// @notice Probe `IExtTermRepoToken(repoToken).balanceOf(holder)` with try/catch.
    /// @dev Wraps the held-RepoToken balance read so a paused / upgraded
    ///      `TermRepoToken` proxy degrades the held leg to the tracked gate instead of
    ///      bubbling a raw revert out of `balanceOf` for the whole vault.
    /// @param repoToken_ Repo token proxy.
    /// @param holder_ Address to query the balance for (the PlasmaVault).
    /// @return ok True if the call succeeded.
    /// @return balance Held balance (0 on failure).
    function _tryReadRepoTokenBalance(
        address repoToken_,
        address holder_
    ) internal view returns (bool ok, uint256 balance) {
        try IExtTermRepoToken(repoToken_).balanceOf(holder_) returns (uint256 b) {
            return (true, b);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Probe `IExtTermRepoServicer(servicer).endOfRepurchaseWindow()` with try/catch.
    /// @dev See `_tryReadPurchaseToken` rationale.
    /// @param servicer_ Servicer substrate.
    /// @return ok True if the call succeeded.
    /// @return endTimestamp End-of-repurchase-window unix timestamp (0 on failure).
    function _tryReadEndOfRepurchaseWindow(
        address servicer_
    ) internal view returns (bool ok, uint256 endTimestamp) {
        try IExtTermRepoServicer(servicer_).endOfRepurchaseWindow() returns (uint256 ts) {
            return (true, ts);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Probe `IExtTermRepoServicer(servicer).termRepoCollateralManager()` with try/catch.
    /// @param servicer_ Servicer substrate.
    /// @return ok True if the call succeeded.
    /// @return collateralManager Paired collateral manager address (zero on failure or when the
    ///         servicer legitimately reports no manager).
    function _tryReadCollateralManager(
        address servicer_
    ) internal view returns (bool ok, address collateralManager) {
        try IExtTermRepoServicer(servicer_).termRepoCollateralManager() returns (address cm) {
            return (true, cm);
        } catch {
            return (false, address(0));
        }
    }

    /// @notice Probe `IExtTermRepoCollateralManager(cm).numOfAcceptedCollateralTokens()` with try/catch.
    /// @param collateralManager_ Collateral manager to query.
    /// @return ok True if the call succeeded.
    /// @return count Reported accepted-collateral-token count (0 on failure).
    function _tryReadAcceptedCollateralCount(
        address collateralManager_
    ) internal view returns (bool ok, uint8 count) {
        try IExtTermRepoCollateralManager(collateralManager_).numOfAcceptedCollateralTokens() returns (uint8 n) {
            return (true, n);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Probe `IExtTermRepoCollateralManager(cm).collateralTokens(index)` with try/catch.
    /// @dev OOB / proxy breakage at index `i` degrades the entire locked-collateral leg via the
    ///      caller (see `_lockedCollateralValueWad`).
    /// @param collateralManager_ Collateral manager to query.
    /// @param index_ Token index in the accepted-collateral list.
    /// @return ok True if the call succeeded.
    /// @return token Collateral token address (zero on failure).
    function _tryReadCollateralToken(
        address collateralManager_,
        uint256 index_
    ) internal view returns (bool ok, address token) {
        try IExtTermRepoCollateralManager(collateralManager_).collateralTokens(index_) returns (address t) {
            return (true, t);
        } catch {
            return (false, address(0));
        }
    }

    /// @notice Probe `IExtTermRepoCollateralManager(cm).getCollateralBalance(borrower, token)` with try/catch.
    /// @param collateralManager_ Collateral manager to query.
    /// @param borrower_ Borrower (== vault under delegatecall).
    /// @param token_ Collateral token.
    /// @return ok True if the call succeeded.
    /// @return balance Locked collateral balance (0 on failure).
    function _tryReadCollateralBalance(
        address collateralManager_,
        address borrower_,
        address token_
    ) internal view returns (bool ok, uint256 balance) {
        try IExtTermRepoCollateralManager(collateralManager_).getCollateralBalance(borrower_, token_) returns (
            uint256 b
        ) {
            return (true, b);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Probe `offerLocker.lockedOffer(id)` with try/catch; returns on-chain amount or 0.
    /// @param offerLocker_ TermAuctionOfferLocker proxy address.
    /// @param offerId_ Pending offer id.
    /// @return ok True if the call succeeded (does not imply the offer is still locked).
    /// @return amount On-chain `lockedOffer.amount` (0 when cleared / refunded / cancelled).
    function _tryReadLockedOfferAmount(
        address offerLocker_,
        bytes32 offerId_
    ) internal view returns (bool ok, uint256 amount) {
        try IExtTermAuctionOfferLocker(offerLocker_).lockedOffer(offerId_) returns (
            IExtTermAuctionOfferLocker.TermAuctionOffer memory offer
        ) {
            return (true, offer.amount);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Probe `bidLocker.lockedBid(id)` with try/catch; returns canonical liveness signal.
    /// @dev Stale-bid predicate: live iff `bidder != address(0) && amount != 0`. The
    ///      Term BidLocker returns a zero-valued struct (NOT a revert) for unknown / cleared
    ///      ids — try/catch is defensive against future ABI changes.
    ///
    ///      Refuted double-count hypothesis. One might hypothesise a window in which the
    ///      `TermAuction` orchestrator has flipped
    ///      `auctionCompleted = true` but the `TermAuctionBidLocker` still has live bid
    ///      storage, yielding a double-count between this predicate (which would return
    ///      `true`) and `_lockedCollateralValueWad` (which already prices the same
    ///      collateral via the `TermRepoCollateralManager`). The window does not exist:
    ///
    ///        1. `TermAuctionBidLocker._processBidForAuction` (vendored v0.9.0 source,
    ///           lines 959-962) does `delete bids[id]; bidCount -= 1;` atomically. ALL
    ///           four bid-clearing paths inside `_getAllBids` route through it:
    ///             - expired-rollover     (`TermAuctionBidLocker.sol:616`)
    ///             - revealed-shortfall   (`TermAuctionBidLocker.sol:736`)
    ///             - revealed-assigned    (`TermAuctionBidLocker.sol:941`)
    ///             - unrevealed           (`TermAuctionBidLocker.sol:658`)
    ///        2. At the tail of `_getAllBids` the locker asserts
    ///           `bidCount == 0` (`TermAuctionBidLocker.sol:668`) — the entire `bids`
    ///           mapping is empty after clearing.
    ///        3. `TermAuction.completeAuction` flips `auctionCompleted = true`
    ///           (`TermAuction.sol:213`) and IMMEDIATELY calls
    ///           `termAuctionBidLocker.getAllBids(...)` (`TermAuction.sol:231`) inside
    ///           the same external transaction. The locker wipe is therefore atomic
    ///           with the orchestrator flag flip; no externally observable window
    ///           exists where `lockedBid(id)` is non-zero AND
    ///           `termAuction.auctionCompleted()` is `true`.
    ///
    ///      Consequently `bid.bidder != address(0) && bid.amount != 0` is a sound
    ///      stale-bid gate without consulting the orchestrator. The vault-side
    ///      `TermFinancePendingBidsStorageLib` entry is allowed to linger until
    ///      `TermFinanceCleanupFuse._pruneStoredBids` compacts it; the predicate
    ///      gates the valuation correctly in the meantime, so no double-count occurs.
    ///
    ///      Regression coverage:
    ///        - Fork:  `TermFinanceBorrowerFork.testForkLockedBidReturnsAllZeroAtCompletedAuction`
    ///                 — pins the post-clearing zero-struct invariant against live
    ///                 Ethereum mainnet at block 25097999.
    ///        - Unit:  see `TermFinanceBalanceFuseTest` / `TermFinanceCleanupFuseTest`
    ///                 for the corresponding mocked transitions.
    /// @param bidLocker_ TermAuctionBidLocker proxy address.
    /// @param bidId_ Pending bid id.
    /// @return ok True if the staticcall succeeded.
    /// @return isLive True iff the bid is still live per the canonical predicate.
    function _tryReadLockedBidIsLive(
        address bidLocker_,
        bytes32 bidId_
    ) internal view returns (bool ok, bool isLive) {
        try IExtTermAuctionBidLocker(bidLocker_).lockedBid(bidId_) returns (
            IExtTermAuctionBidLocker.TermAuctionBid memory bid
        ) {
            return (true, bid.bidder != address(0) && bid.amount != 0);
        } catch {
            return (false, false);
        }
    }

    /// @notice Probe the adapter discount rate with try/catch; falls back to (false, 0) on revert.
    /// @param repoToken_ Term Repo token to query.
    /// @return ok True if the call succeeded.
    /// @return rate Discount rate in 18-dec mantissa.
    function _tryGetDiscountRate(address repoToken_) internal view returns (bool ok, uint256 rate) {
        try IExtTermDiscountRateAdapter(DISCOUNT_RATE_ADAPTER).getDiscountRate(repoToken_) returns (uint256 r) {
            return (true, r);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Probe the adapter conservative haircut with try/catch.
    /// @param repoToken_ Term Repo token to query.
    /// @return ok True if the call succeeded.
    /// @return hcut Haircut in 18-dec mantissa.
    function _tryGetRepoRedemptionHaircut(address repoToken_) internal view returns (bool ok, uint256 hcut) {
        try IExtTermDiscountRateAdapter(DISCOUNT_RATE_ADAPTER).repoRedemptionHaircut(repoToken_) returns (
            uint256 h
        ) {
            return (true, h);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Probe the servicer's realised default haircut with try/catch.
    /// @param servicer_ Substrate key.
    /// @return ok True if the call succeeded.
    /// @return hcut Haircut in 18-dec mantissa.
    function _tryReadShortfallHaircut(address servicer_) internal view returns (bool ok, uint256 hcut) {
        try IExtTermRepoServicer(servicer_).shortfallHaircutMantissa() returns (uint256 h) {
            return (true, h);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Probe `IPriceOracleMiddleware(mw).getAssetPrice(asset)` with try/catch +
    ///         price-zero check, normalised for the tracked-vs-untracked gate.
    /// @dev Returns `ok == false` on EITHER (a) the middleware reverted (production
    ///      `PriceOracleMiddleware` raises `UnsupportedAsset` / `UnexpectedPriceResult` on
    ///      missing or non-positive prices), OR (b) the middleware returned `price == 0`
    ///      (mock / future implementations). The unified signal lets callers gate untracked
    ///      legs uniformly regardless of how the oracle reports failure. On success the
    ///      caller receives both the price and the price decimals.
    /// @param priceOracleMiddleware_ Oracle middleware address.
    /// @param asset_ Token to price.
    /// @return ok False iff the price could not be read or was zero.
    /// @return price Price mantissa (0 on failure).
    /// @return priceDecimals Oracle decimals (0 on failure).
    function _tryGetAssetPrice(
        address priceOracleMiddleware_,
        address asset_
    ) internal view returns (bool ok, uint256 price, uint256 priceDecimals) {
        try IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(asset_) returns (uint256 p, uint256 pDec) {
            if (p == 0) return (false, 0, 0);
            return (true, p, pDec);
        } catch {
            return (false, 0, 0);
        }
    }

}
