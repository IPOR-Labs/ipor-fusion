// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {
    TransientStorageSetInputsFuse,
    TransientStorageSetInputsFuseEnterData
} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {
    CompoundV3SupplyFuse,
    CompoundV3SupplyFuseEnterData
} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {
    CompoundV3BorrowFuse,
    CompoundV3BorrowFuseEnterData,
    CompoundV3BorrowFuseExitData
} from "../../../contracts/fuses/compound_v3/CompoundV3BorrowFuse.sol";
import {CompoundV3WithPriceOracleMiddlewareBalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3WithPriceOracleMiddlewareBalanceFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/ext/IComet.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";

/// @dev Test-local view of the cUSDCv3 Comet: custom errors and parameters not present in the production IComet
interface ICometCompoundV3BorrowFuseTest {
    error NotCollateralized();
    error BorrowTooSmall();

    function baseBorrowMin() external view returns (uint256);
}

/// @title CompoundV3BorrowFuseTest
/// @notice Ethereum mainnet fork tests of CompoundV3BorrowFuse executed through a real PlasmaVault (USDC underlying)
///         against the real cUSDCv3 Comet, real ERC20 tokens and a real PriceOracleMiddleware with production sources.
/// @dev Only real contracts and state are used (no test doubles or state overrides). Collateral is funded directly
///      to the vault with deal (focused fuse tests).
contract CompoundV3BorrowFuseTest is Test {
    uint256 private constant FORK_BLOCK = 25982679;

    address private constant COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant USDC_USD_SOURCE = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address private constant ETH_USD_SOURCE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant WSTETH_USD_SOURCE = 0x4329e2178D41D058Cf2808c11436A9e83BC5D8b0;
    address private constant WBTC_USD_SOURCE = 0x106f9537Dd66423E6674e85CA187B43055B59fe9;

    uint256 private constant MARKET_ID = IporFusionMarkets.COMPOUND_V3_USDC;

    /// @dev Comet converts present value <-> principal with its index, rounding the debt by at most a wei or two
    uint256 private constant COMET_ROUNDING_TOLERANCE = 2;

    /// @dev Tolerance for vault NAV comparisons (Comet rounding + two wad conversions in the vault)
    uint256 private constant NAV_TOLERANCE = 10;

    uint256 private constant WETH_COLLATERAL = 10e18;
    uint256 private constant BORROW_AMOUNT = 10_000e6;

    address private atomist = makeAddr("atomist");
    address private alpha = makeAddr("alpha");
    address private user = makeAddr("user");

    PlasmaVault private plasmaVault;
    address private withdrawManager;
    address private priceOracleMiddleware;

    CompoundV3SupplyFuse private supplyFuse;
    CompoundV3BorrowFuse private borrowFuse;
    CompoundV3WithPriceOracleMiddlewareBalanceFuse private balanceFuse;
    ERC20BalanceFuse private erc20BalanceFuse;
    TransientStorageSetInputsFuse private setInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        _deployPriceOracleMiddleware();
        _deployVault();
        _configureVault();
    }

    // ============ Constructor / config ============

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(CompoundV3BorrowFuse.CompoundV3BorrowFuseInvalidMarketId.selector);
        new CompoundV3BorrowFuse(0, COMET);
    }

    function testShouldRevertWhenCometIsZeroAddress() public {
        vm.expectRevert(CompoundV3BorrowFuse.CompoundV3BorrowFuseInvalidAddress.selector);
        new CompoundV3BorrowFuse(MARKET_ID, address(0));
    }

    function testShouldSetImmutables() public {
        CompoundV3BorrowFuse fuse = new CompoundV3BorrowFuse(MARKET_ID, COMET);

        assertEq(fuse.VERSION(), address(fuse), "VERSION");
        assertEq(fuse.MARKET_ID(), MARKET_ID, "MARKET_ID");
        assertEq(address(fuse.COMET()), COMET, "COMET");
        assertEq(fuse.COMPOUND_BASE_TOKEN(), USDC, "COMPOUND_BASE_TOKEN");
    }

    // ============ Enter (borrow) ============

    function testShouldBorrowUsdcAgainstCollateralCbBtc() public {
        _assertBorrowAgainstCollateral(CBBTC, 1e8, 30_000e6);
    }

    function testShouldBorrowUsdcAgainstCollateralWbtc() public {
        _assertBorrowAgainstCollateral(WBTC, 1e8, 30_000e6);
    }

    function testShouldBorrowUsdcAgainstCollateralWeth() public {
        _assertBorrowAgainstCollateral(WETH, WETH_COLLATERAL, BORROW_AMOUNT);
    }

    function testShouldBorrowUsdcAgainstCollateralWstEth() public {
        _assertBorrowAgainstCollateral(WSTETH, WETH_COLLATERAL, BORROW_AMOUNT);
    }

    function testShouldReturnZeroWhenBorrowAmountIsZero() public {
        // given
        _supplyCollateral(WETH, WETH_COLLATERAL);
        uint256 vaultUsdcBefore = _vaultUsdc();
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 collateralBefore = _collateral(WETH);

        // direct call: the zero-amount path touches no storage, so the return values can be read without the vault
        (address asset, address market, uint256 amount) = borrowFuse.enter(CompoundV3BorrowFuseEnterData({amount: 0}));
        assertEq(asset, USDC, "returned asset");
        assertEq(market, COMET, "returned market");
        assertEq(amount, 0, "returned amount");

        // when
        vm.recordLogs();
        _executeOne(_borrowAction(0));

        // then
        _assertNoFuseEvent(CompoundV3BorrowFuse.CompoundV3BorrowFuseEnter.selector);
        assertEq(_debt(), 0, "debt");
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "base supply");
        assertEq(_vaultUsdc(), vaultUsdcBefore, "vault USDC");
        assertEq(_collateral(WETH), collateralBefore, "collateral");
        assertEq(plasmaVault.totalAssets(), totalAssetsBefore, "totalAssets");
    }

    function testShouldRevertBorrowWhenBaseTokenNotGranted() public {
        // given
        _supplyCollateral(WETH, WETH_COLLATERAL);
        _grantMarketSubstrates(_collateralSubstrates());

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(CompoundV3BorrowFuse.CompoundV3BorrowFuseUnsupportedAsset.selector, "enter", USDC)
        );
        _executeOne(_borrowAction(BORROW_AMOUNT));
    }

    function testShouldRevertBorrowWhenNotCollateralized() public {
        // given
        _supplyCollateral(WETH, WETH_COLLATERAL);
        uint256 borrowLimit = _cometBorrowLimit(WETH, WETH_COLLATERAL);

        // when / then - 1% above the limit computed from Comet prices and borrowCollateralFactor
        vm.expectRevert(ICometCompoundV3BorrowFuseTest.NotCollateralized.selector);
        _executeOne(_borrowAction((borrowLimit * 101) / 100));

        // and 1% below the limit succeeds
        uint256 belowLimit = (borrowLimit * 99) / 100;
        _executeOne(_borrowAction(belowLimit));
        assertApproxEqAbs(_debt(), belowLimit, COMET_ROUNDING_TOLERANCE, "debt below limit");
    }

    function testShouldRevertBorrowWithoutCollateral() public {
        // given - no collateral on Comet, borrow above baseBorrowMin
        uint256 amount = ICometCompoundV3BorrowFuseTest(COMET).baseBorrowMin();
        assertEq(_collateral(WETH), 0, "no collateral");

        // when / then
        vm.expectRevert(ICometCompoundV3BorrowFuseTest.NotCollateralized.selector);
        _executeOne(_borrowAction(amount));
    }

    function testShouldRevertBorrowBelowBaseBorrowMin() public {
        // given
        _supplyCollateral(WETH, WETH_COLLATERAL);
        uint256 baseBorrowMin = ICometCompoundV3BorrowFuseTest(COMET).baseBorrowMin();
        assertEq(baseBorrowMin, 100e6, "baseBorrowMin");

        // when / then
        vm.expectRevert(ICometCompoundV3BorrowFuseTest.BorrowTooSmall.selector);
        _executeOne(_borrowAction(baseBorrowMin - 1));
    }

    function testShouldConsumeBaseSupplyBeforeBorrowing() public {
        // given - collateral plus a positive USDC base supply on the same Comet account
        uint256 usdcSupply = 1_000e6;
        _supplyCollateral(WETH, WETH_COLLATERAL);
        deal(USDC, address(plasmaVault), usdcSupply);
        _executeOne(_supplyAction(USDC, usdcSupply));

        uint256 baseSupplyBefore = IComet(COMET).balanceOf(address(plasmaVault));
        assertApproxEqAbs(baseSupplyBefore, usdcSupply, COMET_ROUNDING_TOLERANCE, "base supply before");
        assertEq(_debt(), 0, "no debt before");
        uint256 vaultUsdcBefore = _vaultUsdc();

        // when
        uint256 amount = 5_000e6;
        _executeOne(_borrowAction(amount));

        // then
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "base supply consumed");
        assertApproxEqAbs(_debt(), amount - baseSupplyBefore, COMET_ROUNDING_TOLERANCE, "debt = amount - supply");
        assertEq(_vaultUsdc(), vaultUsdcBefore + amount, "vault USDC");
    }

    function testShouldEmitEnterEvent() public {
        // given
        _supplyCollateral(WETH, WETH_COLLATERAL);

        // then
        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit CompoundV3BorrowFuse.CompoundV3BorrowFuseEnter(address(borrowFuse), USDC, COMET, BORROW_AMOUNT);

        // when
        _executeOne(_borrowAction(BORROW_AMOUNT));
    }

    // ============ Exit (repay) ============

    function testShouldRepayPartOfDebt() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        uint256 debtBefore = _debt();
        uint256 vaultUsdcBefore = _vaultUsdc();
        uint256 repayAmount = 4_000e6;

        // when
        _executeOne(_repayAction(repayAmount));

        // then
        assertApproxEqAbs(_debt(), debtBefore - repayAmount, COMET_ROUNDING_TOLERANCE, "debt");
        assertEq(_vaultUsdc(), vaultUsdcBefore - repayAmount, "vault USDC");
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "base supply");
        assertEq(_collateral(WETH), WETH_COLLATERAL, "collateral");
    }

    function testShouldAllowPartialRepayLeavingDebtBelowBaseBorrowMin() public {
        // given
        uint256 baseBorrowMin = ICometCompoundV3BorrowFuseTest(COMET).baseBorrowMin();
        _openWethPosition(1_000e6);
        uint256 debtBefore = _debt();
        uint256 repayAmount = 950e6;

        // when
        _executeOne(_repayAction(repayAmount));

        // then
        uint256 debtAfter = _debt();
        assertApproxEqAbs(debtAfter, debtBefore - repayAmount, COMET_ROUNDING_TOLERANCE, "debt");
        assertGt(debtAfter, 0, "debt still open");
        assertLt(debtAfter, baseBorrowMin, "debt below baseBorrowMin");
    }

    function testShouldRepayFullDebtLeavingZeroBorrowBalance() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        uint256 debt = _debt();
        assertGt(debt, BORROW_AMOUNT, "interest accrued");
        uint256 interestShortfall = debt - _vaultUsdc();
        // fund only the accrued-interest shortfall
        deal(USDC, address(plasmaVault), _vaultUsdc() + interestShortfall);
        assertEq(_vaultUsdc(), debt, "vault holds exactly the debt");

        // when
        _executeOne(_repayAction(debt));

        // then
        assertEq(_debt(), 0, "borrow balance");
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "base supply");
        assertEq(_vaultUsdc(), 0, "vault USDC spent");
        assertEq(IERC20(USDC).allowance(address(plasmaVault), COMET), 0, "allowance");
    }

    function testShouldCapRepayAtOutstandingDebt() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        uint256 debt = _debt();
        deal(USDC, address(plasmaVault), 3 * debt);
        uint256 vaultUsdcBefore = _vaultUsdc();

        // then
        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit CompoundV3BorrowFuse.CompoundV3BorrowFuseExit(address(borrowFuse), USDC, COMET, debt);

        // when
        _executeOne(_repayAction(2 * debt));

        // then
        assertEq(_debt(), 0, "borrow balance");
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "no base supply created");
        assertEq(_vaultUsdc(), vaultUsdcBefore - debt, "vault keeps the excess USDC");
        assertEq(IERC20(USDC).allowance(address(plasmaVault), COMET), 0, "allowance");
    }

    function testShouldRepayWithMaxUint() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        // Comet rounds the debt up, so keep a small buffer above the borrowed USDC
        deal(USDC, address(plasmaVault), _vaultUsdc() + 1e6);
        uint256 debt = _debt();
        uint256 vaultUsdcBefore = _vaultUsdc();

        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit CompoundV3BorrowFuse.CompoundV3BorrowFuseExit(address(borrowFuse), USDC, COMET, debt);

        // when
        _executeOne(_repayAction(type(uint256).max));

        // then
        assertEq(_debt(), 0, "borrow balance");
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "base supply");
        assertEq(_vaultUsdc(), vaultUsdcBefore - debt, "vault USDC");
        assertEq(_collateral(WETH), WETH_COLLATERAL, "collateral untouched");
    }

    function testShouldReturnZeroWhenRepayAmountIsZero() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        uint256 debtBefore = _debt();
        uint256 vaultUsdcBefore = _vaultUsdc();

        // direct call: the zero-amount path touches no storage, so the return values can be read without the vault
        (address asset, address market, uint256 amount) = borrowFuse.exit(CompoundV3BorrowFuseExitData({amount: 0}));
        assertEq(asset, USDC, "returned asset");
        assertEq(market, COMET, "returned market");
        assertEq(amount, 0, "returned amount");

        // when
        vm.recordLogs();
        _executeOne(_repayAction(0));

        // then
        _assertNoFuseEvent(CompoundV3BorrowFuse.CompoundV3BorrowFuseExit.selector);
        assertEq(_debt(), debtBefore, "debt");
        assertEq(_vaultUsdc(), vaultUsdcBefore, "vault USDC");
    }

    function testShouldReturnZeroWhenNoDebt() public {
        // given - USDC granted, idle USDC in the vault, but no debt on Comet
        deal(USDC, address(plasmaVault), BORROW_AMOUNT);
        assertEq(_debt(), 0, "no debt");
        uint256 vaultUsdcBefore = _vaultUsdc();

        // when
        vm.recordLogs();
        _executeOne(_repayAction(BORROW_AMOUNT));

        // then - nothing supplied to Comet, no allowance, no event
        _assertNoFuseEvent(CompoundV3BorrowFuse.CompoundV3BorrowFuseExit.selector);
        assertEq(_vaultUsdc(), vaultUsdcBefore, "vault USDC");
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "no base supply created");
        assertEq(_debt(), 0, "debt");
        assertEq(IERC20(USDC).allowance(address(plasmaVault), COMET), 0, "allowance");
    }

    function testShouldRevertRepayWhenBaseTokenNotGranted() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        _grantMarketSubstrates(_collateralSubstrates());

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(CompoundV3BorrowFuse.CompoundV3BorrowFuseUnsupportedAsset.selector, "exit", USDC)
        );
        _executeOne(_repayAction(BORROW_AMOUNT));
    }

    function testShouldRevertRepayWhenVaultHasInsufficientUsdc() public {
        // given - the vault holds exactly the borrowed USDC, accrued interest makes the debt larger
        _openWethPosition(BORROW_AMOUNT);
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        uint256 debt = _debt();
        uint256 vaultUsdc = _vaultUsdc();
        assertEq(vaultUsdc, BORROW_AMOUNT, "vault USDC");
        assertGt(debt, vaultUsdc + 1, "debt above idle USDC");

        // when / then - partial repay above the idle USDC (amount < debt)
        vm.expectRevert(bytes("ERC20: transfer amount exceeds balance"));
        _executeOne(_repayAction(vaultUsdc + 1));

        // when / then - full repay (amount >= debt)
        vm.expectRevert(bytes("ERC20: transfer amount exceeds balance"));
        _executeOne(_repayAction(type(uint256).max));

        assertEq(_debt(), debt, "debt unchanged");
        assertEq(_vaultUsdc(), vaultUsdc, "vault USDC unchanged");
    }

    /// @dev Asserts no residual allowance after repay. Comet always pulls exactly the approved amount, so this test
    ///      alone cannot distinguish the explicit `forceApprove(COMET, 0)` revoke from allowance consumed by transferFrom.
    function testShouldLeaveZeroAllowanceAfterRepay() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        deal(USDC, address(plasmaVault), _vaultUsdc() + 1e6);

        // when - partial
        _executeOne(_repayAction(BORROW_AMOUNT / 2));

        // then
        assertGt(_debt(), 0, "debt after partial repay");
        assertEq(IERC20(USDC).allowance(address(plasmaVault), COMET), 0, "allowance after partial repay");

        // when - full
        _executeOne(_repayAction(BORROW_AMOUNT));

        // then
        assertEq(_debt(), 0, "debt after full repay");
        assertEq(IERC20(USDC).allowance(address(plasmaVault), COMET), 0, "allowance after full repay");
    }

    function testShouldEmitExitEvent() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        uint256 repayAmount = 2_500e6;

        // then
        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit CompoundV3BorrowFuse.CompoundV3BorrowFuseExit(address(borrowFuse), USDC, COMET, repayAmount);

        // when
        _executeOne(_repayAction(repayAmount));
    }

    // ============ Transient ============

    function testShouldBorrowTransient() public {
        // given
        _supplyCollateral(WETH, WETH_COLLATERAL);
        uint256 vaultUsdcBefore = _vaultUsdc();

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = _setInputsAction(BORROW_AMOUNT);
        actions[1] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(CompoundV3BorrowFuse.enterTransient, ())
        });

        // then
        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit CompoundV3BorrowFuse.CompoundV3BorrowFuseEnter(address(borrowFuse), USDC, COMET, BORROW_AMOUNT);

        // when
        _execute(actions);

        // then
        assertApproxEqAbs(_debt(), BORROW_AMOUNT, COMET_ROUNDING_TOLERANCE, "debt");
        assertEq(_vaultUsdc(), vaultUsdcBefore + BORROW_AMOUNT, "vault USDC");
    }

    function testShouldRepayTransient() public {
        // given
        _openWethPosition(BORROW_AMOUNT);
        uint256 debtBefore = _debt();
        uint256 vaultUsdcBefore = _vaultUsdc();
        uint256 repayAmount = 6_000e6;

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = _setInputsAction(repayAmount);
        actions[1] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(CompoundV3BorrowFuse.exitTransient, ())
        });

        // then
        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit CompoundV3BorrowFuse.CompoundV3BorrowFuseExit(address(borrowFuse), USDC, COMET, repayAmount);

        // when
        _execute(actions);

        // then
        assertApproxEqAbs(_debt(), debtBefore - repayAmount, COMET_ROUNDING_TOLERANCE, "debt");
        assertEq(_vaultUsdc(), vaultUsdcBefore - repayAmount, "vault USDC");
        assertEq(IERC20(USDC).allowance(address(plasmaVault), COMET), 0, "allowance");
    }

    // ============ Scenario helpers ============

    function _assertBorrowAgainstCollateral(address collateral_, uint256 collateralAmount_, uint256 borrow_) private {
        // given
        _supplyCollateral(collateral_, collateralAmount_);
        assertEq(_collateral(collateral_), collateralAmount_, "collateral supplied");
        assertLt(borrow_, _cometBorrowLimit(collateral_, collateralAmount_), "borrow within Comet limit");

        uint256 vaultUsdcBefore = _vaultUsdc();
        uint256 totalAssetsBefore = plasmaVault.totalAssets();

        // when
        _executeOne(_borrowAction(borrow_));

        // then
        assertEq(_vaultUsdc(), vaultUsdcBefore + borrow_, "vault USDC increased by exactly the borrowed amount");
        assertApproxEqAbs(_debt(), borrow_, COMET_ROUNDING_TOLERANCE, "debt");
        assertEq(IComet(COMET).balanceOf(address(plasmaVault)), 0, "no base supply");
        assertEq(_collateral(collateral_), collateralAmount_, "collateral unchanged");
        assertApproxEqAbs(plasmaVault.totalAssets(), totalAssetsBefore, NAV_TOLERANCE, "totalAssets unchanged");
    }

    function _openWethPosition(uint256 borrow_) private {
        _supplyCollateral(WETH, WETH_COLLATERAL);
        _executeOne(_borrowAction(borrow_));
        assertApproxEqAbs(_debt(), borrow_, COMET_ROUNDING_TOLERANCE, "opened debt");
    }

    function _supplyCollateral(address asset_, uint256 amount_) private {
        deal(asset_, address(plasmaVault), amount_);
        _executeOne(_supplyAction(asset_, amount_));
    }

    // ============ Setup ============

    function _deployPriceOracleMiddleware() private {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(CHAINLINK_FEED_REGISTRY);
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", atomist))
        );

        address[] memory assets = new address[](4);
        address[] memory sources = new address[](4);
        assets[0] = USDC;
        sources[0] = USDC_USD_SOURCE;
        assets[1] = WETH;
        sources[1] = ETH_USD_SOURCE;
        assets[2] = WSTETH;
        sources[2] = WSTETH_USD_SOURCE;
        assets[3] = WBTC;
        sources[3] = WBTC_USD_SOURCE;
        // cbBTC: no explicit source, priced through the Chainlink Feed Registry fallback

        vm.prank(atomist);
        PriceOracleMiddleware(priceOracleMiddleware).setAssetsPricesSources(assets, sources);
    }

    function _deployVault() private {
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: USDC,
            underlyingTokenName: "USDC",
            priceOracleMiddleware: priceOracleMiddleware,
            atomist: atomist
        });

        vm.startPrank(atomist);
        (plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);
        IporFusionAccessManager accessManager = IporFusionAccessManager(plasmaVault.authority());

        IporFusionAccessManagerHelper.RoleAddresses memory roles = IporFusionAccessManagerHelper.RoleAddresses({
            daos: new address[](1),
            admins: new address[](1),
            owners: new address[](1),
            atomists: new address[](1),
            alphas: new address[](1),
            guardians: new address[](1),
            fuseManagers: new address[](1),
            claimRewards: new address[](1),
            transferRewardsManagers: new address[](1),
            configInstantWithdrawalFusesManagers: new address[](1),
            updateMarketsBalancesAccounts: new address[](1),
            updateRewardsBalanceAccounts: new address[](1),
            withdrawManagerRequestFeeManagers: new address[](1),
            withdrawManagerWithdrawFeeManagers: new address[](1),
            priceOracleMiddlewareManagers: new address[](1),
            whitelist: new address[](1),
            preHooksManagers: new address[](1)
        });

        roles.daos[0] = atomist;
        roles.admins[0] = atomist;
        roles.owners[0] = atomist;
        roles.atomists[0] = atomist;
        roles.alphas[0] = alpha;
        roles.guardians[0] = atomist;
        roles.fuseManagers[0] = atomist;
        roles.claimRewards[0] = alpha;
        roles.transferRewardsManagers[0] = alpha;
        roles.configInstantWithdrawalFusesManagers[0] = atomist;
        roles.updateMarketsBalancesAccounts[0] = atomist;
        roles.updateRewardsBalanceAccounts[0] = alpha;
        roles.withdrawManagerRequestFeeManagers[0] = atomist;
        roles.withdrawManagerWithdrawFeeManagers[0] = atomist;
        roles.priceOracleMiddlewareManagers[0] = atomist;
        roles.whitelist[0] = user;
        roles.preHooksManagers[0] = atomist;

        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            plasmaVault,
            roles,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );
        vm.stopPrank();
    }

    function _configureVault() private {
        supplyFuse = new CompoundV3SupplyFuse(MARKET_ID, COMET);
        borrowFuse = new CompoundV3BorrowFuse(MARKET_ID, COMET);
        balanceFuse = new CompoundV3WithPriceOracleMiddlewareBalanceFuse(MARKET_ID, COMET);
        erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        setInputsFuse = new TransientStorageSetInputsFuse();

        address[] memory fuses = new address[](3);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(borrowFuse);
        fuses[2] = address(setInputsFuse);

        bytes32[] memory compoundSubstrates = new bytes32[](5);
        compoundSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        bytes32[] memory collaterals = _collateralSubstrates();
        for (uint256 i; i < collaterals.length; ++i) {
            compoundSubstrates[i + 1] = collaterals[i];
        }

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        vm.startPrank(atomist);
        PlasmaVaultHelper.addFusesToVault(plasmaVault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(plasmaVault, MARKET_ID, address(balanceFuse));
        PlasmaVaultHelper.addBalanceFusesToVault(
            plasmaVault,
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(erc20BalanceFuse)
        );
        PlasmaVaultHelper.addSubstratesToMarket(plasmaVault, MARKET_ID, compoundSubstrates);
        PlasmaVaultHelper.addSubstratesToMarket(plasmaVault, IporFusionMarkets.ERC20_VAULT_BALANCE, collaterals);
        PlasmaVaultHelper.addDependencyBalanceGraphs(plasmaVault, MARKET_ID, dependencies);
        vm.stopPrank();

        vm.label(address(plasmaVault), "PlasmaVault");
        vm.label(COMET, "cUSDCv3");
        vm.label(address(supplyFuse), "CompoundV3SupplyFuse");
        vm.label(address(borrowFuse), "CompoundV3BorrowFuse");
        vm.label(address(balanceFuse), "CompoundV3WithPriceOracleMiddlewareBalanceFuse");
    }

    function _collateralSubstrates() private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](4);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(CBBTC);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        substrates[2] = PlasmaVaultConfigLib.addressToBytes32(WSTETH);
        substrates[3] = PlasmaVaultConfigLib.addressToBytes32(WBTC);
    }

    function _grantMarketSubstrates(bytes32[] memory substrates_) private {
        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(MARKET_ID, substrates_);
    }

    // ============ Execution helpers ============

    function _execute(FuseAction[] memory actions_) private {
        vm.prank(alpha);
        plasmaVault.execute(actions_);
    }

    function _executeOne(FuseAction memory action_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = action_;
        _execute(actions);
    }

    function _supplyAction(address asset_, uint256 amount_) private view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: address(supplyFuse),
                data: abi.encodeCall(
                    CompoundV3SupplyFuse.enter,
                    (CompoundV3SupplyFuseEnterData({asset: asset_, amount: amount_}))
                )
            });
    }

    function _borrowAction(uint256 amount_) private view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: address(borrowFuse),
                data: abi.encodeCall(CompoundV3BorrowFuse.enter, (CompoundV3BorrowFuseEnterData({amount: amount_})))
            });
    }

    function _repayAction(uint256 amount_) private view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: address(borrowFuse),
                data: abi.encodeCall(CompoundV3BorrowFuse.exit, (CompoundV3BorrowFuseExitData({amount: amount_})))
            });
    }

    function _setInputsAction(uint256 amount_) private view returns (FuseAction memory) {
        address[] memory fuses = new address[](1);
        fuses[0] = address(borrowFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = bytes32(amount_);

        return
            FuseAction({
                fuse: address(setInputsFuse),
                data: abi.encodeCall(
                    TransientStorageSetInputsFuse.enter,
                    (TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse}))
                )
            });
    }

    // ============ View helpers ============

    function _debt() private view returns (uint256) {
        return IComet(COMET).borrowBalanceOf(address(plasmaVault));
    }

    function _collateral(address asset_) private view returns (uint256) {
        return IComet(COMET).collateralBalanceOf(address(plasmaVault), asset_);
    }

    function _vaultUsdc() private view returns (uint256) {
        return IERC20(USDC).balanceOf(address(plasmaVault));
    }

    /// @dev Maximum base borrow allowed by Comet for a sole collateral, from Comet prices and borrowCollateralFactor
    function _cometBorrowLimit(address asset_, uint256 amount_) private view returns (uint256) {
        IComet.AssetInfo memory info = IComet(COMET).getAssetInfoByAddress(asset_);
        uint256 collateralPrice = IComet(COMET).getPrice(info.priceFeed);
        uint256 basePrice = IComet(COMET).getPrice(IComet(COMET).baseTokenPriceFeed());
        uint256 collateralValue = (amount_ * collateralPrice) / info.scale;
        uint256 borrowCapacity = (collateralValue * info.borrowCollateralFactor) / 1e18;
        return (borrowCapacity * 1e6) / basePrice;
    }

    /// @dev Asserts that no log with the given topic0 was emitted by the vault since vm.recordLogs()
    function _assertNoFuseEvent(bytes32 topic0_) private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(plasmaVault) && logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != topic0_, "unexpected fuse event");
            }
        }
    }
}
