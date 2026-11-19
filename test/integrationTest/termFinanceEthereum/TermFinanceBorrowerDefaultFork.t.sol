// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IExtTermRepoCollateralManager} from "contracts/fuses/term_finance/ext/IExtTermRepoCollateralManager.sol";
import {IExtTermRepoServicer} from "contracts/fuses/term_finance/ext/IExtTermRepoServicer.sol";
import {TermFinanceSubstrateLib} from "contracts/fuses/term_finance/lib/TermFinanceSubstrateLib.sol";

import {TermFinanceBalanceFuseHarness} from "../../unitTest/fuses/term_finance/mocks/TermFinanceBalanceFuseHarness.sol";
import {MockOracle} from "./TermFinanceBorrowerFork.t.sol";

/// @title TermFinanceBorrowerDefaultFork
/// @notice Fork test of a real `batchDefault` on the live Term borrower (IL-9553). It warps past the servicer's
///         redemption timestamp, so it runs on its own fork block (different from `TermFinanceBorrowerFork` and
///         `TermFinanceLiveBalanceFork`): suites with the same fork URL and block share one forge backend, and a
///         `vm.warp` would leak into them.
/// @dev The two Term-side calls without a production interface (`batchDefault`, the two servicer counters and the
///      Term price feed `usdValueOfTokens`) are made by signature.
contract TermFinanceBorrowerDefaultFork is Test {
    address private constant TERM_CONTROLLER = 0x21FC7B250CCAeECDb2abb38e04617D1f24D98772;
    address private constant ADAPTER_B = 0x3C6b0398eEd7dAfcb3C13d482400329a6e25Acd2;
    address private constant SERVICER = 0x11951C559cBA31E83f8032cFF4bd854eA0228657;
    address private constant REPO_TOKEN = 0x347220087c69656AD3590200E1ea4Eafe842FD2E;
    address private constant TERM_REPO_LOCKER = 0xb3565AD9ABdE6BFCdc0a8BB28C890329B938B545;
    address private constant COLLATERAL_MANAGER = 0x9b00ee0b1cE01f74B1d18fAc682D4c9A3077C7d3;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant PT_REUSD = 0x3EAA0F0f0A5d3D595ae4e4b0D27f439d01c3E7b2;
    address private constant LIVE_BORROWER = 0x3976747B82316020A15662761C82860B9785e7f3;

    /// @dev `TermPriceConsumerV3` of the live collateral manager (proxy storage slot 258).
    address private constant TERM_PRICE_ORACLE = 0x04fCd15C3582F0Fa81a46533795196a5257f79C8;

    uint256 private constant MARKET_ID = 49;
    /// @dev Own fork block, distinct from the other Term fork suites (they pin 25097999).
    uint256 private constant FORK_BLOCK = 25096999;

    MockOracle private oracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);
        oracle = new MockOracle();
        oracle.setAssetPrice(USDC, 1e8, 8);
        oracle.setAssetPrice(PT_REUSD, 1e8, 8);
    }

    /// @dev Preconditions of the default test at this block (live borrower, debt and locked collateral exist).
    function testForkDefaultPreconditionsHoldAtOwnBlock() public view {
        assertGt(
            IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER),
            0,
            "live borrower has debt"
        );
        assertGt(
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD),
            0,
            "live borrower has locked collateral"
        );
    }

    /// @dev Reads a no-argument `uint256` view of the live servicer by signature.
    function _servicerCounter(string memory signature_) private view returns (uint256 value) {
        (bool ok, bytes memory ret) = SERVICER.staticcall(abi.encodeWithSignature(signature_));
        assertTrue(ok, "servicer counter read");
        value = abi.decode(ret, (uint256));
    }

    function _newBalanceHarness(bytes32[] memory subs_) private returns (TermFinanceBalanceFuseHarness harness) {
        harness = new TermFinanceBalanceFuseHarness(MARKET_ID, TERM_CONTROLLER, ADAPTER_B);
        harness.setMarketSubstrates(MARKET_ID, subs_);
        harness.setPriceOracleMiddleware(address(oracle));
    }

    function _substratesX() private pure returns (bytes32[] memory subs) {
        subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(SERVICER);
        subs[1] = TermFinanceSubstrateLib.collateralPairKey(SERVICER, PT_REUSD);
    }

    /// @dev Etches a balance harness at the live borrower with the given substrates.
    function _etchBalanceHarnessWithSubstrates(bytes32[] memory subs_) private returns (TermFinanceBalanceFuseHarness) {
        TermFinanceBalanceFuseHarness shadow = new TermFinanceBalanceFuseHarness(MARKET_ID, TERM_CONTROLLER, ADAPTER_B);
        vm.etch(LIVE_BORROWER, address(shadow).code);
        TermFinanceBalanceFuseHarness(LIVE_BORROWER).setMarketSubstrates(MARKET_ID, subs_);
        TermFinanceBalanceFuseHarness(LIVE_BORROWER).setPriceOracleMiddleware(address(oracle));
        return TermFinanceBalanceFuseHarness(LIVE_BORROWER);
    }

    /// @notice A real default of the live borrower after the repurchase window. The Term-side price
    ///         feed is mocked (the only way to make the live loan underwater at a frozen block), so the liquidator
    ///         seizes ALL locked collateral for ~half of the debt. The residual stays outstanding and no collateral
    ///         stays encumbered, so the servicer redeems pro rata. Proves: batchDefault leaves repo tokens untouched; the borrower's NAV does
    ///         not rise; the repo token leg is valued at face x recovery (before the first redemption through the
    ///         repurchase counters, after it through `shortfallHaircutMantissa`), not at face.
    function testForkRealBatchDefaultLeavesRepoTokensAndValuesThemAtRecovery() public {
        uint256 debt = IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER);
        uint256 closure = debt / 2;

        // Holder of repo tokens of X (no debt) and the borrower vault (underwater below).
        TermFinanceBalanceFuseHarness holder = _newHolderOfRepoTokens(HELD_FACE);
        TermFinanceBalanceFuseHarness borrowerVault = _etchBalanceHarnessWithSubstrates(_substratesX());

        _makeUnderwaterAndWarpToRedemption(closure);

        // Before the default: the borrower is underwater, the holder's repo tokens are worth nothing because
        // nothing has been collected yet (recovery = 0 / (0 + outstanding)).
        assertEq(borrowerVault.balanceOf(), 0, "borrower underwater before the default");
        assertEq(holder.balanceOf(), 0, "nothing collected yet: recovery 0");
        assertEq(IExtTermRepoServicer(SERVICER).shortfallHaircutMantissa(), 0, "mantissa unset before any redemption");

        _batchDefaultByLiquidator(closure);
        _assertDefaultSeizedCollateralOnly(debt, closure, address(holder));
        assertEq(borrowerVault.balanceOf(), 0, "borrower NAV does not rise after the default");

        // Repo token leg after the default, before any redemption: recovery from the two counters.
        assertEq(holder.balanceOf(), ((HELD_FACE * ((closure * 1e18) / debt)) / 1e18) * 1e12, "face x counters ratio");

        // First redemption by a third party sets Term's own mantissa.
        _redeemByThirdParty(1_000 * 1e6);
        uint256 mantissa = IExtTermRepoServicer(SERVICER).shortfallHaircutMantissa();
        assertEq(mantissa, (closure * 1e18) / debt, "Term sets the mantissa to collected / (collected + outstanding)");
        assertLt(mantissa, 1e18, "the mantissa is a recovery ratio below par");
        assertEq(IERC20(REPO_TOKEN).balanceOf(address(holder)), HELD_FACE, "the balance did not change");
        assertEq(holder.balanceOf(), ((HELD_FACE * mantissa) / 1e18) * 1e12, "face x shortfallHaircutMantissa");
        assertLt(holder.balanceOf(), HELD_FACE * 1e12, "an unchanged balance is worth less than face");
        assertEq(borrowerVault.balanceOf(), 0, "borrower NAV still zero after the redemption");
    }

    uint256 private constant HELD_FACE = 100_000 * 1e6;

    function _assertDefaultSeizedCollateralOnly(uint256 debt_, uint256 closure_, address holder_) private view {
        assertEq(
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD),
            0,
            "all collateral seized"
        );
        assertEq(
            IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER),
            debt_ - closure_,
            "residual stays outstanding"
        );
        assertEq(IERC20(REPO_TOKEN).balanceOf(holder_), HELD_FACE, "default does not seize repo tokens");
        assertEq(_servicerCounter("totalRepurchaseCollected()"), closure_, "the repayment was collected");
        assertEq(_servicerCounter("totalOutstandingRepurchaseExposure()"), debt_ - closure_, "residual exposure");
    }

    function _redeemByThirdParty(uint256 amount_) private {
        address redeemer = address(0xBEEF1);
        deal(REPO_TOKEN, redeemer, amount_);
        IExtTermRepoServicer(SERVICER).redeemTermRepoTokens(redeemer, amount_);
    }

    /// @dev Prices PT-reUSD in the Term feed (mocked) and in the fuse's oracle so that `closure_` seizes exactly the
    ///      borrower's locked collateral, then warps past the redemption timestamp.
    function _makeUnderwaterAndWarpToRedemption(uint256 closure_) private {
        uint256 locked = IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(
            LIVE_BORROWER,
            PT_REUSD
        );
        uint256 termPrice = _termPriceSeizingExactly(closure_, locked);
        oracle.setAssetPrice(PT_REUSD, termPrice, 18); // keep the fuse's oracle coherent with the Term-side price
        vm.warp(IExtTermRepoServicer(SERVICER).redemptionTimestamp() + 1);
        _mockTermPrices(closure_, termPrice);
    }

    /// @dev A third party repays `closure_` of the borrower's debt through the live `batchDefault`.
    function _batchDefaultByLiquidator(uint256 closure_) private {
        address liquidator = address(0xD1FA);
        deal(USDC, liquidator, closure_);
        vm.startPrank(liquidator);
        IERC20(USDC).approve(TERM_REPO_LOCKER, closure_);
        uint256[] memory closures = new uint256[](1);
        closures[0] = closure_;
        (bool ok, bytes memory ret) = COLLATERAL_MANAGER.call(
            abi.encodeWithSignature("batchDefault(address,uint256[])", LIVE_BORROWER, closures)
        );
        assertTrue(ok, string(ret));
        vm.stopPrank();
    }

    /// @dev Replicates the collateral manager's seizure arithmetic (`_collateralSeizureAmounts`, 8 % liquidated
    ///      damages) to find the Term-side collateral price (18 dec) at which `closure_` seizes exactly `locked_`.
    function _termPriceSeizingExactly(uint256 closure_, uint256 locked_) private pure returns (uint256 price) {
        price = (closure_ * 1.08e18) / locked_;
        for (uint256 i; i < 2_000_000; ++i) {
            if (_seized(closure_, price) == locked_) return price;
            if (_seized(closure_, price) > locked_) price += 1;
            else price -= 1;
        }
        revert("no exact seizure price");
    }

    function _seized(uint256 closure_, uint256 price_) private pure returns (uint256) {
        uint256 ratio = (closure_ * 1e12 * 1e18) / price_;
        return ((ratio * 1.08e18) / 1e18) / 1e12;
    }

    /// @dev Mocks the two Term-side USD valuations `batchDefault` reads (USDC at par, PT-reUSD at `price_`).
    function _mockTermPrices(uint256 closure_, uint256 price_) private {
        vm.mockCall(
            TERM_PRICE_ORACLE,
            abi.encodeWithSignature("usdValueOfTokens(address,uint256)", USDC, closure_),
            abi.encode(closure_ * 1e12)
        );
        vm.mockCall(
            TERM_PRICE_ORACLE,
            abi.encodeWithSignature("usdValueOfTokens(address,uint256)", PT_REUSD, uint256(1e6)),
            abi.encode(price_)
        );
    }

    /// @dev Standalone vault holding `face_` repo tokens of X (REPO_TOKEN_HOLDING), without debt.
    function _newHolderOfRepoTokens(uint256 face_) private returns (TermFinanceBalanceFuseHarness holder) {
        bytes32[] memory subsHolder = new bytes32[](2);
        subsHolder[0] = PlasmaVaultConfigLib.addressToBytes32(SERVICER);
        subsHolder[1] = TermFinanceSubstrateLib.repoTokenHoldingKey(SERVICER);
        holder = _newBalanceHarness(subsHolder);
        deal(REPO_TOKEN, address(holder), face_);
    }
}
