// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CompoundV3WithPriceOracleMiddlewareBalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3WithPriceOracleMiddlewareBalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {
    CompoundV3BorrowFuse,
    CompoundV3BorrowFuseEnterData
} from "../../../contracts/fuses/compound_v3/CompoundV3BorrowFuse.sol";
import {
    CompoundV3SupplyFuse,
    CompoundV3SupplyFuseEnterData
} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/ext/IComet.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {FeeManager} from "../../../contracts/managers/fee/FeeManager.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";

import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

/// @notice Test-local declarations of Compound V3 Comet custom errors (not part of the production IComet interface)
interface ICometErrorsCompoundV3MiddlewareBalanceFuseTest {
    error BadAsset();
}

/// @title CompoundV3WithPriceOracleMiddlewareBalanceFuseTest
/// @notice Fork tests (Ethereum, block 25982679) of CompoundV3WithPriceOracleMiddlewareBalanceFuse running inside a real
///         PlasmaVault (governance, access manager, fee manager) with a real PriceOracleMiddleware (ERC1967 proxy) and the
///         real cUSDCv3 Comet. No mocks, no harnesses, no storage manipulation of protocol, oracle or vault state.
/// @dev Every expected value reproduces both stages of the valuation:
///      1. balance fuse: USD WAD value = sum(position x middleware price) - debt x middleware USDC price
///         (IporMath.convertToWadInt rounds half up for positive values),
///      2. PlasmaVaultMarketsLib.updateMarketsBalances: underlying = (usdWad * 10^priceDecimals / priceUnderlying)
///         truncated, then converted from WAD to 6 decimals (truncated).
contract CompoundV3WithPriceOracleMiddlewareBalanceFuseTest is Test {
    uint256 private constant FORK_BLOCK = 25982679;

    address private constant COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant CB_BTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address private constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant WST_ETH_USD_SOURCE = 0x4329e2178D41D058Cf2808c11436A9e83BC5D8b0;
    address private constant WBTC_USD_SOURCE = 0x106f9537Dd66423E6674e85CA187B43055B59fe9;
    /// @dev Chainlink DAI / USD aggregator (8 decimals), used only by the non-Comet-collateral test
    address private constant CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    uint256 private constant MARKET_ID = IporFusionMarkets.COMPOUND_V3_USDC;
    uint256 private constant ERC20_MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;

    /// @dev PlasmaVault.decimals() - PlasmaVaultLib.DECIMALS_OFFSET for a USDC vault
    uint256 private constant UNDERLYING_DECIMALS = 6;

    address private atomist;
    address private alpha;

    PlasmaVault private plasmaVault;
    IporFusionAccessManager private accessManager;
    PriceOracleMiddleware private priceOracleMiddleware;

    CompoundV3SupplyFuse private supplyFuse;
    CompoundV3BorrowFuse private borrowFuse;
    CompoundV3WithPriceOracleMiddlewareBalanceFuse private balanceFuse;
    ERC20BalanceFuse private erc20BalanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        atomist = makeAddr("atomist");
        alpha = makeAddr("alpha");

        priceOracleMiddleware = _deployMiddleware(CHAINLINK_FEED_REGISTRY);

        address[] memory assets = new address[](4);
        address[] memory sources = new address[](4);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;
        assets[1] = WETH;
        sources[1] = CHAINLINK_ETH_USD;
        assets[2] = WST_ETH;
        sources[2] = WST_ETH_USD_SOURCE;
        assets[3] = WBTC;
        sources[3] = WBTC_USD_SOURCE;
        // cbBTC: no explicit source, priced through the Chainlink Feed Registry fallback
        vm.prank(atomist);
        priceOracleMiddleware.setAssetsPricesSources(assets, sources);

        _deployVault();

        supplyFuse = new CompoundV3SupplyFuse(MARKET_ID, COMET);
        borrowFuse = new CompoundV3BorrowFuse(MARKET_ID, COMET);
        balanceFuse = new CompoundV3WithPriceOracleMiddlewareBalanceFuse(MARKET_ID, COMET);
        erc20BalanceFuse = new ERC20BalanceFuse(ERC20_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(borrowFuse);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = ERC20_MARKET_ID;

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(MARKET_ID, address(balanceFuse));
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(ERC20_MARKET_ID, address(erc20BalanceFuse));
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(MARKET_ID, _defaultCompoundSubstrates());
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(ERC20_MARKET_ID, _collateralSubstrates());
        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependencies);
        vm.stopPrank();

        vm.label(COMET, "cUSDCv3");
        vm.label(USDC, "USDC");
        vm.label(CB_BTC, "cbBTC");
        vm.label(WETH, "WETH");
        vm.label(WST_ETH, "wstETH");
        vm.label(WBTC, "WBTC");
        vm.label(DAI, "DAI");
        vm.label(address(plasmaVault), "PlasmaVault");
        vm.label(address(priceOracleMiddleware), "PriceOracleMiddleware");
        vm.label(address(balanceFuse), "CompoundV3WithPriceOracleMiddlewareBalanceFuse");
    }

    // ============================================================
    // Constructor
    // ============================================================

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(
            CompoundV3WithPriceOracleMiddlewareBalanceFuse
                .CompoundV3WithPriceOracleMiddlewareBalanceFuseInvalidMarketId
                .selector
        );
        new CompoundV3WithPriceOracleMiddlewareBalanceFuse(0, COMET);
    }

    function testShouldRevertWhenCometIsZeroAddress() public {
        vm.expectRevert(
            CompoundV3WithPriceOracleMiddlewareBalanceFuse
                .CompoundV3WithPriceOracleMiddlewareBalanceFuseInvalidAddress
                .selector
        );
        new CompoundV3WithPriceOracleMiddlewareBalanceFuse(MARKET_ID, address(0));
    }

    function testShouldSetImmutables() public view {
        assertEq(balanceFuse.VERSION(), address(balanceFuse), "VERSION");
        assertEq(balanceFuse.MARKET_ID(), MARKET_ID, "MARKET_ID");
        assertEq(address(balanceFuse.COMET()), COMET, "COMET");
        assertEq(balanceFuse.COMPOUND_BASE_TOKEN(), USDC, "COMPOUND_BASE_TOKEN");
        assertEq(balanceFuse.COMPOUND_BASE_TOKEN_DECIMALS(), 6, "COMPOUND_BASE_TOKEN_DECIMALS");
    }

    // ============================================================
    // balanceOf() through updateMarketsBalances / totalAssetsInMarket
    // ============================================================

    function testShouldReturnZeroWhenNoSubstrates() public {
        // given - a real collateral position exists and is valued
        _supplyCollateral(WETH, 10e18);
        assertGt(plasmaVault.totalAssetsInMarket(MARKET_ID), 0, "market value before revoking substrates");

        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(MARKET_ID, new bytes32[](0));
        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getMarketSubstrates(MARKET_ID).length, 0, "substrates");

        // when
        _refreshMarket();

        // then
        assertEq(IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH), 10e18, "collateral still in Comet");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), 0, "totalAssetsInMarket");
    }

    function testShouldReturnZeroWhenNoPosition() public {
        // given
        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getMarketSubstrates(MARKET_ID).length, 5, "substrates");
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "base supply");
        assertEq(IComet(COMET).borrowBalanceOf(address(plasmaVault)), 0, "debt");

        // when
        _refreshMarket();

        // then
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), 0, "totalAssetsInMarket");
    }

    function testShouldSkipOracleForSubstrateWithoutPosition() public {
        // given - middleware without Feed Registry fallback, pricing only USDC and WETH
        PriceOracleMiddleware limitedMiddleware = _deployLimitedMiddleware();
        _useLimitedMiddleware(limitedMiddleware);

        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        limitedMiddleware.getAssetPrice(CB_BTC);
        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        limitedMiddleware.getAssetPrice(WST_ETH);
        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        limitedMiddleware.getAssetPrice(WBTC);

        uint256 amount = 10e18;

        // when - execute refreshes MARKET_ID 2 with cbBTC, wstETH and WBTC granted but without positions
        _supplyCollateral(WETH, amount);
        _refreshMarket();

        // then
        uint256 expected = _toUnderlying(
            address(limitedMiddleware),
            _positionUsdWad(
                address(limitedMiddleware),
                WETH,
                IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH)
            )
        );
        assertGt(expected, 0, "expected");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), expected, "totalAssetsInMarket");
    }

    function testShouldRevertRefreshWhenPositionAssetHasNoPrice() public {
        PriceOracleMiddleware limitedMiddleware = _deployLimitedMiddleware();
        uint256 amount = 1e8;
        uint256 snapshot = vm.snapshotState();

        // scenario 1: supplying the unpriced collateral reverts in the balance refresh at the end of execute
        _useLimitedMiddleware(limitedMiddleware);
        deal(CB_BTC, address(plasmaVault), amount);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(supplyFuse),
            abi.encodeCall(supplyFuse.enter, (CompoundV3SupplyFuseEnterData({asset: CB_BTC, amount: amount})))
        );
        vm.prank(alpha);
        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        plasmaVault.execute(calls);

        assertEq(IComet(COMET).collateralBalanceOf(address(plasmaVault), CB_BTC), 0, "supply rolled back");

        // scenario 2: an existing position becomes unpriced -> explicit refresh reverts
        vm.revertToState(snapshot);
        _supplyCollateral(CB_BTC, amount);
        assertGt(plasmaVault.totalAssetsInMarket(MARKET_ID), 0, "valued with the full middleware");

        _useLimitedMiddleware(limitedMiddleware);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(atomist);
        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        plasmaVault.updateMarketsBalances(marketIds);
    }

    function testShouldValueCollateralWithMiddlewarePrice() public {
        address[4] memory collaterals = [CB_BTC, WBTC, WETH, WST_ETH];
        uint256[4] memory amounts = [uint256(1e8), uint256(1e8), uint256(10e18), uint256(10e18)];
        uint8[4] memory decimals = [8, 8, 18, 18];

        for (uint256 i; i < collaterals.length; ++i) {
            uint256 snapshot = vm.snapshotState();

            // given
            assertEq(IERC20Metadata(collaterals[i]).decimals(), decimals[i], "asset decimals");
            _supplyCollateral(collaterals[i], amounts[i]);

            // when
            _refreshMarket();

            // then
            uint256 collateral = IComet(COMET).collateralBalanceOf(address(plasmaVault), collaterals[i]);
            assertEq(collateral, amounts[i], "collateralBalanceOf");

            (uint256 price, uint256 priceDecimals) = priceOracleMiddleware.getAssetPrice(collaterals[i]);
            uint256 usdWad = _toUsdWad(collateral, price, decimals[i], priceDecimals);
            uint256 expected = _toUnderlying(address(priceOracleMiddleware), usdWad);

            assertGt(expected, 0, "expected");
            assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), expected, "totalAssetsInMarket");

            vm.revertToState(snapshot);
        }
    }

    function testShouldValueBaseSupplyWithMiddlewarePrice() public {
        // given
        uint256 amount = 100_000e6;
        _supplyBase(amount);

        // when
        _refreshMarket();

        // then
        uint256 baseSupply = IComet(COMET).balanceOf(address(plasmaVault));
        assertApproxEqAbs(baseSupply, amount, 1, "base supply");
        assertEq(IComet(COMET).borrowBalanceOf(address(plasmaVault)), 0, "debt");

        uint256 expected = _toUnderlying(
            address(priceOracleMiddleware),
            _positionUsdWad(address(priceOracleMiddleware), USDC, baseSupply)
        );
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), expected, "totalAssetsInMarket");
    }

    function testShouldSubtractDebtValuedWithMiddlewareUsdcPrice() public {
        // given
        _supplyCollateral(WETH, 10e18);
        uint256 collateralOnlyValue = plasmaVault.totalAssetsInMarket(MARKET_ID);
        _borrow(10_000e6);

        // when
        _refreshMarket();

        // then
        uint256 debt = IComet(COMET).borrowBalanceOf(address(plasmaVault));
        assertApproxEqAbs(debt, 10_000e6, 1, "debt");

        uint256 collateralUsdWad = _positionUsdWad(
            address(priceOracleMiddleware),
            WETH,
            IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH)
        );
        uint256 debtUsdWad = _positionUsdWad(address(priceOracleMiddleware), USDC, debt);
        uint256 expected = _toUnderlying(address(priceOracleMiddleware), collateralUsdWad - debtUsdWad);

        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), expected, "totalAssetsInMarket");
        assertLt(expected, collateralOnlyValue, "debt reduces market value");
    }

    function testShouldSubtractDebtWhenUsdcNotGrantedAsSubstrate() public {
        // given
        _supplyCollateral(WETH, 10e18);
        _borrow(10_000e6);

        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(MARKET_ID, _collateralSubstrates());
        assertFalse(PlasmaVaultGovernance(address(plasmaVault)).isMarketSubstrateGranted(MARKET_ID, _toBytes32(USDC)));

        // when
        _refreshMarket();

        // then
        uint256 debt = IComet(COMET).borrowBalanceOf(address(plasmaVault));
        assertGt(debt, 0, "debt");

        uint256 collateralUsdWad = _positionUsdWad(
            address(priceOracleMiddleware),
            WETH,
            IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH)
        );
        uint256 debtUsdWad = _positionUsdWad(address(priceOracleMiddleware), USDC, debt);
        uint256 expected = _toUnderlying(address(priceOracleMiddleware), collateralUsdWad - debtUsdWad);
        uint256 collateralOnly = _toUnderlying(address(priceOracleMiddleware), collateralUsdWad);

        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), expected, "totalAssetsInMarket");
        assertLt(plasmaVault.totalAssetsInMarket(MARKET_ID), collateralOnly, "debt still netted");
    }

    function testShouldIncludeAccruedInterestInDebt() public {
        // given
        _supplyCollateral(WETH, 10e18);
        _borrow(10_000e6);
        _refreshMarket();

        uint256 collateralBefore = IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH);
        uint256 debtBefore = IComet(COMET).borrowBalanceOf(address(plasmaVault));
        uint256 debtUsdWadBefore = _positionUsdWad(address(priceOracleMiddleware), USDC, debtBefore);
        uint256 marketValueBefore = plasmaVault.totalAssetsInMarket(MARKET_ID);

        // when
        vm.warp(block.timestamp + 30 days);
        _refreshMarket();

        // then
        uint256 collateralAfter = IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH);
        uint256 debtAfter = IComet(COMET).borrowBalanceOf(address(plasmaVault));
        uint256 collateralUsdWad = _positionUsdWad(address(priceOracleMiddleware), WETH, collateralAfter);
        uint256 debtUsdWadAfter = _positionUsdWad(address(priceOracleMiddleware), USDC, debtAfter);
        uint256 expected = _toUnderlying(address(priceOracleMiddleware), collateralUsdWad - debtUsdWadAfter);

        assertEq(collateralAfter, collateralBefore, "collateral constant");
        assertGt(debtAfter, debtBefore, "debt accrued");
        assertGt(debtUsdWadAfter, debtUsdWadBefore, "debt value grows");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), expected, "totalAssetsInMarket");
        assertLt(plasmaVault.totalAssetsInMarket(MARKET_ID), marketValueBefore, "market value decreases");
    }

    function testShouldNotRevertForSubstrateThatIsNotCometCollateral() public {
        // given - DAI is priced by the middleware (explicit Chainlink DAI / USD source) but is not listed on cUSDCv3
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = DAI;
        sources[0] = CHAINLINK_DAI_USD;
        vm.prank(atomist);
        priceOracleMiddleware.setAssetsPricesSources(assets, sources);

        (uint256 daiPrice, ) = priceOracleMiddleware.getAssetPrice(DAI);
        assertGt(daiPrice, 0, "DAI priced by middleware");

        vm.expectRevert(ICometErrorsCompoundV3MiddlewareBalanceFuseTest.BadAsset.selector);
        IComet(COMET).getAssetInfoByAddress(DAI);

        bytes32[] memory substrates = new bytes32[](6);
        bytes32[] memory defaults = _defaultCompoundSubstrates();
        for (uint256 i; i < defaults.length; ++i) {
            substrates[i] = defaults[i];
        }
        substrates[5] = _toBytes32(DAI);
        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(MARKET_ID, substrates);

        // DAI sitting idle in the vault must not be counted by the Compound market
        deal(DAI, address(plasmaVault), 1_000e18);
        _supplyCollateral(WETH, 10e18);

        // when
        _refreshMarket();

        // then
        assertEq(IComet(COMET).collateralBalanceOf(address(plasmaVault), DAI), 0, "DAI collateral");
        uint256 expected = _toUnderlying(
            address(priceOracleMiddleware),
            _positionUsdWad(
                address(priceOracleMiddleware),
                WETH,
                IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH)
            )
        );
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), expected, "DAI contributes zero");

        // the legacy CompoundV3BalanceFuse bricks the same refresh with BadAsset
        CompoundV3BalanceFuse legacyBalanceFuse = new CompoundV3BalanceFuse(MARKET_ID, COMET);
        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(MARKET_ID, address(legacyBalanceFuse));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(atomist);
        vm.expectRevert(ICometErrorsCompoundV3MiddlewareBalanceFuseTest.BadAsset.selector);
        plasmaVault.updateMarketsBalances(marketIds);
    }

    function testShouldRevertWhenDebtExceedsGrantedCollateralValue() public {
        // given
        _supplyCollateral(WETH, 10e18);
        _borrow(10_000e6);

        bytes32[] memory usdcOnly = new bytes32[](1);
        usdcOnly[0] = _toBytes32(USDC);
        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(MARKET_ID, usdcOnly);

        uint256 debt = IComet(COMET).borrowBalanceOf(address(plasmaVault));
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "no base supply while borrowing");
        int256 netUsdWad = -int256(_positionUsdWad(address(priceOracleMiddleware), USDC, debt));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;

        // when / then
        vm.prank(atomist);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedIntToUint.selector, netUsdWad));
        plasmaVault.updateMarketsBalances(marketIds);
    }

    function testShouldUseSameMiddlewarePriceForBaseSupplyAndDebt() public {
        uint256 amount = 10_000e6;
        (uint256 usdcPrice, uint256 usdcPriceDecimals) = priceOracleMiddleware.getAssetPrice(USDC);
        assertEq(usdcPriceDecimals, 18, "middleware quote decimals");

        uint256 snapshot = vm.snapshotState();

        // scenario A: positive base supply (a Comet account cannot hold base supply and base debt at once)
        _supplyBase(amount);
        _refreshMarket();

        uint256 baseSupply = IComet(COMET).balanceOf(address(plasmaVault));
        assertEq(IComet(COMET).borrowBalanceOf(address(plasmaVault)), 0, "A: no debt");
        uint256 baseSupplyUsdWad = _toUsdWad(baseSupply, usdcPrice, 6, usdcPriceDecimals);
        uint256 marketValueA = plasmaVault.totalAssetsInMarket(MARKET_ID);
        assertEq(marketValueA, _toUnderlying(address(priceOracleMiddleware), baseSupplyUsdWad), "A: base supply value");
        // valued and converted with the same middleware USDC price -> round trip to the supplied amount
        assertApproxEqAbs(marketValueA, baseSupply, 1, "A: round trip");

        vm.revertToState(snapshot);

        // scenario B: base debt of the same size against WETH collateral
        _supplyCollateral(WETH, 10e18);
        _borrow(amount);
        _refreshMarket();

        uint256 debt = IComet(COMET).borrowBalanceOf(address(plasmaVault));
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "B: no base supply");
        uint256 debtUsdWad = _toUsdWad(debt, usdcPrice, 6, usdcPriceDecimals);
        uint256 collateralUsdWad = _positionUsdWad(
            address(priceOracleMiddleware),
            WETH,
            IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH)
        );
        uint256 marketValueB = plasmaVault.totalAssetsInMarket(MARKET_ID);
        assertEq(
            marketValueB,
            _toUnderlying(address(priceOracleMiddleware), collateralUsdWad - debtUsdWad),
            "B: collateral minus debt value"
        );

        // the same USDC amount has the same USD WAD magnitude on both sides
        assertApproxEqAbs(debt, baseSupply, 2, "same base amount");
        assertApproxEqAbs(debtUsdWad, baseSupplyUsdWad, (2 * usdcPrice) / 1e6 + 1, "same USD value on both sides");
        if (debt == baseSupply) {
            assertEq(debtUsdWad, baseSupplyUsdWad, "identical USD value for identical amounts");
        }
    }

    function testShouldUseMiddlewareNotCometPriceForWeth() public {
        // given
        uint256 amount = 100e18;
        _supplyCollateral(WETH, amount);

        // when
        _refreshMarket();

        // then
        uint256 collateral = IComet(COMET).collateralBalanceOf(address(plasmaVault), WETH);
        assertEq(collateral, amount, "collateralBalanceOf");

        (uint256 middlewarePrice, uint256 middlewarePriceDecimals) = priceOracleMiddleware.getAssetPrice(WETH);
        IComet.AssetInfo memory assetInfo = IComet(COMET).getAssetInfoByAddress(WETH);
        uint256 cometPrice = IComet(COMET).getPrice(assetInfo.priceFeed); // 8 decimals

        uint256 middlewareUsdWad = _toUsdWad(collateral, middlewarePrice, 18, middlewarePriceDecimals);
        uint256 cometUsdWad = _toUsdWad(collateral, cometPrice, 18, 8);
        uint256 middlewareValue = _toUnderlying(address(priceOracleMiddleware), middlewareUsdWad);
        uint256 cometValue = _toUnderlying(address(priceOracleMiddleware), cometUsdWad);

        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), middlewareValue, "valued with middleware price");
        assertNotEq(middlewarePrice, cometPrice * 1e10, "prices differ at the fork block");
        assertNotEq(plasmaVault.totalAssetsInMarket(MARKET_ID), cometValue, "not valued with Comet price");

        // difference = (pMiddleware - pComet) x amount
        int256 priceDelta = int256(middlewarePrice) - int256(cometPrice * 1e10);
        int256 expectedUsdWadDelta = (priceDelta * int256(collateral)) / 1e18;
        assertApproxEqAbs(int256(middlewareUsdWad) - int256(cometUsdWad), expectedUsdWadDelta, 1, "USD WAD delta");
        assertApproxEqAbs(
            int256(middlewareValue) - int256(cometValue),
            expectedUsdWadDelta >= 0
                ? int256(_toUnderlying(address(priceOracleMiddleware), uint256(expectedUsdWadDelta)))
                : -int256(_toUnderlying(address(priceOracleMiddleware), uint256(-expectedUsdWadDelta))),
            2,
            "underlying delta"
        );
    }

    // ============================================================
    // Setup helpers
    // ============================================================

    function _deployMiddleware(address feedRegistry_) private returns (PriceOracleMiddleware middleware) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(feedRegistry_);
        middleware = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", atomist)))
        );
    }

    function _deployVault() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        usersToRoles.alphas = new address[](1);
        usersToRoles.alphas[0] = alpha;

        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vm.startPrank(atomist);
        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Compound V3 Middleware Balance Fuse Vault",
                assetSymbol: "cV3MBF",
                underlyingToken: USDC,
                priceOracleMiddleware: address(priceOracleMiddleware),
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: address(accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, withdrawManager);

        // RoleLib does not wire these selectors - grant them to the atomist
        bytes4[] memory extraSig = new bytes4[](2);
        extraSig[0] = PlasmaVaultGovernance.grantMarketSubstrates.selector;
        extraSig[1] = PlasmaVault.updateMarketsBalances.selector;
        vm.prank(atomist);
        accessManager.setTargetFunctionRole(address(plasmaVault), extraSig, Roles.ATOMIST_ROLE);

        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = PlasmaVaultGovernance(address(plasmaVault))
            .getPerformanceFeeData();
        vm.prank(atomist);
        FeeManager(FeeAccount(performanceFeeData.feeAccount).FEE_MANAGER()).initialize();
    }

    /// @dev Real PriceOracleMiddleware without Chainlink Feed Registry fallback, pricing only USDC and WETH
    function _deployLimitedMiddleware() private returns (PriceOracleMiddleware limitedMiddleware) {
        limitedMiddleware = _deployMiddleware(address(0));
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;
        assets[1] = WETH;
        sources[1] = CHAINLINK_ETH_USD;
        vm.prank(atomist);
        limitedMiddleware.setAssetsPricesSources(assets, sources);
        vm.label(address(limitedMiddleware), "LimitedPriceOracleMiddleware");
    }

    /// @dev Switches the vault to the limited middleware. ERC20_VAULT_BALANCE (refreshed as a dependency of MARKET_ID 2)
    ///      prices every substrate, so it is restricted to WETH to isolate the Compound balance fuse behaviour.
    function _useLimitedMiddleware(PriceOracleMiddleware limitedMiddleware_) private {
        bytes32[] memory wethOnly = new bytes32[](1);
        wethOnly[0] = _toBytes32(WETH);

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(ERC20_MARKET_ID, wethOnly);
        PlasmaVaultGovernance(address(plasmaVault)).setPriceOracleMiddleware(address(limitedMiddleware_));
        vm.stopPrank();

        assertEq(
            PlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware(),
            address(limitedMiddleware_),
            "limited middleware set"
        );
    }

    function _defaultCompoundSubstrates() private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](5);
        substrates[0] = _toBytes32(USDC);
        substrates[1] = _toBytes32(CB_BTC);
        substrates[2] = _toBytes32(WETH);
        substrates[3] = _toBytes32(WST_ETH);
        substrates[4] = _toBytes32(WBTC);
    }

    function _collateralSubstrates() private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](4);
        substrates[0] = _toBytes32(CB_BTC);
        substrates[1] = _toBytes32(WETH);
        substrates[2] = _toBytes32(WST_ETH);
        substrates[3] = _toBytes32(WBTC);
    }

    function _toBytes32(address asset_) private pure returns (bytes32) {
        return PlasmaVaultConfigLib.addressToBytes32(asset_);
    }

    // ============================================================
    // Vault action helpers (all protocol actions via PlasmaVault.execute as alpha)
    // ============================================================

    function _supplyCollateral(address asset_, uint256 amount_) private {
        deal(asset_, address(plasmaVault), amount_);
        _executeSupply(asset_, amount_);
    }

    function _supplyBase(uint256 amount_) private {
        deal(USDC, address(plasmaVault), amount_);
        _executeSupply(USDC, amount_);
    }

    function _executeSupply(address asset_, uint256 amount_) private {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(supplyFuse),
            abi.encodeCall(supplyFuse.enter, (CompoundV3SupplyFuseEnterData({asset: asset_, amount: amount_})))
        );
        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    function _borrow(uint256 amount_) private {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(borrowFuse),
            abi.encodeCall(borrowFuse.enter, (CompoundV3BorrowFuseEnterData({amount: amount_})))
        );
        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    function _refreshMarket() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(atomist);
        plasmaVault.updateMarketsBalances(marketIds);
    }

    // ============================================================
    // Expected value helpers
    // ============================================================

    /// @dev USD WAD value of a Comet position priced with the given middleware (stage 1, positive term)
    function _positionUsdWad(address middleware_, address asset_, uint256 amount_) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(middleware_).getAssetPrice(asset_);
        return _toUsdWad(amount_, price, IERC20Metadata(asset_).decimals(), priceDecimals);
    }

    /// @dev Stage 1: amount x price normalized to 18 decimals; scaling down rounds half up, as
    ///      IporMath.convertToWadInt does for non-negative values
    function _toUsdWad(
        uint256 amount_,
        uint256 price_,
        uint256 assetDecimals_,
        uint256 priceDecimals_
    ) private pure returns (uint256) {
        uint256 value = amount_ * price_;
        uint256 decimalsSum = assetDecimals_ + priceDecimals_;
        if (decimalsSum == 18) {
            return value;
        }
        if (decimalsSum > 18) {
            uint256 divisor = 10 ** (decimalsSum - 18);
            return (value + divisor / 2) / divisor;
        }
        return value * 10 ** (18 - decimalsSum);
    }

    /// @dev Stage 2 (PlasmaVaultMarketsLib.updateMarketsBalances): USD WAD -> underlying (USDC, 6 decimals),
    ///      using the middleware price of the underlying; both divisions truncate
    function _toUnderlying(address middleware_, uint256 usdWad_) private view returns (uint256) {
        (uint256 underlyingPrice, uint256 underlyingPriceDecimals) = IPriceOracleMiddleware(middleware_).getAssetPrice(
            USDC
        );
        uint256 inWad = (usdWad_ * 10 ** underlyingPriceDecimals) / underlyingPrice;
        return inWad / 10 ** (18 - UNDERLYING_DECIMALS);
    }
}
