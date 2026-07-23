// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TermFinanceBalanceFuse} from "contracts/fuses/term_finance/TermFinanceBalanceFuse.sol";
import {IExtTermAuctionBidLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionBidLocker.sol";
import {IExtTermAuctionOfferLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionOfferLocker.sol";

import {TermFinanceBalanceFuseHarness} from "./mocks/TermFinanceBalanceFuseHarness.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockPriceOracleMiddlewareForTermFinance} from "./mocks/MockPriceOracleMiddlewareForTermFinance.sol";
import {MockTermAuctionBidLocker} from "./mocks/MockTermAuctionBidLocker.sol";
import {MockTermAuctionOfferLocker} from "./mocks/MockTermAuctionOfferLocker.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermDiscountRateAdapter} from "./mocks/MockTermDiscountRateAdapter.sol";
import {MockTermRepoCollateralManager} from "./mocks/MockTermRepoCollateralManager.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";
import {MockTermRepoToken} from "./mocks/MockTermRepoToken.sol";

/// @title TermFinanceBalanceFuseTest
/// @notice Unit tests for TermFinanceBalanceFuse — including the NAV-continuity invariant.
contract TermFinanceBalanceFuseTest is Test {
    uint256 internal constant MARKET_ID = 52;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_PREC = 1e6;
    uint256 internal constant SECS_28D = 28 * 86_400;
    uint256 internal constant SECS_7D = 7 * 86_400;

    TermFinanceBalanceFuseHarness harness;
    MockTermController controller;
    MockTermDiscountRateAdapter adapter;
    MockPriceOracleMiddlewareForTermFinance oracle;

    function setUp() public {
        controller = new MockTermController();
        adapter = new MockTermDiscountRateAdapter();
        oracle = new MockPriceOracleMiddlewareForTermFinance();

        harness = new TermFinanceBalanceFuseHarness(MARKET_ID, address(controller), address(adapter));
        harness.setPriceOracleMiddleware(address(oracle));
    }

    // ============ helpers ============

    struct Term {
        MockTermRepoServicer servicer;
        MockTermRepoToken repoToken;
        MockTermAuctionOfferLocker offerLocker;
        MockTermRepoCollateralManager collateralManager;
        MockERC20Decimals purchaseToken;
        address termRepoLockerAddr;
    }

    /// @dev Build a complete USDC-purchase Term Repo wired up with mocks.
    /// @dev The balance fuse reads `IExtTermRepoServicer.termRepoCollateralManager()` as the
    ///      FIRST foreign call inside `_signedValueForServicerInternal` (cap check via
    ///      `numOfAcceptedCollateralTokens()`). Without a wired-up collateral manager, the
    ///      `_tryReadCollateralManager` probe fails and the leg degrades to 0 — masking every
    ///      lender-side assertion. We wire a CM with 0 accepted tokens by default so the
    ///      lender legs run unobstructed; tests that need accepted tokens override via
    ///      `t.collateralManager.setAcceptedTokens(...)`.
    /// @param tred_ Redemption timestamp to set on servicer.
    function _deployUsdcTerm(uint256 tred_) internal returns (Term memory t) {
        t.purchaseToken = new MockERC20Decimals("USD Coin", "USDC", 6);
        t.repoToken = new MockTermRepoToken("TermRepoToken", "TRT", 6);
        t.offerLocker = new MockTermAuctionOfferLocker();
        t.collateralManager = new MockTermRepoCollateralManager();
        t.servicer = new MockTermRepoServicer();
        t.termRepoLockerAddr = makeAddr("termRepoLocker");

        t.servicer.setTermRepoToken(address(t.repoToken));
        t.servicer.setTermRepoLocker(t.termRepoLockerAddr);
        t.servicer.setTermRepoCollateralManager(address(t.collateralManager));
        t.servicer.setPurchaseToken(address(t.purchaseToken));
        t.servicer.setRedemptionTimestamp(tred_);
        t.servicer.setMaturityTimestamp(tred_);
        // Default end-of-repurchase-window matches the redemption timestamp; debt-PV branches
        // gate on `block.timestamp >= endTimestamp` (zero-floor seconds-to-maturity) so this
        // mirrors a typical Term Repo cycle.
        t.servicer.setEndOfRepurchaseWindow(tred_);
        t.servicer.setShortfallHaircutMantissa(0);

        t.offerLocker.setTermRepoServicer(address(t.servicer));
        t.offerLocker.setTermRepoLocker(t.termRepoLockerAddr);
        t.offerLocker.setPurchaseToken(address(t.purchaseToken));

        t.collateralManager.setTermRepoLocker(t.termRepoLockerAddr);
        // Default: no accepted collateral tokens. Tests that exercise the locked-collateral
        // leg override via `t.collateralManager.setAcceptedTokens(tokens)`.
        t.collateralManager.setAcceptedTokens(new address[](0));

        controller.setIsTermDeployed(address(t.servicer), true);
        oracle.setAssetPrice(address(t.purchaseToken), 1e8, 8); // 1 USDC == $1, 8-dec price
    }

    function _grantSubstrate(address servicer_) internal {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(servicer_);
        harness.setMarketSubstrates(MARKET_ID, subs);
    }

    function _convertUsdcToWad(uint256 usdcAmount_) internal pure returns (uint256) {
        // price 1e8 with 8 decimals, asset 6 decimals → combined decimals = 6 + 8 = 14.
        // wad = usdcAmount * price / 10^(combined - 18) ... or use convertToWad formula:
        // value = usdcAmount * price = usdcAmount * 1e8; convertToWad(value, 14) = value * 1e(18-14) = value * 1e4
        return usdcAmount_ * 1e8 * 1e4;
    }

    // ============ constructor ============

    function test_constructor_setsImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID);
        assertEq(harness.TERM_CONTROLLER(), address(controller));
        assertEq(harness.DISCOUNT_RATE_ADAPTER(), address(adapter));
        assertEq(harness.VERSION(), address(harness));
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceBalanceFuseHarness(0, address(controller), address(adapter));
    }

    function test_constructor_revertsOnZeroController() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceBalanceFuseHarness(MARKET_ID, address(0), address(adapter));
    }

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceBalanceFuseHarness(MARKET_ID, address(controller), address(0));
    }

    // ============ balanceOf — empty paths ============

    function test_balanceOf_returnsZero_whenNoSubstrates() public {
        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_revertsWhenPriceOracleZero() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));
        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1e18);

        // Wipe oracle.
        harness.setPriceOracleMiddleware(address(0));

        vm.expectRevert(Errors.WrongAddress.selector);
        harness.balanceOf();
    }

    function test_balanceOf_zeroAddressSubstrate_skips() public {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = bytes32(0);
        harness.setMarketSubstrates(MARKET_ID, subs);

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_substrateWithNoBalanceAndNoPending_returnsZero() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        assertEq(harness.balanceOf(), 0);
    }

    // ============ balanceOf — held RepoToken (pre-maturity) ============

    function test_balanceOf_heldRepoToken_preMaturity_returnsPVAtAdapterRate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));

        // Set adapter rate 5% APR (5e16 mantissa).
        adapter.setRate(address(t.repoToken), 5e16);

        // Vault holds 1M TermRepoToken with redemptionValue 1.003889e6 (face=1.003889M for 28d @ 5%).
        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        uint256 nav = harness.balanceOf();
        // PV at clearing ≈ 1_000_000 USDC → WAD-USD via $1 price.
        uint256 expected = _convertUsdcToWad(1_000_000);
        // Allow small rounding tolerance.
        assertApproxEqAbs(nav, expected, 100 * 1e4, "PV pre-maturity ~ principal");
    }

    function test_balanceOf_heldRepoToken_postMaturity_returnsFaceMinusHaircut() public {
        uint256 tred = block.timestamp;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));

        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        // 3% shortfall.
        t.servicer.setShortfallHaircutMantissa(3e16);

        // Warp so block.timestamp >= tred.
        vm.warp(tred + 1);

        uint256 nav = harness.balanceOf();
        // face = 1_003_889 USDC, post-haircut = face * 0.97 ≈ 973_772.
        uint256 expectedUsdc = (1_003_889 * (WAD - 3e16)) / WAD;
        uint256 expectedWad = _convertUsdcToWad(expectedUsdc);
        assertApproxEqAbs(nav, expectedWad, 100 * 1e4);
    }

    function test_balanceOf_adapterReverts_skipsHeldContribution() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        adapter.setRate(address(t.repoToken), 5e16);
        adapter.setGetDiscountRateReverts(true);

        uint256 nav = harness.balanceOf();
        assertEq(nav, 0, "adapter revert -> 0 held PV (Option B fallback)");
    }

    function test_balanceOf_adapterHaircutReverts_treatsAsZero() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        adapter.setRate(address(t.repoToken), 5e16);
        adapter.setHaircutReverts(true);

        // Should NOT revert; haircut treated as 0.
        uint256 nav = harness.balanceOf();
        assertGt(nav, 0);
    }

    // ============ regressions: collateral-manager probe / redemption-value / haircut ============

    /// @notice A collateral-manager probe failure on a servicer the vault HAS a
    ///         held position on must FREEZE share math (revert), not silently zero the whole
    ///         servicer leg (which would drop the CM-independent held-repo PV and bypass the
    ///         tracked-servicer gate).
    function test_balanceOf_H2_cmProbeReverts_trackedHeld_reverts() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);
        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        // Collateral-manager probe reverts (paused / upgraded / broken proxy).
        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("termRepoCollateralManager()"),
            bytes("CM down")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseCollateralManagerReadFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice The same probe failure on an UNUSED (granted-but-empty) servicer
    ///         still degrades to 0 — a misconfigured proxy must not brick NAV.
    function test_balanceOf_H2_cmProbeReverts_untracked_returnsZero() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));
        // No held balance, no pending storage, no debt.

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("termRepoCollateralManager()"),
            bytes("CM down")
        );

        assertEq(harness.balanceOf(), 0, "untracked + CM probe failure -> 0");
    }

    /// @notice Accepted-collateral count out of range on a tracked servicer also
    ///         freezes (mirrors the probe-revert path).
    function test_balanceOf_H2_acceptedCountOverCap_trackedHeld_reverts() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);
        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        // numOfAcceptedCollateralTokens() returns a value above MAX_COLLATERAL_TOKENS_PER_SERVICER (8).
        vm.mockCall(
            address(t.collateralManager),
            abi.encodeWithSignature("numOfAcceptedCollateralTokens()"),
            abi.encode(uint8(9))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseCollateralManagerReadFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice An out-of-range `redemptionValue` (> MAX_REDEMPTION_VALUE) on a held
    ///         position must re-raise the tracked gate, not silently zero the leg.
    function test_balanceOf_M1_redemptionValueOverMax_trackedHeld_reverts() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);
        t.repoToken.mint(address(harness), 1_000_000);
        // 1e22 is MAX_REDEMPTION_VALUE; anything above is treated as a corrupted topology read.
        t.repoToken.setRedemptionValue(1e22 + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice A non-zero adapter `repoRedemptionHaircut` on a held pre-maturity
    ///         position freezes share math (the rate-amplification convention over-reports NAV).
    function test_balanceOf_L5_nonZeroRepoRedemptionHaircut_reverts() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);
        adapter.setHaircut(address(t.repoToken), 5e16); // 5% — non-zero
        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseNonZeroRepoRedemptionHaircut.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    // ============ balanceOf — topology-read reverts (try/catch branches) ============

    function test_balanceOf_servicerTermRepoTokenReverts_skipsSubstrate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("termRepoToken()"),
            bytes("revert")
        );

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_servicerTermRepoTokenZero_skipsSubstrate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCall(
            address(t.servicer),
            abi.encodeWithSignature("termRepoToken()"),
            abi.encode(address(0))
        );

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_servicerPurchaseTokenReverts_skipsSubstrate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("purchaseToken()"),
            bytes("revert")
        );

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_servicerPurchaseTokenZero_skipsSubstrate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCall(
            address(t.servicer),
            abi.encodeWithSignature("purchaseToken()"),
            abi.encode(address(0))
        );

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_repoTokenDecimalsReverts_skipsSubstrate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCallRevert(
            address(t.repoToken),
            abi.encodeWithSignature("decimals()"),
            bytes("revert")
        );

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_purchaseTokenDecimalsReverts_skipsSubstrate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCallRevert(
            address(t.purchaseToken),
            abi.encodeWithSignature("decimals()"),
            bytes("revert")
        );

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_redemptionValueReverts_skipsSubstrate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCallRevert(
            address(t.repoToken),
            abi.encodeWithSignature("redemptionValue()"),
            bytes("revert")
        );

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_redemptionTimestampReverts_skipsSubstrate() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("redemptionTimestamp()"),
            bytes("revert")
        );

        assertEq(harness.balanceOf(), 0);
    }

    function test_balanceOf_shortfallHaircutReverts_postMaturity_pvIsZero() public {
        uint256 tred = block.timestamp;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));

        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        vm.warp(tred + 1);

        // Override shortfallHaircut to revert.
        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("shortfallHaircutMantissa()"),
            bytes("revert")
        );

        assertEq(harness.balanceOf(), 0, "shortfallHaircut revert -> 0 PV");
    }

    /// @notice The held-RepoToken leg signals tracked exposure (the
    ///         vault holds repo tokens). When the IPOR oracle returns `price == 0` for the
    ///         purchase token, the `_heldTermRepoTokenPv` helper returns `ok == false` with
    ///         `hasAnyPosition == true`; `_signedValueForServicerImpl` then re-raises
    ///         `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer)`.
    /// @dev NAV-blocking convention: the IPOR oracle is owner-controlled
    ///      configuration, not adversarial input — a zero price for a tracked servicer is a
    ///      NAV-blocking error by design (mirrors AAVE V3 / Morpho / Euler V2 / AAVE V4).
    ///      For UNTRACKED servicers the leg degrades silently to 0 — see the untracked
    ///      degradation test
    ///      `testBalanceFuseDegradesLegToZeroWhenPurchaseTokenPriceIsZero_untracked`.
    function testBalanceFuseRevertsOnPriceZeroForServicerPurchaseToken() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        // Clear the price (zero).
        oracle.setAssetPrice(address(t.purchaseToken), 0, 8);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Untracked servicer (no held repo tokens, no pending offers, no pending
    ///         bids, no locked collateral, no debt obligation). When the IPOR oracle returns
    ///         `price == 0`, the leg silently degrades to 0 instead of bricking `balanceOf`.
    /// @dev Validates the missing-oracle policy for UNTRACKED legs: a single
    ///      mis-configured oracle on an unused servicer must NOT freeze NAV reads on the
    ///      vault.
    function testBalanceFuseDegradesLegToZeroWhenPurchaseTokenPriceIsZero_untracked() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // No held repo tokens, no pending offers, no pending bids, no locked collateral,
        // no debt obligation — the servicer is fully untracked.
        // Clear the purchase-token price.
        oracle.setAssetPrice(address(t.purchaseToken), 0, 8);

        // No revert — untracked leg degrades to 0.
        uint256 nav = harness.balanceOf();
        assertEq(nav, 0, "untracked price-zero degrades silently to 0");
    }

    /// @notice Tracked-by-collateral servicer (positive locked PT-collateral but the
    ///         collateral oracle returns 0). The locked-collateral leg signals
    ///         `hasAnyPosition == true` even though pricing failed (`ok == false`). The fuse
    ///         must re-raise `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer)`
    ///         — proves that "tracked-but-priced-zero" edge case is handled.
    function testBalanceFuseRevertsOnPriceZeroForServicerCollateralToken_tracked() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Wire a custom collateral token whose oracle is intentionally NOT set (price == 0).
        MockERC20Decimals coll = new MockERC20Decimals("Coll", "C", 6);

        address[] memory accepted = new address[](1);
        accepted[0] = address(coll);
        t.collateralManager.setAcceptedTokens(accepted);
        t.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        t.collateralManager.externalLockCollateral(address(coll), 1_000_000);

        // Collateral balance > 0, oracle price == 0 → tracked AND price-zero.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Offers-asymmetry path. The vault has a pending offer in
    ///         vault-owned storage (`TermFinancePendingOffersStorageLib`), the OfferLocker
    ///         proxy is broken (every `lockedOffer` call reverts), and the purchase-token
    ///         oracle returns 0. Pre-fix: `_pendingOffersValueWad` short-circuited before the
    ///         price read (no live entry detectable) and `_hasTrackedExposure` only checked
    ///         the bids storage, so `anyPriceZero` never fired and NAV degraded silently to
    ///         0 despite tracked offer-side exposure. Post-fix: storage presence alone makes
    ///         `_pendingOffersValueWad` query the oracle and report `ok == false /
    ///         hasAnyPosition == true`; combined with the extended `_hasTrackedExposure`
    ///         (which now ORs the offers storage), the per-servicer aggregator re-raises
    ///         `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer)`.
    /// @dev Mirrors the bids-side semantics (`_pendingBidsValueWadForServicer`) where storage
    ///      entry presence is authoritative regardless of whether liveness can be confirmed
    ///      on the locker. Closes the silent-degradation window on the offer-side leg.
    function testBalanceFuseRevertsOnPriceZeroForServicerPurchaseToken_pendingOfferStorageOnly_brokenLocker()
        public
    {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Pending offer in vault-owned storage; no held repo tokens, no locked collateral,
        // no pending bids, no debt obligation. Tracked exposure comes from storage alone.
        bytes32 offerId = bytes32(uint256(0xABC));
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, 1_000_000);

        // Broken locker proxy: every `lockedOffer` call reverts. Pre-fix this caused the
        // helper to early-exit with `(true, 0, false)` before any oracle read.
        t.offerLocker.setLockedOfferReverts(true);

        // Wipe the purchase-token oracle to simulate a missing-price misconfiguration.
        oracle.setAssetPrice(address(t.purchaseToken), 0, 8);

        // Storage entry + broken locker + zero oracle on a tracked servicer must re-raise.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    // ============ balanceOf — pending offers ============

    function test_balanceOf_pendingOffer_contributesLockedAmountFlat() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);

        // Manually add a pending offer with a live `lockedOffer.amount > 0` on the locker.
        bytes32 offerId = bytes32(uint256(0xABC));
        uint256 lockedAmt = 1_000_000;
        t.offerLocker.setLockedOffer(
            offerId,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: offerId,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: lockedAmt,
                purchaseToken: address(t.purchaseToken),
                isRevealed: false
            })
        );

        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, lockedAmt);

        uint256 nav = harness.balanceOf();
        uint256 expected = _convertUsdcToWad(lockedAmt);
        assertEq(nav, expected, "pending offer = flat lockedAmount");
    }

    function test_balanceOf_pendingOffer_clearedOnChain_skipsEntry_noSSTORE() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        bytes32 offerId = bytes32(uint256(0xABC));
        // Stored on locker as cleared: amount == 0.
        t.offerLocker.setLockedOffer(
            offerId,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: offerId,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: 0,
                purchaseToken: address(t.purchaseToken),
                isRevealed: true
            })
        );

        // Storage still has the stale entry.
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, 1_000_000);

        uint256 nav = harness.balanceOf();
        assertEq(nav, 0, "stale pending entry skipped, no value added");
    }

    function test_balanceOf_pendingOffer_lockedOfferReverts_skipsEntry() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        bytes32 offerId = bytes32(uint256(0xABC));
        t.offerLocker.setLockedOfferReverts(true);
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, 1_000_000);

        uint256 nav = harness.balanceOf();
        assertEq(nav, 0, "lockedOffer revert -> skip (try/catch)");
    }

    function test_balanceOf_callableUnderStaticcall_noSSTOREregression() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);

        // Stale pending entry to exercise the path we previously had lazy-cleanup on.
        bytes32 offerId = bytes32(uint256(0xABC));
        t.offerLocker.setLockedOffer(
            offerId,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: offerId,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: 0,
                purchaseToken: address(t.purchaseToken),
                isRevealed: true
            })
        );
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, 1_000_000);

        // staticcall via low-level — would revert if balanceOf SSTOREs.
        (bool ok, bytes memory ret) = address(harness).staticcall(abi.encodeWithSignature("balanceOf()"));
        assertTrue(ok, "balanceOf must be staticcall-safe");
        uint256 nav = abi.decode(ret, (uint256));
        assertEq(nav, 0);
    }

    /// @notice Defensive branch: if a pending entry has `offerLocker == address(0)`
    ///         (only reachable by direct storage manipulation — production write paths reject
    ///         zero-locker via `OfferFuse._assertOfferLockerPaired`), `balanceOf` must skip it
    ///         and continue iterating instead of staticcall-reverting on a zero address.
    function test_balanceOf_pendingOffer_zeroLockerInStorage_isSkipped() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Direct storage write through the test harness, bypassing the fuse guards.
        bytes32 zeroLockerId = bytes32(uint256(0xDEAD));
        harness.addPendingOffer(address(t.servicer), address(0), zeroLockerId, 1_000_000);

        // A second, well-formed entry on the real locker proves the iterator continues past
        // the zero-locker entry.
        bytes32 goodId = bytes32(uint256(0xBEEF));
        uint256 goodAmt = 500_000;
        t.offerLocker.setLockedOffer(
            goodId,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: goodId,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: goodAmt,
                purchaseToken: address(t.purchaseToken),
                isRevealed: false
            })
        );
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), goodId, goodAmt);

        uint256 nav = harness.balanceOf();
        // Only `goodAmt` contributes; zero-locker entry was skipped (not added, not reverted).
        assertEq(nav, _convertUsdcToWad(goodAmt), "zero-locker entry skipped, good entry still counted");
    }

    /// @notice Regression test. A single servicer can hold pending offers
    ///         from two different OfferLockers (an old auction's locker still has live ids
    ///         while a fresh auction starts with a new locker). Per-id locker binding must
    ///         keep both contributions countable; the previous per-servicer cache would have
    ///         under-counted the cycle-N offer because the cache would have been overwritten
    ///         with cycle-N+1's locker address.
    function test_balanceOf_pendingOffers_acrossOfferLockerCycles_sumsBoth() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);

        // Cycle N: original locker (set up in _deployUsdcTerm as t.offerLocker).
        bytes32 idCycleN = bytes32(uint256(0xCAFE0001));
        uint256 amtN = 1_000_000;
        t.offerLocker.setLockedOffer(
            idCycleN,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: idCycleN,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: amtN,
                purchaseToken: address(t.purchaseToken),
                isRevealed: false
            })
        );
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), idCycleN, amtN);

        // Cycle N+1: fresh locker paired with the same servicer.
        MockTermAuctionOfferLocker offerLockerN1 = new MockTermAuctionOfferLocker();
        offerLockerN1.setTermRepoServicer(address(t.servicer));
        offerLockerN1.setTermRepoLocker(t.termRepoLockerAddr);
        offerLockerN1.setPurchaseToken(address(t.purchaseToken));

        bytes32 idCycleN1 = bytes32(uint256(0xCAFE0002));
        uint256 amtN1 = 2_500_000;
        offerLockerN1.setLockedOffer(
            idCycleN1,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: idCycleN1,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: amtN1,
                purchaseToken: address(t.purchaseToken),
                isRevealed: false
            })
        );
        harness.addPendingOffer(address(t.servicer), address(offerLockerN1), idCycleN1, amtN1);

        // NAV must sum BOTH cycles — under-count means the cross-cycle regression has returned.
        uint256 nav = harness.balanceOf();
        uint256 expected = _convertUsdcToWad(amtN + amtN1);
        assertEq(nav, expected, "both cycles' pending offers must count");
    }

    // ============ balanceOf — mixed pending + held ============

    function test_balanceOf_heldRepoTokenAndPendingOffer_sumsBoth() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);

        // Held: 500k repoToken, redValue 1e6 → face = 500k.
        t.repoToken.mint(address(harness), 500_000);
        t.repoToken.setRedemptionValue(1e18);

        // Pending: 200k locked.
        bytes32 offerId = bytes32(uint256(0xDEF));
        t.offerLocker.setLockedOffer(
            offerId,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: offerId,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: 200_000,
                purchaseToken: address(t.purchaseToken),
                isRevealed: false
            })
        );
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, 200_000);

        uint256 nav = harness.balanceOf();
        // Lower bound: held PV is below face=500k (pre-maturity discount), so ≥ ~499k + 200k = 699k.
        // Upper bound: face + pending = 500k + 200k = 700k.
        assertGt(nav, _convertUsdcToWad(699_000));
        assertLe(nav, _convertUsdcToWad(700_000));
    }

    // ============ balanceOf — multi-substrate ============

    function test_balanceOf_multipleServicers_iteratesAll() public {
        Term memory t1 = _deployUsdcTerm(block.timestamp + SECS_7D);
        Term memory t2 = _deployUsdcTerm(block.timestamp + SECS_7D);

        bytes32[] memory subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(t1.servicer));
        subs[1] = PlasmaVaultConfigLib.addressToBytes32(address(t2.servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        adapter.setRate(address(t1.repoToken), 5e16);
        adapter.setRate(address(t2.repoToken), 5e16);

        t1.repoToken.mint(address(harness), 1_000_000);
        t1.repoToken.setRedemptionValue(1e18);
        t2.repoToken.mint(address(harness), 500_000);
        t2.repoToken.setRedemptionValue(1e18);

        uint256 nav = harness.balanceOf();
        // Pre-maturity PV is below face: face=1_500_000 with 5%/7d discount → ~1_498_542.
        // Lower bound chosen generously to tolerate rounding & rate drift.
        assertLe(nav, _convertUsdcToWad(1_500_000));
        assertGt(nav, _convertUsdcToWad(1_498_000));
    }

    // ============ NAV-continuity ============

    /// @notice Asserts NAV stays continuous across lockOffers (t0 → t1) and stays flat
    ///         through the submission window (t1 → t2). Implements phases t0..t2.
    function test_balanceOf_navContinuity_acrossLockOffersAndWindow() public {
        uint256 tred = block.timestamp + SECS_7D;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);

        // t0: idle (USDC sits in the asset balance fuse — outside this fuse's scope).
        // We measure THIS fuse's contribution which should be 0.
        uint256 nav_t0 = harness.balanceOf();
        assertEq(nav_t0, 0, "idle: this fuse contributes nothing");

        // t1: after lockOffers — pending entry added, locker has amount > 0.
        bytes32 offerId = bytes32(uint256(0x1));
        uint256 amt = 1_000_000;
        t.offerLocker.setLockedOffer(
            offerId,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: offerId,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: amt,
                purchaseToken: address(t.purchaseToken),
                isRevealed: false
            })
        );
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, amt);

        uint256 nav_t1 = harness.balanceOf();
        assertEq(nav_t1, _convertUsdcToWad(amt), "after lockOffers: flat lockedAmount");

        // t2: 3 days later, still pre-clearing.
        vm.warp(block.timestamp + 3 * 86_400);
        uint256 nav_t2 = harness.balanceOf();
        assertEq(nav_t2, nav_t1, "flat through window (Option A)");
    }

    /// @notice Asserts the documented upward step at matched clearing — measured AT MATURITY
    ///         (the full accrual is what materialises by then). Phase t4
    ///         characterises this as "NAV ≈ face by maturity" vs pre-clearing flat A.
    function test_balanceOf_navStepAtMaturity_isDocumentedAccrual() public {
        uint256 tred = block.timestamp + SECS_7D;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);

        // Pre-clearing: pending = A.
        bytes32 offerId = bytes32(uint256(0x1));
        uint256 amt = 1_000_000;
        t.offerLocker.setLockedOffer(
            offerId,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: offerId,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: amt,
                purchaseToken: address(t.purchaseToken),
                isRevealed: false
            })
        );
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, amt);

        uint256 nav_pre = harness.balanceOf();

        // Simulate matched clearing.
        t.offerLocker.setLockedOffer(
            offerId,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: offerId,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 5e16,
                amount: 0,
                purchaseToken: address(t.purchaseToken),
                isRevealed: true
            })
        );
        // face_per_token = 1 + 5% * 7/360 = 1.000972 (18-dec mantissa)
        uint256 redVal = 1_000_972e12;
        t.repoToken.mint(address(harness), amt);
        t.repoToken.setRedemptionValue(redVal);

        // Warp to maturity — accrual is fully materialised.
        vm.warp(tred);
        uint256 nav_atMaturity = harness.balanceOf();

        // Upward step ≈ A * r * T / 360. Allow generous tolerance.
        uint256 expectedStep = (amt * 5e16 * SECS_7D) / (360 * 86_400 * WAD);
        uint256 expectedStepWad = _convertUsdcToWad(expectedStep);
        uint256 actualStep = nav_atMaturity - nav_pre;

        // Sanity: upward step exists by maturity.
        assertGt(nav_atMaturity, nav_pre, "matured clearing produces upward NAV step");
        // Tightened from ±20% to ±1%. Math is deterministic — only purchase-token
        // and price-precision rounding can introduce drift, and that is well below 1%.
        assertApproxEqRel(actualStep, expectedStepWad, 1e16, "NAV step matches A*r*T/360 within 1%");
    }

    // ============ borrower helpers ============

    /// @dev Construct a single-token / single-amount collateral array pair for a pending bid.
    function _singleCollateral(
        address token_,
        uint256 amount_
    ) internal pure returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](1);
        amounts = new uint256[](1);
        tokens[0] = token_;
        amounts[0] = amount_;
    }

    /// @dev Construct a two-token collateral array pair for a pending bid.
    function _twoCollateral(
        address tokenA_,
        uint256 amountA_,
        address tokenB_,
        uint256 amountB_
    ) internal pure returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](2);
        amounts = new uint256[](2);
        tokens[0] = tokenA_;
        tokens[1] = tokenB_;
        amounts[0] = amountA_;
        amounts[1] = amountB_;
    }

    /// @dev Convert a generic raw token amount priced at `1e8` / 8-dec oracle (matching the
    ///      tests' default purchase-token price) into WAD-USD. Use this where the token has
    ///      different decimals than USDC.
    function _convertWithDecimals(
        uint256 amount_,
        uint8 tokenDec_,
        uint256 priceMantissa_,
        uint256 priceDec_
    ) internal pure returns (uint256) {
        uint256 combined = uint256(tokenDec_) + priceDec_;
        if (combined >= 18) {
            return (amount_ * priceMantissa_) / (10 ** (combined - 18));
        }
        return amount_ * priceMantissa_ * (10 ** (18 - combined));
    }

    /// @dev Construct an empty bid struct to write onto the BidLocker via `setLockedBid` so
    ///      that `_tryReadLockedBidIsLive` reports the bid as live.
    function _liveBid(
        bytes32 id_,
        address bidder_,
        uint256 amount_,
        address purchaseToken_,
        address[] memory tokens_,
        uint256[] memory amounts_
    ) internal pure returns (IExtTermAuctionBidLocker.TermAuctionBid memory bid) {
        bid = IExtTermAuctionBidLocker.TermAuctionBid({
            id: id_,
            bidder: bidder_,
            bidPriceHash: bytes32(0),
            bidPriceRevealed: 0,
            amount: amount_,
            collateralAmounts: amounts_,
            purchaseToken: purchaseToken_,
            collateralTokens: tokens_,
            isRollover: false,
            rolloverPairOffTermRepoServicer: address(0),
            isRevealed: false
        });
    }

    /// @dev Spin up a `MockTermAuctionBidLocker` bound to `t.servicer` (mirrors the offer-locker
    ///      configuration baked into `_deployUsdcTerm`). Returns the locker instance.
    function _deployBidLocker(Term memory t_) internal returns (MockTermAuctionBidLocker locker) {
        locker = new MockTermAuctionBidLocker();
        locker.setTermRepoServicer(address(t_.servicer));
        locker.setPurchaseToken(address(t_.purchaseToken));
    }

    /// @dev One-shot: register a live pending bid both on the BidLocker and in the harness's
    ///      storage. Avoids the stack-too-deep that bare inline construction triggers.
    function _registerLivePendingBid(
        Term memory t_,
        MockTermAuctionBidLocker locker_,
        bytes32 id_,
        uint256 purchaseAmt_,
        address collToken_,
        uint256 collAmt_
    ) internal {
        (address[] memory tokens, uint256[] memory amounts) = _singleCollateral(collToken_, collAmt_);
        locker_.setLockedBid(
            id_,
            _liveBid(id_, address(harness), purchaseAmt_, address(t_.purchaseToken), tokens, amounts)
        );
        harness.addPendingBid(address(t_.servicer), address(locker_), id_, purchaseAmt_, tokens, amounts);
    }

    // ============ borrower side — pending bids leg ============

    /// @notice Borrower-side pending-bids leg, baseline: a single live pending bid
    ///         contributes the WAD-USD value of its locked collateral (NOT the requested
    ///         purchase amount). The locker's `lockedBid` must indicate liveness
    ///         (`bidder != 0 && amount != 0`); the authoritative collateral amounts come
    ///         from storage.
    function test_balanceOf_pendingBid_contributesLockedAmountFlat() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Use a 6-dec collateral token, priced at $1 with 8-dec oracle.
        MockERC20Decimals coll = new MockERC20Decimals("Collateral", "COLL", 6);
        oracle.setAssetPrice(address(coll), 1e8, 8);

        _registerLivePendingBid(t, _deployBidLocker(t), bytes32(uint256(0xB1D0)), 1_000_000, address(coll), 2_500_000);

        uint256 nav = harness.balanceOf();
        uint256 expected = _convertUsdcToWad(2_500_000); // same dec/price as USDC.
        assertEq(nav, expected, "pending bid = WAD-USD of locked collateral");
    }

    /// @notice Cross-cycle (BidLocker N and N+1) test: a single servicer can hold pending bids
    ///         in TWO different lockers (an older auction still has a live bid while a fresh
    ///         auction opens). NAV must sum BOTH — mirrors `test_balanceOf_pendingOffers_acrossOfferLockerCycles_sumsBoth`.
    function test_balanceOf_pendingBids_acrossBidLockerCycles_sumsBoth() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        MockERC20Decimals coll = new MockERC20Decimals("Collateral", "COLL", 6);
        oracle.setAssetPrice(address(coll), 1e8, 8);

        // Cycle N locker + live bid.
        _registerLivePendingBid(t, _deployBidLocker(t), bytes32(uint256(0xCAFE1001)), 800_000, address(coll), 1_000_000);
        // Cycle N+1 locker + live bid.
        _registerLivePendingBid(t, _deployBidLocker(t), bytes32(uint256(0xCAFE1002)), 1_500_000, address(coll), 2_500_000);

        uint256 nav = harness.balanceOf();
        uint256 expected = _convertUsdcToWad(1_000_000 + 2_500_000);
        assertEq(nav, expected, "both cycles' pending bids must count");
    }

    /// @notice Defensive: a pending bid stored with `bidLocker == address(0)` (only reachable
    ///         via direct storage manipulation; production write paths reject it) must be
    ///         skipped without reverting and the iterator continues.
    function test_balanceOf_pendingBid_zeroBidderInStorage_isSkipped() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Zero-locker pending bid (no liveness call is made for it — the `bidLocker == 0` short
        // circuit at the top of `_pendingBidLegValueWad` covers this).
        (address[] memory tokens, uint256[] memory amounts) = _singleCollateral(makeAddr("phantom-coll"), 999);
        harness.addPendingBid(address(t.servicer), address(0), bytes32(uint256(0xDEADBEEF)), 1_000_000, tokens, amounts);

        // Good bid: live on the locker, contributes 500_000 USDC-equivalent collateral.
        MockERC20Decimals coll = new MockERC20Decimals("Collateral", "COLL", 6);
        oracle.setAssetPrice(address(coll), 1e8, 8);
        _registerLivePendingBid(t, _deployBidLocker(t), bytes32(uint256(0xBEEF)), 400_000, address(coll), 500_000);

        uint256 nav = harness.balanceOf();
        assertEq(nav, _convertUsdcToWad(500_000), "zero-locker bid skipped, good bid counted");
    }

    /// @notice Stale bid: `lockedBid` returns a zero-bidder struct (cleared / cancelled /
    ///         refunded). The fuse's canonical liveness predicate (`bidder != 0 && amount != 0`)
    ///         must skip the entry — no value contributed.
    function test_balanceOf_pendingBid_clearedOnChain_skipsEntry() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        MockTermAuctionBidLocker bidLocker = _deployBidLocker(t);
        MockERC20Decimals coll = new MockERC20Decimals("Collateral", "COLL", 6);
        oracle.setAssetPrice(address(coll), 1e8, 8);

        // Cleared on locker: bidder == 0 (default struct after delete) — DON'T call setLockedBid.
        // Tracked in storage:
        (address[] memory tokens, uint256[] memory amounts) = _singleCollateral(address(coll), 1_000_000);
        harness.addPendingBid(address(t.servicer), address(bidLocker), bytes32(uint256(0x511E)), 1_000_000, tokens, amounts);

        uint256 nav = harness.balanceOf();
        assertEq(nav, 0, "stale (bidder==0) bid skipped, no value added");
    }

    /// @notice `lockedBid` reverts → catchable by inner `_tryReadLockedBidIsLive` try/catch;
    ///         entry is skipped (degrades to 0) and the outer iteration continues. Mirrors
    ///         `test_balanceOf_pendingOffer_lockedOfferReverts_skipsEntry` for the bid path.
    function test_balanceOf_pendingBid_lockedBidReverts_skipsEntry() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        MockTermAuctionBidLocker bidLocker = _deployBidLocker(t);
        bidLocker.setLockedBidReverts(true);

        MockERC20Decimals coll = new MockERC20Decimals("Collateral", "COLL", 6);
        oracle.setAssetPrice(address(coll), 1e8, 8);

        (address[] memory tokens, uint256[] memory amounts) = _singleCollateral(address(coll), 1_000_000);
        harness.addPendingBid(address(t.servicer), address(bidLocker), bytes32(uint256(0xABCD)), 1_000_000, tokens, amounts);

        uint256 nav = harness.balanceOf();
        assertEq(nav, 0, "lockedBid revert -> skip via try/catch");
    }

    // ============ borrower side — debt leg ============

    /// @notice Debt-leg baseline: a borrower with non-zero `getBorrowerRepurchaseObligation`
    ///         contributes a NEGATIVE leg. With matching locked collateral, NAV = collateral
    ///         (positive) − debt PV (positive but subtracted) > 0. Post-maturity:
    ///         secondsToMaturity == 0 → PV == face (no time discount).
    function test_balanceOf_debt_returnedAsNegative_subtractsFromNAV() public {
        // Post-maturity scenario: tred == block.timestamp + 1 then warp.
        uint256 tred = block.timestamp + 1;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));
        vm.warp(tred + 100); // ensures block.timestamp >= endTimestamp → pv == face

        // Wire one accepted collateral token (USDC re-used for simplicity).
        address[] memory accepted = new address[](1);
        accepted[0] = address(t.purchaseToken);
        t.collateralManager.setAcceptedTokens(accepted);

        // 5_000_000 USDC locked as collateral, 1_000_000 USDC debt face.
        // Deposit into the CM's accounting via `externalLockCollateral` (mock pulls funds from
        // the harness; we deal balance + skipPull=true to avoid token plumbing).
        t.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        t.collateralManager.externalLockCollateral(address(t.purchaseToken), 5_000_000);

        t.servicer.setBorrowerRepurchaseObligation(address(harness), 1_000_000);

        uint256 nav = harness.balanceOf();
        // collateral = 5_000_000 USDC → 5e18 WAD, debt = 1_000_000 USDC → 1e18 WAD.
        // Net = 4_000_000 USDC → 4e18 WAD.
        uint256 expected = _convertUsdcToWad(4_000_000);
        assertEq(nav, expected, "NAV = collateral - debt");
    }

    /// @notice "Debt-leg failure semantics — no tracked exposure":
    ///         the debt-read is still ATTEMPTED, but a successful read returning 0 contributes
    ///         no negative leg. We force the obligation read to REVERT and assert NAV == 0
    ///         (the absence of tracked exposure means the revert degrades to 0).
    function test_balanceOf_debt_zeroExposure_skipsDebtRead() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // No collateral, no pending bids → not tracked. Even a reverting debt read degrades.
        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("getBorrowerRepurchaseObligation(address)", address(harness)),
            bytes("revert")
        );

        uint256 nav = harness.balanceOf();
        assertEq(nav, 0, "no tracked exposure -> debt revert silently degrades");
    }

    /// @notice Selector-gated re-raise: when the vault HAS tracked exposure (locked
    ///         collateral > 0) and `getBorrowerRepurchaseObligation` reverts, the WHOLE
    ///         `balanceOf` MUST revert with `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer`.
    function test_balanceOf_debt_trackedExposureWithDebtReadRevert_reverts() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Wire collateral so prior collateral value > 0.
        address[] memory accepted = new address[](1);
        accepted[0] = address(t.purchaseToken);
        t.collateralManager.setAcceptedTokens(accepted);
        t.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        t.collateralManager.externalLockCollateral(address(t.purchaseToken), 1_000_000);

        // Force debt read to revert.
        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("getBorrowerRepurchaseObligation(address)", address(harness)),
            bytes("debt-read-fail")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtReadFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Borrower exposure tracked via pending bids alone (no actively locked collateral
    ///         and no held repo tokens) still gates the debt-read revert into a re-raise — the
    ///         pending-bids storage is in vault-owned storage and is authoritative evidence of
    ///         borrower intent regardless of the Term proxy state.
    function test_balanceOf_debt_trackedViaPendingBidsOnly_reverts() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Pending bid stored — `_hasTrackedExposure` returns true. We don't need the locker call
        // to succeed; even with locked-bid revert the storage signal alone gates the re-raise.
        MockTermAuctionBidLocker bidLocker = _deployBidLocker(t);
        bidLocker.setLockedBidReverts(true);
        (address[] memory tokens, uint256[] memory amounts) = _singleCollateral(makeAddr("col"), 1);
        harness.addPendingBid(address(t.servicer), address(bidLocker), bytes32(uint256(0xB1D7)), 1_000_000, tokens, amounts);

        // Force debt read to revert.
        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("getBorrowerRepurchaseObligation(address)", address(harness)),
            bytes("debt-read-fail")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtReadFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Post-maturity branch in `_debtPvWad`: when `block.timestamp >= endOfRepurchaseWindow`,
    ///         `secondsToMaturity == 0` and `pv == face`. The negated WAD value equals the
    ///         face's USD valuation.
    function test_balanceOf_debt_postMaturity_pvEqualsFace() public {
        uint256 tred = block.timestamp + 1;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));
        vm.warp(tred + 1); // strictly past endOfRepurchaseWindow.

        // Wire some collateral so the servicer leg is tracked AND positive sufficient to
        // offset the debt (avoids `SafeCast.toUint256` net-negative revert which is exercised
        // in a separate test).
        address[] memory accepted = new address[](1);
        accepted[0] = address(t.purchaseToken);
        t.collateralManager.setAcceptedTokens(accepted);
        t.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        t.collateralManager.externalLockCollateral(address(t.purchaseToken), 3_000_000);

        t.servicer.setBorrowerRepurchaseObligation(address(harness), 2_000_000);

        uint256 nav = harness.balanceOf();
        // collateral (3M USDC) - debt face (2M USDC, no time discount) = 1M USDC.
        assertEq(nav, _convertUsdcToWad(1_000_000), "post-maturity: pv == face");
    }

    /// @notice Pre-maturity branch: PV < face, so net NAV = collateral − pv > collateral − face.
    function test_balanceOf_debt_preMaturity_pvLessThanFace() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16); // 5% APR

        // Collateral 10M USDC; debt 1M USDC face — pre-maturity discount makes pv < 1M.
        address[] memory accepted = new address[](1);
        accepted[0] = address(t.purchaseToken);
        t.collateralManager.setAcceptedTokens(accepted);
        t.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        t.collateralManager.externalLockCollateral(address(t.purchaseToken), 10_000_000);

        t.servicer.setBorrowerRepurchaseObligation(address(harness), 1_000_000);

        uint256 nav = harness.balanceOf();
        // collateral - pv > collateral - face. Equivalent assertion: nav > 9_000_000.
        assertGt(nav, _convertUsdcToWad(9_000_000), "pre-maturity discount produces pv < face");
        // Sanity upper bound: nav < collateral (debt positive subtracted).
        assertLt(nav, _convertUsdcToWad(10_000_000), "debt leg subtracts something");
    }

    // ============ borrower side — locked collateral leg ============

    /// @notice Locked collateral leg iterates `cm.collateralTokens(i)` for `i in [0..n)` and
    ///         sums the WAD-USD value of each balance. Multiple accepted tokens with the same
    ///         price contribute additively.
    function test_balanceOf_lockedCollateral_twoTokens_sumsBoth() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        MockERC20Decimals collA = new MockERC20Decimals("CollA", "CA", 6);
        MockERC20Decimals collB = new MockERC20Decimals("CollB", "CB", 6);
        oracle.setAssetPrice(address(collA), 1e8, 8);
        oracle.setAssetPrice(address(collB), 1e8, 8);

        address[] memory accepted = new address[](2);
        accepted[0] = address(collA);
        accepted[1] = address(collB);
        t.collateralManager.setAcceptedTokens(accepted);

        t.collateralManager.setSkipPull(true);
        vm.startPrank(address(harness));
        t.collateralManager.externalLockCollateral(address(collA), 1_500_000);
        t.collateralManager.externalLockCollateral(address(collB), 700_000);
        vm.stopPrank();

        uint256 nav = harness.balanceOf();
        assertEq(nav, _convertUsdcToWad(2_200_000), "two collateral tokens summed");
    }

    /// @notice Cap check: a servicer with `numOfAcceptedCollateralTokens() = 9` (one above
    ///         `MAX_COLLATERAL_TOKENS_PER_SERVICER = 8`) is silently degraded to a 0 leg by
    ///         `_signedValueForServicerInternal` (the cap check returns 0 directly). A
    ///         second well-formed servicer still contributes.
    function testBalanceOfDegradesServicerLegToZeroWhenCollateralTokensExceedsMax() public {
        // Capped-out servicer.
        Term memory t1 = _deployUsdcTerm(block.timestamp + SECS_7D);

        // Build 9 accepted tokens with valid oracle prices so the cap is the only failure.
        address[] memory tooMany = new address[](9);
        for (uint256 i; i < 9; ++i) {
            MockERC20Decimals tok = new MockERC20Decimals(string(abi.encodePacked("Tok", i)), "TOK", 6);
            oracle.setAssetPrice(address(tok), 1e8, 8);
            tooMany[i] = address(tok);
        }
        t1.collateralManager.setAcceptedTokens(tooMany);

        // Normal servicer with held repo position.
        Term memory t2 = _deployUsdcTerm(block.timestamp + SECS_7D);
        adapter.setRate(address(t2.repoToken), 5e16);
        t2.repoToken.mint(address(harness), 1_000_000);
        t2.repoToken.setRedemptionValue(1e18);

        bytes32[] memory subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(t1.servicer));
        subs[1] = PlasmaVaultConfigLib.addressToBytes32(address(t2.servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        uint256 nav = harness.balanceOf();
        // t1 leg = 0 (cap revert); t2 leg ≈ 1M USDC (slight pre-maturity discount).
        assertLe(nav, _convertUsdcToWad(1_000_000));
        assertGt(nav, _convertUsdcToWad(998_000));
    }

    // ============ borrower side — localised try/catch invariants ============

    /// @notice Invariant: a servicer whose foreign reads revert (cap, OOB on
    ///         `collateralTokens`, proxy breakage) degrades to 0 via the localised
    ///         `_tryRead…` helpers; the next servicer still contributes. Already covered
    ///         partially by the cap-overflow test — here we exercise a DIFFERENT revert
    ///         source: collateral manager's `collateralTokens(0)` OOB-reverts (length-zero
    ///         array but reported count > 0).
    function test_balanceOf_servicerLegReverts_degradesToZero_continuesIteration() public {
        Term memory t1 = _deployUsdcTerm(block.timestamp + SECS_7D);
        // Configure CM with reported count > 0 BUT no actual tokens — `collateralTokens(0)`
        // will OOB-revert mid-leg.
        vm.mockCall(
            address(t1.collateralManager),
            abi.encodeWithSignature("numOfAcceptedCollateralTokens()"),
            abi.encode(uint8(1))
        );
        // collateralTokens(0) is unmocked → falls through to the real mock which has no
        // accepted tokens → reverts with OOB.

        // Normal servicer.
        Term memory t2 = _deployUsdcTerm(block.timestamp + SECS_7D);
        adapter.setRate(address(t2.repoToken), 5e16);
        t2.repoToken.mint(address(harness), 500_000);
        t2.repoToken.setRedemptionValue(1e18);

        bytes32[] memory subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(t1.servicer));
        subs[1] = PlasmaVaultConfigLib.addressToBytes32(address(t2.servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        uint256 nav = harness.balanceOf();
        // t1 = 0 (OOB revert caught); t2 ≈ 500_000 USDC (pre-maturity discount).
        assertLe(nav, _convertUsdcToWad(500_000));
        assertGt(nav, _convertUsdcToWad(499_000));
    }

    /// @notice Generic non-debt revert is caught and degraded — exercised here by forcing the
    ///         servicer's `termRepoCollateralManager()` to revert (the very first external
    ///         read inside `_signedValueForServicerInternal`). Mirror of the proxy-breakage
    ///         scenario; the local `_tryReadCollateralManager` try/catch swallows the revert
    ///         and the leg degrades to 0.
    function test_balanceOf_otherRevertsAreCaught() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("termRepoCollateralManager()"),
            bytes("proxy-breakage")
        );

        uint256 nav = harness.balanceOf();
        assertEq(nav, 0, "generic revert -> degrade to 0");
    }

    /// @notice Selector-gate granularity: the tracked-borrower debt-read failure
    ///         RE-RAISES even if other servicers are still healthy. This is ONE of TWO
    ///         channels by which a single leg can take down the whole `balanceOf`; the
    ///         other is the
    ///         `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked` gate.
    function test_balanceOf_debtReadFailedForTracked_isReraised() public {
        // Tracked-borrower servicer (will revert).
        Term memory tBad = _deployUsdcTerm(block.timestamp + SECS_7D);

        // Wire collateral so prior collateral > 0 → tracked.
        address[] memory accepted = new address[](1);
        accepted[0] = address(tBad.purchaseToken);
        tBad.collateralManager.setAcceptedTokens(accepted);
        tBad.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        tBad.collateralManager.externalLockCollateral(address(tBad.purchaseToken), 1_000_000);

        vm.mockCallRevert(
            address(tBad.servicer),
            abi.encodeWithSignature("getBorrowerRepurchaseObligation(address)", address(harness)),
            bytes("debt-fail")
        );

        // Healthy servicer with held position.
        Term memory tGood = _deployUsdcTerm(block.timestamp + SECS_7D);
        adapter.setRate(address(tGood.repoToken), 5e16);
        tGood.repoToken.mint(address(harness), 1_000_000);
        tGood.repoToken.setRedemptionValue(1e18);

        // Both granted as substrates.
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(tBad.servicer));
        subs[1] = PlasmaVaultConfigLib.addressToBytes32(address(tGood.servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        // Whole balanceOf reverts despite the healthy servicer.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtReadFailedForTrackedServicer.selector,
                address(tBad.servicer)
            )
        );
        harness.balanceOf();
    }

    // ============ borrower side — signed aggregation invariants ============

    /// @notice `SafeCast.toUint256` invariant: a single servicer where debt > collateral
    ///         yields a negative signed leg. The net total is converted via
    ///         `SafeCast.toUint256(...)` which reverts on a negative value — the documented
    ///         "ERC4626 insolvency signal" path.
    function test_balanceOf_negativeServicerLeg_revertsViaSafeCast() public {
        // Post-maturity scenario so secondsToMaturity == 0 → pv == face (predictable).
        uint256 tred = block.timestamp + 1;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));
        vm.warp(tred + 10);

        // Debt 5_000_000 USDC; NO collateral, NO held repo, NO pending offers/bids.
        t.servicer.setBorrowerRepurchaseObligation(address(harness), 5_000_000);

        // SafeCast.toUint256 reverts the net-negative as a panic 0x11 (under/overflow).
        vm.expectRevert();
        harness.balanceOf();
    }

    /// @notice Debt saturation: `_debtPvWad` returns `-MAX_VALUE_PER_LEG` directly when the
    ///         uint256 mantissa exceeds `MAX_VALUE_PER_LEG_UINT` (1e36). With NO offsetting
    ///         positive leg, the entire `balanceOf` net is `-MAX_VALUE_PER_LEG` and
    ///         `SafeCast.toUint256` reverts — the documented insolvency-signal path.
    /// @dev With purchasePrec = 1e6 and oracle price 1e8 (8-dec), combined decimals = 14, so
    ///      `IporMath.convertToWad(face * price, 14) = face * 1e8 * 1e4 = face * 1e12`.
    ///      Saturation at 1e36 is triggered for face > 1e24.
    function test_balanceOf_debtExceedsMaxValue_saturates() public {
        uint256 tred = block.timestamp + 1;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));
        vm.warp(tred + 10);

        // No collateral, no pending bids, no held repo → only the debt leg contributes.
        // Face must exceed 1e24 (raw purchase-token units) to hit the WAD saturation cap.
        t.servicer.setBorrowerRepurchaseObligation(address(harness), 1e25);

        // -MAX_VALUE_PER_LEG → SafeCast reverts.
        vm.expectRevert();
        harness.balanceOf();
    }

    // ============ borrower side — mixed legs ============

    /// @notice Mixed legs: held repo (lender) + pending bid (borrower) + locked collateral
    ///         (borrower) + outstanding debt (borrower) — all four legs contribute and
    ///         net NAV reflects their sum.
    function test_balanceOf_mixedLenderAndBorrower_aggregatesCorrectly() public {
        uint256 tred = block.timestamp + 1;
        Term memory t = _deployUsdcTerm(tred);
        _grantSubstrate(address(t.servicer));
        vm.warp(tred + 10); // post-maturity → predictable pv == face

        // Lender side: 2M held repo, redValue 1e18 → face = 2M, post-maturity haircut 0.
        t.repoToken.mint(address(harness), 2_000_000);
        t.repoToken.setRedemptionValue(1e18);

        // Borrower side: lock 3M USDC collateral.
        address[] memory accepted = new address[](1);
        accepted[0] = address(t.purchaseToken);
        t.collateralManager.setAcceptedTokens(accepted);
        t.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        t.collateralManager.externalLockCollateral(address(t.purchaseToken), 3_000_000);

        // Pending bid: 1.5M collateral on a live bidLocker.
        _registerLivePendingBid(t, _deployBidLocker(t), bytes32(uint256(0xBEE7)), 800_000, address(t.purchaseToken), 1_500_000);

        // Debt: 2M face.
        t.servicer.setBorrowerRepurchaseObligation(address(harness), 2_000_000);

        // Net = held(2M) + collateral(3M) + pendingBids(1.5M) - debt(2M) = 4.5M USDC.
        uint256 nav = harness.balanceOf();
        assertEq(nav, _convertUsdcToWad(4_500_000), "lender + borrower legs aggregate correctly");
    }

    // ============ wrapped servicer reads on pending-offers leg ============

    /// @notice Regression: a tracked pending-offer with the
    ///         servicer's `purchaseToken()` reverting (paused / upgraded proxy) MUST
    ///         trigger the re-raise — pre-fix the helper either bubbled the raw
    ///         revert or silently returned `(true, 0, ...)` on `purchaseToken == 0`.
    function testBalanceFuseRevertsOnServicerPurchaseTokenReverts_pendingOfferTracked() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        bytes32 offerId = bytes32(uint256(0xABC));
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, 1_000_000);

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("purchaseToken()"),
            bytes("MockTermRepoServicer: purchaseToken reverts")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Regression: a tracked pending-offer with the servicer's
    ///         `purchaseToken()` returning `address(0)` (pre-clearing / migration bug)
    ///         MUST trigger the re-raise. Pre-fix the helper returned
    ///         `(true, 0, hasAnyPosition)` and the leg silently disappeared from NAV.
    function testBalanceFuseRevertsOnServicerPurchaseTokenZero_pendingOfferTracked() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        bytes32 offerId = bytes32(uint256(0xABC));
        harness.addPendingOffer(address(t.servicer), address(t.offerLocker), offerId, 1_000_000);

        vm.mockCall(
            address(t.servicer),
            abi.encodeWithSignature("purchaseToken()"),
            abi.encode(address(0))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    // ============ wrapped servicer reads on debt leg ============

    /// @notice Regression: when the borrower is tracked (positive obligation)
    ///         and the Adapter-B discount rate read fails (zero address or revert), the
    ///         debt leg MUST revert with the dedicated diagnostic — pre-fix it silently
    ///         degraded to 0 (share-mint attack window).
    function testBalanceFuseDebtRateFailedReverts_onDiscountRateRevert() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Tracked borrower: positive obligation.
        t.servicer.setBorrowerRepurchaseObligation(address(harness), 1_000_000);

        // Adapter-B revert on getDiscountRate.
        vm.mockCallRevert(
            address(adapter),
            abi.encodeWithSignature("getDiscountRate(address)", address(t.repoToken)),
            bytes("Adapter-B: getDiscountRate reverts")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtRateFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Regression on `_debtPvWad`: a tracked borrower whose
    ///         `endOfRepurchaseWindow()` reverts MUST trigger the debt-rate diagnostic
    ///         (pre-fix the raw revert bubbled out of `balanceOf` for the whole vault).
    function testBalanceFuseDebtRateFailedReverts_onEndOfRepurchaseWindowRevert() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.servicer.setBorrowerRepurchaseObligation(address(harness), 1_000_000);

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("endOfRepurchaseWindow()"),
            bytes("Servicer: endOfRepurchaseWindow reverts")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtRateFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Regression on `_debtPvWad`: a tracked borrower whose
    ///         `termRepoToken()` reverts MUST trigger the debt-rate diagnostic.
    function testBalanceFuseDebtRateFailedReverts_onRepoTokenRevert() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.servicer.setBorrowerRepurchaseObligation(address(harness), 1_000_000);

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("termRepoToken()"),
            bytes("Servicer: termRepoToken reverts")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtRateFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    // ============ wrapped held-RepoToken balanceOf + topology-fail tracked signal ============

    /// @notice Regression: a vault holding a non-zero `TermRepoToken` balance must
    ///         re-raise when the `balanceOf` call on the repoToken reverts (paused
    ///         / upgraded proxy). Pre-fix the call bubbled out of `balanceOf` for the
    ///         entire vault.
    function testBalanceFuseRevertsOnRepoTokenBalanceOfReverts_heldTracked() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));
        adapter.setRate(address(t.repoToken), 5e16);

        // Vault has a positive repoToken balance pre-revert.
        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1e18);

        vm.mockCallRevert(
            address(t.repoToken),
            abi.encodeWithSignature("balanceOf(address)", address(harness)),
            bytes("RepoToken: paused")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Regression: held leg with positive repoToken balance + topology read
    ///         failure (e.g. `redemptionValue()` reverts) MUST re-raise. Pre-fix
    ///         the helper returned `(true, 0, false)` and the held leg silently
    ///         disappeared from NAV.
    function testBalanceFuseRevertsOnTopologyFailWithHeldBalance() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1e18);

        vm.mockCallRevert(
            address(t.repoToken),
            abi.encodeWithSignature("redemptionValue()"),
            bytes("RepoToken: redemptionValue reverts")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    // ============ _lockedCollateralValueWad mid-loop read failure preserves hasAnyPosition ============

    /// @notice Regression: when a mid-loop CollateralManager read fails (token i
    ///         lookup or balance lookup) AND a previous iteration already proved a
    ///         positive balance, the helper MUST re-raise. Pre-fix it returned
    ///         `(true, 0, false)` and silently dropped both signals.
    function testBalanceFuseRevertsOnMidLoopCollateralReadFailWithPriorBalance() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Two accepted collateral tokens: index 0 with positive balance, index 1 reverts.
        MockERC20Decimals badToken = new MockERC20Decimals("BAD", "BAD", 18);
        address[] memory accepted = new address[](2);
        accepted[0] = address(t.purchaseToken);
        accepted[1] = address(badToken);
        t.collateralManager.setAcceptedTokens(accepted);
        t.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        t.collateralManager.externalLockCollateral(address(t.purchaseToken), 1_000_000);

        // Force getCollateralBalance for token index 1 to revert.
        vm.mockCallRevert(
            address(t.collateralManager),
            abi.encodeWithSignature("getCollateralBalance(address,address)", address(harness), address(badToken)),
            bytes("CM: getCollateralBalance reverts on index 1")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    // ============ adversarial decimals overflow guard ============

    /// @notice Regression: a `purchaseToken.decimals()` value above the
    ///         MAX_TOKEN_DECIMALS cap (would overflow `10 ** dec`) MUST degrade the
    ///         held leg via the re-raise instead of bubbling a raw overflow revert.
    function testBalanceFuseRevertsOnPurchaseTokenDecimalsOverCap_heldTracked() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.repoToken.mint(address(harness), 1_000_000);
        t.repoToken.setRedemptionValue(1e18);

        // 100 > MAX_TOKEN_DECIMALS (30). Topology probe degrades via the cap; held leg
        // becomes a re-raise candidate because balance > 0.
        vm.mockCall(
            address(t.purchaseToken),
            abi.encodeWithSignature("decimals()"),
            abi.encode(uint8(100))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Regression on the debt leg: a tracked borrower with an out-of-cap
    ///         purchase-token decimals MUST trigger the debt-rate diagnostic (mirror of
    ///         the fail-fast posture, not silent zero).
    function testBalanceFuseDebtRateFailedReverts_onPurchaseTokenDecimalsOverCap() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.servicer.setBorrowerRepurchaseObligation(address(harness), 1_000_000);

        vm.mockCall(
            address(t.purchaseToken),
            abi.encodeWithSignature("decimals()"),
            abi.encode(uint8(100))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtRateFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice Regression on `_debtPvWad`: a tracked borrower whose
    ///         servicer `purchaseToken()` reverts MUST trigger the debt-rate diagnostic
    ///         (pre-fix the raw revert bubbled out of `balanceOf`).
    function testBalanceFuseDebtRateFailedReverts_onPurchaseTokenRevert() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        t.servicer.setBorrowerRepurchaseObligation(address(harness), 1_000_000);

        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("purchaseToken()"),
            bytes("Servicer: purchaseToken reverts")
        );

        // NOTE: the pending-offers leg's `purchaseToken()` wrapper would fire first via
        // the price-zero re-raise, but here there is no pending-offer storage and no held
        // repo position, so the call path proceeds straight to the debt leg.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtRateFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        harness.balanceOf();
    }
}
