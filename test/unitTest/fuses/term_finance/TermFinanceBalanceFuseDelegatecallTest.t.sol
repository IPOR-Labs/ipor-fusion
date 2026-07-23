// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";

import {TermFinanceBalanceFuse} from "contracts/fuses/term_finance/TermFinanceBalanceFuse.sol";

import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockPriceOracleMiddlewareForTermFinance} from "./mocks/MockPriceOracleMiddlewareForTermFinance.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermDiscountRateAdapter} from "./mocks/MockTermDiscountRateAdapter.sol";
import {MockTermRepoCollateralManager} from "./mocks/MockTermRepoCollateralManager.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";
import {MockTermRepoToken} from "./mocks/MockTermRepoToken.sol";

/// @notice Minimal PlasmaVault stand-in whose ONLY purpose is to delegatecall the fuse
///         at a different address than its own bytecode — i.e. the production topology.
///         No fallback / no PlasmaVaultBase delegation; any unknown selector reverts here so
///         a buggy `try this.fn(...)` inside the fuse is observed by the test (the catch
///         swallows it and `balanceOf()` returns 0).
/// @dev Exposes the same storage setters as `TermFinanceBalanceFuseHarness` so that the
///      fixture can seed the substrate list and price oracle middleware against the VAULT's
///      ERC-7201 storage — which is what the delegatecalled fuse code reads via
///      `address(this)`.
contract MinimalPlasmaVaultHarness {
    using Address for address;

    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    function setPriceOracleMiddleware(address oracle_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(oracle_);
    }

    /// @notice Production-topology entry: `functionDelegateCall(fuse, balanceOf())`.
    /// @dev Mirrors `PlasmaVault.functionDelegateCall(fuse, ...)` — runs the fuse code with
    ///      `address(this) == vault`. A `try this.signedValueForServicer(...)` inside the
    ///      fuse will hit THIS contract's selector dispatch (which has no such function) and
    ///      revert; the test asserts the post-refactor behaviour of NOT swallowing legit legs.
    function delegateBalanceOf(address fuse_) external returns (uint256) {
        bytes memory ret = fuse_.functionDelegateCall(abi.encodeWithSignature("balanceOf()"));
        return abi.decode(ret, (uint256));
    }
}

/// @title TermFinanceBalanceFuseDelegatecallTest
/// @notice Regression test. Reproduces the EXACT production topology — the vault
///         lives at one address, the fuse at another, and the vault invokes the fuse via
///         `Address.functionDelegateCall` (mirroring `PlasmaVault.functionDelegateCall(fuse,
///         balanceOf())`). The pre-refactor implementation issued `try this.signedValueForServicer(...)`
///         which under this topology hits the vault's empty fallback and the outer catch swallows
///         the result — NAV degrades to 0 unconditionally. The unit tests in
///         `TermFinanceBalanceFuseTest.t.sol` did not catch this because the harness inherits
///         the fuse so the self-call hits the same contract and succeeds.
contract TermFinanceBalanceFuseDelegatecallTest is Test {
    uint256 private constant MARKET_ID = 52;
    uint256 private constant WAD = 1e18;
    uint256 private constant SECS_28D = 28 * 86_400;
    uint256 private constant SECS_7D = 7 * 86_400;

    MinimalPlasmaVaultHarness private vault;
    TermFinanceBalanceFuse private fuse;
    MockTermController private controller;
    MockTermDiscountRateAdapter private adapter;
    MockPriceOracleMiddlewareForTermFinance private oracle;

    function setUp() public {
        controller = new MockTermController();
        adapter = new MockTermDiscountRateAdapter();
        oracle = new MockPriceOracleMiddlewareForTermFinance();

        vault = new MinimalPlasmaVaultHarness();
        fuse = new TermFinanceBalanceFuse(MARKET_ID, address(controller), address(adapter));

        // Seed the price oracle on the VAULT's storage (delegatecalled fuse reads it via
        // `PlasmaVaultLib.getPriceOracleMiddleware()` at the vault's ERC-7201 slot).
        vault.setPriceOracleMiddleware(address(oracle));

        // Sanity: vault and fuse MUST be at distinct addresses for this topology to test
        // the self-call breakage; `new` guarantees this but we assert it for clarity.
        require(address(vault) != address(fuse), "fixture: vault must differ from fuse");
    }

    // ============ helpers (mirror `TermFinanceBalanceFuseTest._deployUsdcTerm`) ============

    struct Term {
        MockTermRepoServicer servicer;
        MockTermRepoToken repoToken;
        MockTermRepoCollateralManager collateralManager;
        MockERC20Decimals purchaseToken;
        address termRepoLockerAddr;
    }

    /// @dev Build a complete USDC-purchase Term Repo wired up with mocks. Mirrors the helper
    ///      in `TermFinanceBalanceFuseTest` but trimmed to what the delegatecall regression
    ///      needs (no auction lockers — we only exercise the held-repo and tracked-debt legs).
    function _deployUsdcTerm(uint256 tred_) internal returns (Term memory t) {
        t.purchaseToken = new MockERC20Decimals("USD Coin", "USDC", 6);
        t.repoToken = new MockTermRepoToken("TermRepoToken", "TRT", 6);
        t.collateralManager = new MockTermRepoCollateralManager();
        t.servicer = new MockTermRepoServicer();
        t.termRepoLockerAddr = makeAddr("termRepoLocker");

        t.servicer.setTermRepoToken(address(t.repoToken));
        t.servicer.setTermRepoLocker(t.termRepoLockerAddr);
        t.servicer.setTermRepoCollateralManager(address(t.collateralManager));
        t.servicer.setPurchaseToken(address(t.purchaseToken));
        t.servicer.setRedemptionTimestamp(tred_);
        t.servicer.setMaturityTimestamp(tred_);
        t.servicer.setEndOfRepurchaseWindow(tred_);
        t.servicer.setShortfallHaircutMantissa(0);

        t.collateralManager.setTermRepoLocker(t.termRepoLockerAddr);
        t.collateralManager.setAcceptedTokens(new address[](0));

        controller.setIsTermDeployed(address(t.servicer), true);
        oracle.setAssetPrice(address(t.purchaseToken), 1e8, 8);
    }

    function _grantSubstrate(address servicer_) internal {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(servicer_);
        vault.setMarketSubstrates(MARKET_ID, subs);
    }

    function _convertUsdcToWad(uint256 usdcAmount_) internal pure returns (uint256) {
        return usdcAmount_ * 1e8 * 1e4;
    }

    // ============ regression cases ============

    /// @notice REGRESSION: under the production delegatecall topology (vault and fuse at
    ///         distinct addresses), `balanceOf` MUST aggregate the held TermRepoToken position
    ///         correctly. Before the fix this test fails with NAV == 0 because the
    ///         fuse's `try this.signedValueForServicer(...)` hits the vault's selector dispatch
    ///         (which has no such function), reverts, and the outer catch swallows the leg.
    function test_balanceOf_underProductionDelegatecallTopology_returnsCorrectNav() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));

        adapter.setRate(address(t.repoToken), 5e16);

        // The held position lives on the VAULT (== address(this) under delegatecall).
        t.repoToken.mint(address(vault), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        uint256 nav = vault.delegateBalanceOf(address(fuse));

        // PV at clearing ≈ 1_000_000 USDC → WAD-USD via $1 price.
        uint256 expected = _convertUsdcToWad(1_000_000);
        assertApproxEqAbs(nav, expected, 100 * 1e4, "PV pre-maturity ~ principal");
        assertGt(nav, 0, "balanceOf must aggregate via delegatecall topology");
    }

    /// @notice REGRESSION: a debt-leg failure on a TRACKED borrower (positive locked
    ///         collateral) MUST re-raise across the delegatecall boundary as
    ///         `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer`. Before the
    ///         fix this test fails because the inner revert is swallowed by the outer catch
    ///         (selector mismatch — the inner revert was the self-call empty-selector revert,
    ///         not the debt-read selector — so the leg silently degraded to 0 instead of
    ///         propagating).
    function test_balanceOf_debtReadFailureOnTrackedBorrower_reverts() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_7D);
        _grantSubstrate(address(t.servicer));

        // Tracked exposure: lock collateral so prior collateral > 0 → the debt-read failure
        // gate fires.
        address[] memory accepted = new address[](1);
        accepted[0] = address(t.purchaseToken);
        t.collateralManager.setAcceptedTokens(accepted);
        t.collateralManager.setSkipPull(true);
        vm.prank(address(vault));
        t.collateralManager.externalLockCollateral(address(t.purchaseToken), 1_000_000);

        // Make `getBorrowerRepurchaseObligation` revert.
        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("getBorrowerRepurchaseObligation(address)", address(vault)),
            bytes("debt-fail")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtReadFailedForTrackedServicer.selector,
                address(t.servicer)
            )
        );
        vault.delegateBalanceOf(address(fuse));
    }

    /// @notice REGRESSION follow-up: under the production delegatecall topology,
    ///         an UNTRACKED servicer with a broken `termRepoCollateralManager()` proxy MUST
    ///         degrade to a zero NAV contribution — NOT revert. This pins the
    ///         "single broken leg degrades to 0 under delegatecall" invariant on the very
    ///         first foreign call in `_signedValueForServicerInternal`, the one that gates
    ///         the rest of the servicer-side aggregation.
    /// @dev The servicer is intentionally UNTRACKED — no locked collateral, no pending bids,
    ///      no held repo tokens — so there is no exposure that would justify propagating any
    ///      revert (the `DebtReadFailedForTrackedServicer` revert gate cannot fire because
    ///      `priorCollateralValue == 0` and `_hasTrackedExposure(servicer) == false`).
    ///      The delegatecall boundary is the load-bearing piece: before the fix the fuse issued
    ///      `try this.signedValueForServicer(...)` which under this topology hits the
    ///      vault's selector dispatch (no fallback in `MinimalPlasmaVaultHarness`), reverts,
    ///      and the outer catch swallowed every leg uniformly. After the fix each foreign call
    ///      is locally wrapped in try/catch at the call site — the broken
    ///      `termRepoCollateralManager()` returns `(false, address(0))` from
    ///      `_tryReadCollateralManager` and the leg short-circuits to `return 0` BEFORE any
    ///      collateral / debt math runs.
    function test_balanceOf_untrackedServicerBrokenProxy_degradesToZeroUnderDelegatecall() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));

        // Verify the no-exposure precondition: substrate has no held repo tokens, no locked
        // collateral, no pending bids tracked in storage. The mock servicer starts clean and
        // we never seed any of those signals.
        assertEq(t.repoToken.balanceOf(address(vault)), 0, "precondition: no held repo tokens");
        assertEq(
            t.collateralManager.getCollateralBalance(address(vault), address(t.purchaseToken)),
            0,
            "precondition: no locked collateral"
        );

        // Break the very first foreign call: `termRepoCollateralManager()` reverts. The fuse
        // routes through `_tryReadCollateralManager` which returns `(false, address(0))` and
        // `_signedValueForServicerInternal` short-circuits to `return 0`.
        vm.mockCallRevert(
            address(t.servicer),
            abi.encodeWithSignature("termRepoCollateralManager()"),
            bytes("cm-proxy-broken")
        );

        uint256 nav = vault.delegateBalanceOf(address(fuse));
        assertEq(nav, 0, "untracked servicer with broken proxy must degrade to 0 NAV");
    }

    /// @notice REGRESSION: under the production delegatecall topology, an
    ///         UNTRACKED servicer whose purchase-token oracle is broken (returns price 0)
    ///         must degrade to a zero NAV contribution — NOT revert. Mirrors the unit-test
    ///         `testBalanceFuseDegradesLegToZeroWhenPurchaseTokenPriceIsZero_untracked` but
    ///         under the production `vault.functionDelegateCall(fuse, ...)` topology so the
    ///         delegatecall boundary is the load-bearing piece.
    function test_balanceOf_untrackedServicerOracleZero_degradesToZeroUnderDelegatecall() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));

        // No held repo tokens, no pending offers, no pending bids, no locked collateral —
        // fully untracked. Wipe the purchase-token oracle to simulate a broken / unset feed.
        oracle.setAssetPrice(address(t.purchaseToken), 0, 8);

        uint256 nav = vault.delegateBalanceOf(address(fuse));
        assertEq(nav, 0, "untracked oracle-zero must degrade under delegatecall");
    }

    /// @notice REGRESSION: under the production delegatecall topology, a TRACKED
    ///         servicer (held repo position > 0) whose purchase-token oracle returns 0 must
    ///         re-raise `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer)`.
    ///         Validates that the gated revert routes correctly through the delegatecall
    ///         boundary (the `Address.functionDelegateCall` helper rethrows the inner
    ///         selector unchanged via assembly).
    function test_balanceOf_trackedServicerOracleZero_revertsUnderDelegatecall() public {
        Term memory t = _deployUsdcTerm(block.timestamp + SECS_28D);
        _grantSubstrate(address(t.servicer));

        // Tracked exposure: held repo position lives on the VAULT.
        t.repoToken.mint(address(vault), 1_000_000);
        t.repoToken.setRedemptionValue(1_003_889e12);

        oracle.setAssetPrice(address(t.purchaseToken), 0, 8);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(t.servicer)
            )
        );
        vault.delegateBalanceOf(address(fuse));
    }
}
