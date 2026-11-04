// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    CompoundV3BorrowFuse,
    CompoundV3BorrowFuseEnterData,
    CompoundV3BorrowFuseExitData
} from "../../../contracts/fuses/compound_v3/CompoundV3BorrowFuse.sol";
import {
    CompoundV3SupplyFuse,
    CompoundV3SupplyFuseEnterData,
    CompoundV3SupplyFuseExitData
} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {CompoundV3WithPriceOracleMiddlewareBalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3WithPriceOracleMiddlewareBalanceFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/ext/IComet.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {
    PlasmaVault,
    FuseAction,
    MarketSubstratesConfig,
    MarketBalanceFuseConfig,
    PlasmaVaultInitData,
    FeeConfig
} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

/// @notice Test-local view of the Institutional Comet (errors and views not present in the production IComet)
interface ICometInstitutionalUsdcBorrow {
    error NotCollateralized();

    function baseScale() external view returns (uint256);

    function isBorrowCollateralized(address account) external view returns (bool);

    function isLendersWithdrawPaused() external view returns (bool);

    function pauseLendersWithdraw(bool paused) external;
}

/// @title Fork test of borrowing USDC on the Compound V3 Institutional USDC market (ciUSDCv3) on Ethereum
/// @notice Real PlasmaVault, access manager, PriceOracleMiddleware and the real ciUSDCv3 Comet, with
///         CompoundV3SupplyFuse, CompoundV3BorrowFuse and CompoundV3WithPriceOracleMiddlewareBalanceFuse bound to
///         market IporFusionMarkets.COMPOUND_V3_INSTITUTIONAL_USDC. No mocks. The vault underlying is WETH, the
///         collateral listed on the Comet; borrowed USDC sits idle and is valued through the ERC20 vault balance market.
contract CompoundV3InstitutionalUsdcBorrowEthereum is Test {
    uint256 private constant FORK_BLOCK = 26_340_464;

    address private constant COMET_ADDRESS = 0x207158a267CBD2598BB3d611D8CBdEE2709F2F8C;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC_USD_SOURCE = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address private constant ETH_USD_SOURCE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    /// @dev pause guardian of the Institutional Comet (can call pauseLendersWithdraw)
    address private constant PAUSE_GUARDIAN = 0xbbf3f1421D886E9b2c5D716B5192aC998af2012c;

    uint256 private constant MARKET_ID = IporFusionMarkets.COMPOUND_V3_INSTITUTIONAL_USDC;
    uint256 private constant ERC20_MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;

    uint256 private constant COLLATERAL_AMOUNT = 40e18;
    /// @dev Comet rounds debt through principal/index conversion, so a couple of base units of drift is expected
    uint256 private constant USDC_TOLERANCE = 4;

    IComet private constant COMET = IComet(COMET_ADDRESS);
    ICometInstitutionalUsdcBorrow private constant COMET_EXT = ICometInstitutionalUsdcBorrow(COMET_ADDRESS);

    address private admin;
    address private alpha;
    address private user;

    PriceOracleMiddleware private priceOracleMiddleware;
    CompoundV3SupplyFuse private supplyFuse;
    CompoundV3BorrowFuse private borrowFuse;
    CompoundV3WithPriceOracleMiddlewareBalanceFuse private balanceFuse;
    ERC20BalanceFuse private erc20BalanceFuse;
    PlasmaVault private vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        admin = makeAddr("admin");
        alpha = makeAddr("alpha");
        user = makeAddr("user");

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(CHAINLINK_FEED_REGISTRY);
        priceOracleMiddleware = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin)))
        );
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = USDC;
        sources[0] = USDC_USD_SOURCE;
        assets[1] = WETH;
        sources[1] = ETH_USD_SOURCE;
        vm.prank(admin);
        priceOracleMiddleware.setAssetsPricesSources(assets, sources);

        supplyFuse = new CompoundV3SupplyFuse(MARKET_ID, COMET_ADDRESS);
        borrowFuse = new CompoundV3BorrowFuse(MARKET_ID, COMET_ADDRESS);
        balanceFuse = new CompoundV3WithPriceOracleMiddlewareBalanceFuse(MARKET_ID, COMET_ADDRESS);
        erc20BalanceFuse = new ERC20BalanceFuse(ERC20_MARKET_ID);

        vault = _deployVault(true);
        _depositToVault(COLLATERAL_AMOUNT);
    }

    function testShouldBindBorrowFuseToInstitutionalUsdcCometAndMarket57() public view {
        assertEq(borrowFuse.MARKET_ID(), 57, "borrow fuse market id");
        assertEq(address(borrowFuse.COMET()), COMET_ADDRESS, "borrow fuse comet");
        assertEq(borrowFuse.COMPOUND_BASE_TOKEN(), USDC, "borrow fuse base token");
        assertEq(borrowFuse.VERSION(), address(borrowFuse), "borrow fuse version");
    }

    function testShouldBorrowRepayAndWithdrawCollateralWithNavAtEachStep() public {
        uint256 navStart = vault.totalAssets();
        assertEq(navStart, COLLATERAL_AMOUNT, "nav after deposit");

        // supply collateral
        _execute(_supplyAction(WETH, COLLATERAL_AMOUNT));
        assertEq(ERC20(WETH).balanceOf(address(vault)), 0, "idle WETH after supply");
        assertEq(COMET.collateralBalanceOf(address(vault), WETH), COLLATERAL_AMOUNT, "comet collateral");
        _assertNetValue(navStart, "after supply");

        // borrow 30% of the collateral value
        uint256 borrowAmount = _collateralValueInUsdc() / 3;
        assertGt(borrowAmount, 1_000e6, "sanity: borrow above the minimum");
        _execute(_borrowAction(borrowAmount));

        assertEq(ERC20(USDC).balanceOf(address(vault)), borrowAmount, "idle USDC rose by the borrowed amount");
        assertGe(COMET.borrowBalanceOf(address(vault)), borrowAmount, "debt >= borrowed");
        assertApproxEqAbs(COMET.borrowBalanceOf(address(vault)), borrowAmount, USDC_TOLERANCE, "debt");
        assertEq(COMET.balanceOf(address(vault)), 0, "no base supply while borrowing");
        assertTrue(COMET_EXT.isBorrowCollateralized(address(vault)), "collateralized");
        _assertNetValue(navStart, "after borrow");

        // repay part
        uint256 partial_ = borrowAmount / 4;
        _execute(_repayAction(partial_));
        assertApproxEqAbs(
            COMET.borrowBalanceOf(address(vault)),
            borrowAmount - partial_,
            USDC_TOLERANCE,
            "debt after partial repay"
        );
        assertEq(ERC20(USDC).balanceOf(address(vault)), borrowAmount - partial_, "idle USDC after partial repay");
        assertEq(ERC20(USDC).allowance(address(vault), COMET_ADDRESS), 0, "no residual allowance");
        _assertNetValue(navStart, "after partial repay");

        // repay the rest (cover only the principal rounding shortfall, if any)
        uint256 debt = COMET.borrowBalanceOf(address(vault));
        uint256 idle = ERC20(USDC).balanceOf(address(vault));
        if (debt > idle) {
            assertLe(debt - idle, USDC_TOLERANCE, "rounding shortfall");
            deal(USDC, address(vault), debt);
        }
        _execute(_repayAction(type(uint256).max));
        assertEq(COMET.borrowBalanceOf(address(vault)), 0, "debt after full repay");
        assertEq(COMET.balanceOf(address(vault)), 0, "no base supply after full repay");

        // withdraw the collateral
        _execute(_withdrawAction(WETH, COLLATERAL_AMOUNT));
        assertEq(COMET.collateralBalanceOf(address(vault), WETH), 0, "comet collateral after withdraw");
        assertEq(ERC20(WETH).balanceOf(address(vault)), COLLATERAL_AMOUNT, "WETH back in the vault");
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 0, "market 57 NAV after exit");
    }

    function testShouldRevertBorrowAboveCollateralFactor() public {
        _execute(_supplyAction(WETH, COLLATERAL_AMOUNT));

        IComet.AssetInfo memory info = COMET.getAssetInfoByAddress(WETH);
        uint256 collateralValue = (COLLATERAL_AMOUNT * COMET.getPrice(info.priceFeed)) / info.scale;
        uint256 capacityValue = (collateralValue * info.borrowCollateralFactor) / 1e18;
        uint256 maxBorrow = (capacityValue * COMET_EXT.baseScale()) / COMET.getPrice(COMET.baseTokenPriceFeed());

        vm.expectRevert(ICometInstitutionalUsdcBorrow.NotCollateralized.selector);
        _execute(_borrowAction(maxBorrow + 1e6));
        assertEq(COMET.borrowBalanceOf(address(vault)), 0, "no debt after revert");

        _execute(_borrowAction(maxBorrow - 1e6));
        assertTrue(COMET_EXT.isBorrowCollateralized(address(vault)), "collateralized at the limit");
    }

    function testShouldRevertBorrowWhenUsdcSubstrateNotGranted() public {
        PlasmaVault noUsdcVault = _deployVault(false);
        _depositTo(noUsdcVault, COLLATERAL_AMOUNT);
        vm.prank(alpha);
        noUsdcVault.execute(_single(_supplyAction(WETH, COLLATERAL_AMOUNT)));

        vm.expectRevert(
            abi.encodeWithSelector(CompoundV3BorrowFuse.CompoundV3BorrowFuseUnsupportedAsset.selector, "enter", USDC)
        );
        vm.prank(alpha);
        noUsdcVault.execute(_single(_borrowAction(10_000e6)));
    }

    function testShouldStillBorrowWhenLendersWithdrawPaused() public {
        _execute(_supplyAction(WETH, COLLATERAL_AMOUNT));

        vm.prank(PAUSE_GUARDIAN);
        COMET_EXT.pauseLendersWithdraw(true);
        assertTrue(COMET_EXT.isLendersWithdrawPaused(), "lenders withdraw paused");

        uint256 borrowAmount = _collateralValueInUsdc() / 3;
        _execute(_borrowAction(borrowAmount));
        assertEq(ERC20(USDC).balanceOf(address(vault)), borrowAmount, "borrowed while lenders withdraw is paused");
    }

    // ------------------------------------------------------------------------------------------------

    function _deployVault(bool grantUsdc_) private returns (PlasmaVault newVault) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = admin;
        usersToRoles.atomist = admin;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;

        IporFusionAccessManager accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        newVault = PlasmaVaultCloneLib.newPlasmaVault();
        vm.prank(admin);
        newVault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Compound V3 Institutional Borrow Vault",
                assetSymbol: "ciV3BRW",
                underlyingToken: WETH,
                priceOracleMiddleware: address(priceOracleMiddleware),
                feeConfig: FeeConfig({
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    iporDaoFeeRecipientAddress: makeAddr("daoFeeRecipient")
                }),
                accessManager: address(accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(newVault), accessManager, withdrawManager);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(borrowFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(balanceFuse));
        balanceFuses[1] = MarketBalanceFuseConfig(ERC20_MARKET_ID, address(erc20BalanceFuse));

        bytes32[] memory compoundSubstrates = new bytes32[](grantUsdc_ ? 2 : 1);
        compoundSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        if (grantUsdc_) {
            compoundSubstrates[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        }
        bytes32[] memory erc20Substrates = new bytes32[](1);
        erc20Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);
        marketConfigs[0] = MarketSubstratesConfig(MARKET_ID, compoundSubstrates);
        marketConfigs[1] = MarketSubstratesConfig(ERC20_MARKET_ID, erc20Substrates);

        PlasmaVaultConfigurator.setupPlasmaVault(vm, admin, address(newVault), fuses, balanceFuses, marketConfigs);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = ERC20_MARKET_ID;
        vm.prank(admin);
        PlasmaVaultGovernance(address(newVault)).updateDependencyBalanceGraphs(marketIds, dependencies);
    }

    function _depositToVault(uint256 amount_) private {
        _depositTo(vault, amount_);
    }

    function _depositTo(PlasmaVault target_, uint256 amount_) private {
        deal(WETH, user, amount_);
        vm.startPrank(user);
        ERC20(WETH).approve(address(target_), amount_);
        target_.deposit(amount_, user);
        vm.stopPrank();
    }

    function _execute(FuseAction memory action_) private {
        vm.prank(alpha);
        vault.execute(_single(action_));
    }

    function _single(FuseAction memory action_) private pure returns (FuseAction[] memory calls) {
        calls = new FuseAction[](1);
        calls[0] = action_;
    }

    function _supplyAction(address asset_, uint256 amount_) private view returns (FuseAction memory) {
        return
            FuseAction(
                address(supplyFuse),
                abi.encodeCall(
                    CompoundV3SupplyFuse.enter,
                    (CompoundV3SupplyFuseEnterData({asset: asset_, amount: amount_}))
                )
            );
    }

    function _withdrawAction(address asset_, uint256 amount_) private view returns (FuseAction memory) {
        return
            FuseAction(
                address(supplyFuse),
                abi.encodeCall(
                    CompoundV3SupplyFuse.exit,
                    (CompoundV3SupplyFuseExitData({asset: asset_, amount: amount_}))
                )
            );
    }

    function _borrowAction(uint256 amount_) private view returns (FuseAction memory) {
        return
            FuseAction(
                address(borrowFuse),
                abi.encodeCall(CompoundV3BorrowFuse.enter, (CompoundV3BorrowFuseEnterData({amount: amount_})))
            );
    }

    function _repayAction(uint256 amount_) private view returns (FuseAction memory) {
        return
            FuseAction(
                address(borrowFuse),
                abi.encodeCall(CompoundV3BorrowFuse.exit, (CompoundV3BorrowFuseExitData({amount: amount_})))
            );
    }

    /// @dev value of COLLATERAL_AMOUNT WETH in USDC base units, from the vault middleware
    function _collateralValueInUsdc() private view returns (uint256) {
        (uint256 wethPrice, uint256 wethDecimals) = priceOracleMiddleware.getAssetPrice(WETH);
        (uint256 usdcPrice, uint256 usdcDecimals) = priceOracleMiddleware.getAssetPrice(USDC);
        return (COLLATERAL_AMOUNT * wethPrice * 10 ** usdcDecimals * 1e6) / (usdcPrice * 10 ** wethDecimals * 1e18);
    }

    /// @dev The vault net value (WETH idle + market 57 net of debt + idle USDC) must stay at the starting NAV: the
    ///      market 57 value is collateral value minus debt (via the middleware balance fuse), the idle USDC is
    ///      valued by the ERC20 market. The tolerance covers WAD/decimals flooring and Comet debt rounding.
    function _assertNetValue(uint256 navStart_, string memory step_) private view {
        (uint256 usdcPrice, uint256 usdcDecimals) = priceOracleMiddleware.getAssetPrice(USDC);
        (uint256 wethPrice, uint256 wethDecimals) = priceOracleMiddleware.getAssetPrice(WETH);

        // independent expectation of market 57: collateral value - debt, in WETH units
        uint256 collateralWeth = COMET.collateralBalanceOf(address(vault), WETH);
        uint256 debtUsdc = COMET.borrowBalanceOf(address(vault));
        uint256 debtInWeth = (debtUsdc * usdcPrice * 10 ** wethDecimals * 1e12) / (wethPrice * 10 ** usdcDecimals);
        // 1e12 scales 6-decimal USDC to 18-decimal WETH units

        assertApproxEqAbs(
            vault.totalAssetsInMarket(MARKET_ID),
            collateralWeth - debtInWeth,
            1e12,
            string.concat("market 57 NAV = collateral - debt, ", step_)
        );
        // 1 USDC base unit is ~4e11 wei of WETH at these prices; allow 4 base units of rounding plus WAD flooring
        assertApproxEqAbs(vault.totalAssets(), navStart_, 4e12, string.concat("total assets, ", step_));
    }
}
