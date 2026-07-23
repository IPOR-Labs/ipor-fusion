// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "contracts/libraries/IporFusionMarkets.sol";
import {IExtTermAuctionOfferLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionOfferLocker.sol";
import {IExtTermController} from "contracts/fuses/term_finance/ext/IExtTermController.sol";
import {IExtTermDiscountRateAdapter} from "contracts/fuses/term_finance/ext/IExtTermDiscountRateAdapter.sol";
import {IExtTermRepoServicer} from "contracts/fuses/term_finance/ext/IExtTermRepoServicer.sol";
import {IExtTermRepoToken} from "contracts/fuses/term_finance/ext/IExtTermRepoToken.sol";

import {TermFinanceBalanceFuseHarness} from "../../unitTest/fuses/term_finance/mocks/TermFinanceBalanceFuseHarness.sol";

/// @title TermFinanceLiveBalanceFork
/// @notice Fork test against live Ethereum mainnet: validates that
///         (a) the ext interface ABIs match the deployed Term Finance contracts,
///         (b) the BalanceFuse PV math is consistent with on-chain redemptionValue and adapter rate,
///         (c) `balanceOf` is staticcall-safe on real proxies.
contract TermFinanceLiveBalanceFork is Test {
    // Evergreen contracts on Ethereum mainnet.
    address constant TERM_CONTROLLER = 0x21FC7B250CCAeECDb2abb38e04617D1f24D98772;
    address constant ADAPTER_B = 0x3C6b0398eEd7dAfcb3C13d482400329a6e25Acd2;

    // Live USDC Term Repo at the pinned block (probed 2026-05-15, block 25097999).
    // Servicer / RepoToken / Locker addresses verified live via `cast call`.
    address constant SERVICER = 0x11951C559cBA31E83f8032cFF4bd854eA0228657;
    address constant REPO_TOKEN = 0x347220087c69656AD3590200E1ea4Eafe842FD2E;
    address constant TERM_REPO_LOCKER = 0xb3565AD9ABdE6BFCdc0a8BB28C890329B938B545;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // PlasmaVault price oracle middleware (Ethereum production).
    // Use a minimal mock so we don't depend on the production oracle's USDC entry.
    address oracle;
    TermFinanceBalanceFuseHarness harness;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 25097999);

        // Deploy a tiny mock oracle that returns USDC = $1, 8 dec.
        MockOracle mock = new MockOracle();
        mock.setAssetPrice(USDC, 1e8, 8);
        oracle = address(mock);

        harness = new TermFinanceBalanceFuseHarness(
            IporFusionMarkets.TERM_FINANCE,
            TERM_CONTROLLER,
            ADAPTER_B
        );
        harness.setPriceOracleMiddleware(oracle);

        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(SERVICER);
        harness.setMarketSubstrates(IporFusionMarkets.TERM_FINANCE, subs);
    }

    /// @notice ABI sanity: ensure every getter we call returns a sensible value live.
    function test_liveAbis_areCompatible() public view {
        assertTrue(IExtTermController(TERM_CONTROLLER).isTermDeployed(SERVICER), "servicer registered");
        assertEq(IExtTermRepoServicer(SERVICER).termRepoToken(), REPO_TOKEN);
        assertEq(IExtTermRepoServicer(SERVICER).termRepoLocker(), TERM_REPO_LOCKER);
        assertEq(IExtTermRepoServicer(SERVICER).purchaseToken(), USDC);
        assertGt(IExtTermRepoServicer(SERVICER).redemptionTimestamp(), block.timestamp, "future maturity");
        assertEq(IExtTermRepoServicer(SERVICER).shortfallHaircutMantissa(), 0, "no shortfall on live market");

        assertEq(IExtTermRepoToken(REPO_TOKEN).decimals(), 6, "USDC term repo: 6 decimals");
        assertEq(IExtTermRepoToken(REPO_TOKEN).redemptionValue(), 1e18, "redemptionValue is 18-dec mantissa");
        assertGt(uint256(IExtTermRepoToken(REPO_TOKEN).termRepoId()), 0, "non-zero termRepoId");

        assertGt(IExtTermDiscountRateAdapter(ADAPTER_B).getDiscountRate(REPO_TOKEN), 0, "adapter rate > 0");
        assertEq(IExtTermDiscountRateAdapter(ADAPTER_B).currTermController(), TERM_CONTROLLER);
    }

    /// @notice BalanceFuse returns zero when vault holds no repoToken and has no pending offers.
    function test_balanceOf_zeroState() public view {
        assertEq(harness.balanceOf(), 0);
    }

    /// @notice Hold 100k repoToken in the vault, compute PV, and cross-check against manual math.
    function test_balanceOf_heldRepoToken_pvMatchesManualCalc() public {
        // Deal 100k repoTokens (6-dec) to the harness as if the vault held them.
        uint256 repoBal = 100_000 * 1e6;
        deal(REPO_TOKEN, address(harness), repoBal);

        uint256 nav = harness.balanceOf();

        // Manual recomputation:
        uint256 redValue = IExtTermRepoToken(REPO_TOKEN).redemptionValue();
        uint256 tred = IExtTermRepoServicer(SERVICER).redemptionTimestamp();
        uint256 secondsToMaturity = tred - block.timestamp;
        uint256 rate = IExtTermDiscountRateAdapter(ADAPTER_B).getDiscountRate(REPO_TOKEN);
        uint256 adapterHcut = IExtTermDiscountRateAdapter(ADAPTER_B).repoRedemptionHaircut(REPO_TOKEN);

        // face = repoBal * redValue * purchasePrec / (repoTokenPrec * 1e18) = repoBal * redValue / 1e18
        // (because repoTokenPrec == purchasePrec == 1e6 here)
        uint256 face = (repoBal * redValue) / 1e18;
        uint256 effRate = (rate * (1e18 + adapterHcut)) / 1e18;
        uint256 dayFrac = (secondsToMaturity * 1e6) / (360 * 86_400);
        uint256 divisor = 1e6 + (effRate * dayFrac) / 1e18;
        uint256 pvInPurchase = (face * 1e6) / divisor;

        // Convert to WAD-USD with price = 1e8 (8 dec) and asset = 6 dec.
        uint256 expectedWad = pvInPurchase * 1e8 * 1e4; // = pvInPurchase * 1e12

        assertApproxEqRel(nav, expectedWad, 1e15, "live PV within 0.1%");
    }

    /// @notice `balanceOf` must remain staticcall-safe even when reading live proxies.
    function test_balanceOf_isStaticcallSafe_onLive() public {
        deal(REPO_TOKEN, address(harness), 100_000 * 1e6);

        (bool ok, bytes memory ret) = address(harness).staticcall(abi.encodeWithSignature("balanceOf()"));
        assertTrue(ok, "balanceOf must be staticcall-safe against live contracts");
        uint256 nav = abi.decode(ret, (uint256));
        assertGt(nav, 0, "non-zero balance");
    }
}

contract MockOracle {
    mapping(address => uint256) private _price;
    mapping(address => uint256) private _dec;

    function setAssetPrice(address asset_, uint256 price_, uint256 dec_) external {
        _price[asset_] = price_;
        _dec[asset_] = dec_;
    }

    function getAssetPrice(address asset_) external view returns (uint256, uint256) {
        return (_price[asset_], _dec[asset_]);
    }
}
