// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TermFinanceBalanceFuse} from "contracts/fuses/term_finance/TermFinanceBalanceFuse.sol";
import {TermFinanceSubstrateLib} from "contracts/fuses/term_finance/lib/TermFinanceSubstrateLib.sol";
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

/// @title TermFinanceBalanceFuseServicerFloorTest
/// @notice IL-9553: every servicer (Term Repo) of market 52 is valued on its own. A default seizes only the
///         collateral locked in that servicer's collateral manager, so a servicer is worth its pending offers and
///         pending bid collateral plus `max(0, own repo-token PV + locked collateral - debt PV)`. An underwater
///         servicer contributes 0: it neither lowers the value of the other servicers nor reverts `balanceOf`.
/// @dev Runs `balanceOf` on the harness (inherits the fuse, so `address(this)` is the vault as under the
///      PlasmaVault delegatecall). All amounts are USDC (6 decimals) priced at 1 USD; repo tokens have redemption
///      value 1e18 and the default adapter rate is 0, so PV equals face before and after maturity.
contract TermFinanceBalanceFuseServicerFloorTest is Test {
    uint256 internal constant MARKET_ID = 52;
    uint256 internal constant USDC = 1e6;
    /// @dev Per-servicer saturation bound of the fuse (`MAX_VALUE_PER_LEG_UINT`).
    uint256 internal constant MAX_VALUE_PER_LEG = 1e36;

    TermFinanceBalanceFuseHarness internal harness;
    MockTermController internal controller;
    MockTermDiscountRateAdapter internal adapter;
    MockPriceOracleMiddlewareForTermFinance internal oracle;
    uint256 internal tred;

    struct Term {
        MockTermRepoServicer servicer;
        MockTermRepoToken repoToken;
        MockTermAuctionOfferLocker offerLocker;
        MockTermRepoCollateralManager collateralManager;
        MockERC20Decimals purchaseToken;
    }

    function setUp() public {
        controller = new MockTermController();
        adapter = new MockTermDiscountRateAdapter();
        oracle = new MockPriceOracleMiddlewareForTermFinance();
        harness = new TermFinanceBalanceFuseHarness(MARKET_ID, address(controller), address(adapter));
        harness.setPriceOracleMiddleware(address(oracle));
        tred = block.timestamp + 7 days;
    }

    // ============ underwater servicer next to a lender servicer ============

    /// @notice Criterion 4, freeze case: X (locked 250k, debt 300k) next to Y (repo tokens 40k). The vault is
    ///         worth the 40k of Y; on the base the signed total of -10k reverted and froze market 52.
    function test_underwaterServicerNextToLender_returnsLenderOnly() public {
        Term memory x = _underwaterX();
        Term memory y = _deployTerm();
        _repoTokens(y, 40_000 * USDC);
        _grant2(x, false, y, true);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(40_000 * USDC), "X floors at 0, Y counts in full");
    }

    /// @notice Same freeze case before maturity (the window in which a margin call needs collateral top-ups).
    function test_underwaterServicerNextToLender_preMaturity_returnsLenderOnly() public {
        Term memory x = _underwaterX();
        Term memory y = _deployTerm();
        _repoTokens(y, 40_000 * USDC);
        _grant2(x, false, y, true);

        assertEq(harness.balanceOf(), _wad(40_000 * USDC), "X floors at 0 before maturity too");
    }

    /// @notice Criterion 4, understatement case: X next to Y (repo tokens 1.0M) is worth 1.0M, not 950k.
    function test_underwaterServicerNextToLargeLender_isNotNetted() public {
        Term memory x = _underwaterX();
        Term memory y = _deployTerm();
        _repoTokens(y, 1_000_000 * USDC);
        _grant2(x, false, y, true);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(1_000_000 * USDC), "X's shortfall is not charged to Y");
    }

    /// @notice The only servicer is underwater: 0, no revert.
    function test_onlyServicerUnderwater_returnsZero() public {
        Term memory x = _underwaterX();
        _grant1(x, false);
        _toPostMaturity();

        assertEq(harness.balanceOf(), 0, "underwater servicer alone -> 0");
    }

    /// @notice Two underwater servicers next to a lender: only the lender counts.
    function test_twoUnderwaterServicersNextToLender_returnsLenderOnly() public {
        Term memory x1 = _underwaterX();
        Term memory x2 = _deployTerm();
        _debt(x2, 500_000 * USDC);
        Term memory y = _deployTerm();
        _repoTokens(y, 70_000 * USDC);
        _grant3(x1, x2, y);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(70_000 * USDC), "both underwater servicers floor at 0");
    }

    // ============ free legs of an underwater servicer ============

    /// @notice Pending offers and pending bid collateral are not seized by a default of the servicer's
    ///         obligation, so they stay counted next to an underwater credit leg (base: 250+30+20-300 = 0).
    function test_underwaterServicer_pendingOfferAndBidCollateralStayFree() public {
        Term memory x = _underwaterX();
        _pendingOffer(x, bytes32(uint256(0x0FF1)), 30_000 * USDC);
        _pendingBid(x, bytes32(uint256(0xB1D1)), 20_000 * USDC);
        _grant1(x, false);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(50_000 * USDC), "offer 30k + bid collateral 20k, credit leg 0");
    }

    // ============ own repo tokens in the same servicer (IL-9566 D-016) ============

    /// @notice Criterion 4 (D-016): X with its own repo tokens of the same servicer (100k) is netted inside X:
    ///         max(0, 100k + 250k - 300k) = 50k. The vault's residual debt would dilute the pool recovery of those
    ///         repo tokens, and before the window it can cancel debt with them at par (`burnCollapseExposure`).
    function test_underwaterServicerWithOwnRepoTokens_nettedInsideServicer() public {
        Term memory x = _underwaterX();
        _repoTokens(x, 100_000 * USDC);
        _grant1(x, true);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(50_000 * USDC), "own repo tokens join the credit leg");
    }

    /// @notice D-016 with free legs: own repo 100k + locked 250k < debt 400k, plus offer 30k and bid collateral
    ///         20k. The credit leg floors at 0 and the pending legs stay (base: 100+250+30+20-400 = 0).
    function test_ownRepoTokensUnderwater_pendingLegsStayFree() public {
        Term memory x = _deployTerm();
        _lock(x, 250_000 * USDC);
        _debt(x, 400_000 * USDC);
        _repoTokens(x, 100_000 * USDC);
        _pendingOffer(x, bytes32(uint256(0x0FF2)), 30_000 * USDC);
        _pendingBid(x, bytes32(uint256(0xB1D2)), 20_000 * USDC);
        _grant1(x, true);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(50_000 * USDC), "pending legs only, credit leg floors at 0");
    }

    /// @notice D-016, own repo tokens alone cover the debt: 500k - 300k = 200k (unchanged).
    function test_ownRepoTokensCoverDebt_returnsNet() public {
        Term memory x = _deployTerm();
        _debt(x, 300_000 * USDC);
        _repoTokens(x, 500_000 * USDC);
        _grant1(x, true);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(200_000 * USDC), "repo 500k - debt 300k");
    }

    // ============ healthy configurations are unchanged ============

    /// @notice Healthy borrower: locked 1.1M, debt 1.0M -> 0.1M.
    function test_healthyBorrower_unchanged() public {
        Term memory x = _deployTerm();
        _lock(x, 1_100_000 * USDC);
        _debt(x, 1_000_000 * USDC);
        _grant1(x, false);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(100_000 * USDC), "collateral 1.1M - debt 1.0M");
    }

    /// @notice Healthy servicer with every leg: repo 2M + locked 1.1M - debt 1.0M + offer 50k + bid 20k = 2.17M.
    function test_healthyServicerAllLegs_unchanged() public {
        Term memory x = _deployTerm();
        _lock(x, 1_100_000 * USDC);
        _debt(x, 1_000_000 * USDC);
        _repoTokens(x, 2_000_000 * USDC);
        _pendingOffer(x, bytes32(uint256(0x0FF3)), 50_000 * USDC);
        _pendingBid(x, bytes32(uint256(0xB1D3)), 20_000 * USDC);
        _grant1(x, true);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(2_170_000 * USDC), "all legs of a healthy servicer");
    }

    /// @notice Healthy borrower next to a lender: 0.1M + 2M.
    function test_healthyBorrowerNextToLender_unchanged() public {
        Term memory x = _deployTerm();
        _lock(x, 1_100_000 * USDC);
        _debt(x, 1_000_000 * USDC);
        Term memory y = _deployTerm();
        _repoTokens(y, 2_000_000 * USDC);
        _grant2(x, false, y, true);
        _toPostMaturity();

        assertEq(harness.balanceOf(), _wad(2_100_000 * USDC), "0.1M + 2M");
    }

    // ============ saturation ============

    /// @notice The per-servicer value saturates at `MAX_VALUE_PER_LEG` and the sum is unsigned: a saturated
    ///         servicer next to an underwater one reports exactly the bound (base: bound - 50k).
    function test_saturatedServicerNextToUnderwater_returnsBound() public {
        Term memory x = _underwaterX();
        Term memory y = _deployTerm();
        _lock(y, 1e25); // 1e25 raw USDC = 1e37 WAD-USD, above the bound
        _grant2(x, false, y, false);
        _toPostMaturity();

        assertEq(harness.balanceOf(), MAX_VALUE_PER_LEG, "saturated leg + 0");
    }

    // ============ fail-closed gates still fire on an underwater servicer ============

    /// @notice Oracle failure on the underwater servicer's locked collateral (tracked) still freezes NAV.
    function test_gate_priceZeroOnUnderwaterServicer_reverts() public {
        (Term memory x, ) = _underwaterNextToHealthy();
        oracle.setAssetPrice(address(x.purchaseToken), 0, 8);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector,
                address(x.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice A reverting offer locker for a tracked pending offer of the underwater servicer still freezes NAV.
    function test_gate_lockerReadFailedOnUnderwaterServicer_reverts() public {
        Term memory x = _underwaterX();
        bytes32 offerId = bytes32(uint256(0x0FF4));
        _pendingOffer(x, offerId, 30_000 * USDC);
        Term memory y = _deployTerm();
        _repoTokens(y, 1_000_000 * USDC);
        _grant2(x, false, y, true);
        _toPostMaturity();
        x.offerLocker.setLockedOfferReverts(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseLockerReadFailedForTrackedEntry.selector,
                address(x.offerLocker),
                offerId
            )
        );
        harness.balanceOf();
    }

    /// @notice A failed debt read on the underwater servicer (locked collateral tracked) still freezes NAV.
    function test_gate_debtReadFailedOnUnderwaterServicer_reverts() public {
        (Term memory x, ) = _underwaterNextToHealthy();
        vm.mockCallRevert(
            address(x.servicer),
            abi.encodeWithSignature("getBorrowerRepurchaseObligation(address)", address(harness)),
            bytes("debt read fails")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtReadFailedForTrackedServicer.selector,
                address(x.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice A failed discount-rate read for the underwater servicer's debt PV still freezes NAV.
    function test_gate_debtRateFailedOnUnderwaterServicer_reverts() public {
        (Term memory x, ) = _underwaterNextToHealthy();
        vm.mockCallRevert(
            address(adapter),
            abi.encodeWithSignature("getDiscountRate(address)", address(x.repoToken)),
            bytes("rate read fails")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseDebtRateFailedForTrackedServicer.selector,
                address(x.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice A failed collateral-manager probe on the underwater servicer (positive debt) still freezes NAV.
    function test_gate_collateralManagerReadFailedOnUnderwaterServicer_reverts() public {
        (Term memory x, ) = _underwaterNextToHealthy();
        vm.mockCallRevert(
            address(x.servicer),
            abi.encodeWithSignature("termRepoCollateralManager()"),
            bytes("cm read fails")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseCollateralManagerReadFailedForTrackedServicer.selector,
                address(x.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice A non-zero adapter redemption haircut on the underwater servicer's own held repo tokens (before
    ///         maturity) still freezes NAV.
    function test_gate_nonZeroRepoRedemptionHaircutOnUnderwaterServicer_reverts() public {
        Term memory x = _deployTerm();
        _lock(x, 250_000 * USDC);
        _debt(x, 400_000 * USDC);
        _repoTokens(x, 100_000 * USDC);
        Term memory y = _deployTerm();
        _repoTokens(y, 1_000_000 * USDC);
        _grant2(x, true, y, true);
        adapter.setHaircut(address(x.repoToken), 5e16);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFuseNonZeroRepoRedemptionHaircut.selector,
                address(x.servicer)
            )
        );
        harness.balanceOf();
    }

    /// @notice A missing price oracle middleware still reverts with `Errors.WrongAddress`.
    function test_gate_missingPriceOracleMiddleware_reverts() public {
        _underwaterNextToHealthy();
        harness.setPriceOracleMiddleware(address(0));

        vm.expectRevert(Errors.WrongAddress.selector);
        harness.balanceOf();
    }

    // ============ helpers ============

    function _wad(uint256 usdcRaw_) internal pure returns (uint256) {
        // price 1e8 with 8 decimals, token 6 decimals -> WAD-USD = raw * 1e12
        return usdcRaw_ * 1e12;
    }

    function _toPostMaturity() internal {
        vm.warp(tred + 1 hours);
    }

    function _deployTerm() internal returns (Term memory t) {
        t.purchaseToken = new MockERC20Decimals("USD Coin", "USDC", 6);
        t.repoToken = new MockTermRepoToken("TermRepoToken", "TRT", 6);
        t.offerLocker = new MockTermAuctionOfferLocker();
        t.collateralManager = new MockTermRepoCollateralManager();
        t.servicer = new MockTermRepoServicer();
        address repoLocker = makeAddr("termRepoLocker");

        t.servicer.setTermRepoToken(address(t.repoToken));
        t.servicer.setTermRepoLocker(repoLocker);
        t.servicer.setTermRepoCollateralManager(address(t.collateralManager));
        t.servicer.setPurchaseToken(address(t.purchaseToken));
        t.servicer.setRedemptionTimestamp(tred);
        t.servicer.setMaturityTimestamp(tred);
        t.servicer.setEndOfRepurchaseWindow(tred);

        t.offerLocker.setTermRepoServicer(address(t.servicer));
        t.offerLocker.setTermRepoLocker(repoLocker);
        t.offerLocker.setPurchaseToken(address(t.purchaseToken));

        t.collateralManager.setTermRepoLocker(repoLocker);
        t.collateralManager.setAcceptedTokens(new address[](0));

        controller.setIsTermDeployed(address(t.servicer), true);
        oracle.setAssetPrice(address(t.purchaseToken), 1e8, 8);
    }

    /// @dev Servicer X of criterion 4: locked collateral 250k, debt 300k, no other position.
    function _underwaterX() internal returns (Term memory x) {
        x = _deployTerm();
        _lock(x, 250_000 * USDC);
        _debt(x, 300_000 * USDC);
    }

    /// @dev Underwater X (servicer only) next to a healthy lender Y (repo tokens 1.0M), after maturity.
    function _underwaterNextToHealthy() internal returns (Term memory x, Term memory y) {
        x = _underwaterX();
        y = _deployTerm();
        _repoTokens(y, 1_000_000 * USDC);
        _grant2(x, false, y, true);
        _toPostMaturity();
    }

    /// @dev Locks `amount_` of the purchase token (accepted as collateral) for the vault in `t_`.
    function _lock(Term memory t_, uint256 amount_) internal {
        address[] memory accepted = new address[](1);
        accepted[0] = address(t_.purchaseToken);
        t_.collateralManager.setAcceptedTokens(accepted);
        t_.collateralManager.setSkipPull(true);
        vm.prank(address(harness));
        t_.collateralManager.externalLockCollateral(address(t_.purchaseToken), amount_);
    }

    function _debt(Term memory t_, uint256 amount_) internal {
        t_.servicer.setBorrowerRepurchaseObligation(address(harness), amount_);
    }

    /// @dev Repo tokens with redemption value 1e18, so face == balance (same decimals as the purchase token).
    function _repoTokens(Term memory t_, uint256 amount_) internal {
        t_.repoToken.mint(address(harness), amount_);
        t_.repoToken.setRedemptionValue(1e18);
    }

    function _pendingOffer(Term memory t_, bytes32 id_, uint256 amount_) internal {
        t_.offerLocker.setLockedOffer(
            id_,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: id_,
                offeror: address(harness),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: amount_,
                purchaseToken: address(t_.purchaseToken),
                isRevealed: false
            })
        );
        harness.addPendingOffer(address(t_.servicer), address(t_.offerLocker), id_, amount_);
    }

    /// @dev Live pending bid whose locked collateral is `collateral_` of the purchase token.
    function _pendingBid(Term memory t_, bytes32 id_, uint256 collateral_) internal {
        MockTermAuctionBidLocker locker = new MockTermAuctionBidLocker();
        locker.setTermRepoServicer(address(t_.servicer));
        locker.setPurchaseToken(address(t_.purchaseToken));
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(t_.purchaseToken);
        amounts[0] = collateral_;
        locker.setLockedBid(
            id_,
            IExtTermAuctionBidLocker.TermAuctionBid({
                id: id_,
                bidder: address(harness),
                bidPriceHash: bytes32(0),
                bidPriceRevealed: 0,
                amount: collateral_,
                collateralAmounts: amounts,
                purchaseToken: address(t_.purchaseToken),
                collateralTokens: tokens,
                isRollover: false,
                rolloverPairOffTermRepoServicer: address(0),
                isRevealed: false
            })
        );
        harness.addPendingBid(address(t_.servicer), address(locker), id_, collateral_, tokens, amounts);
    }

    /// @dev SERVICER substrate, plus REPO_TOKEN_HOLDING when `hold_`.
    function _grant1(Term memory a_, bool hold_) internal {
        bytes32[] memory subs = new bytes32[](hold_ ? 2 : 1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(a_.servicer));
        if (hold_) subs[1] = TermFinanceSubstrateLib.repoTokenHoldingKey(address(a_.servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);
    }

    function _grant2(Term memory a_, bool holdA_, Term memory b_, bool holdB_) internal {
        bytes32[] memory subs = new bytes32[](2 + (holdA_ ? 1 : 0) + (holdB_ ? 1 : 0));
        uint256 i;
        subs[i++] = PlasmaVaultConfigLib.addressToBytes32(address(a_.servicer));
        subs[i++] = PlasmaVaultConfigLib.addressToBytes32(address(b_.servicer));
        if (holdA_) subs[i++] = TermFinanceSubstrateLib.repoTokenHoldingKey(address(a_.servicer));
        if (holdB_) subs[i++] = TermFinanceSubstrateLib.repoTokenHoldingKey(address(b_.servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);
    }

    /// @dev Two borrower-only servicers and one lender servicer (with REPO_TOKEN_HOLDING).
    function _grant3(Term memory a_, Term memory b_, Term memory lender_) internal {
        bytes32[] memory subs = new bytes32[](4);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(a_.servicer));
        subs[1] = PlasmaVaultConfigLib.addressToBytes32(address(b_.servicer));
        subs[2] = PlasmaVaultConfigLib.addressToBytes32(address(lender_.servicer));
        subs[3] = TermFinanceSubstrateLib.repoTokenHoldingKey(address(lender_.servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);
    }
}
