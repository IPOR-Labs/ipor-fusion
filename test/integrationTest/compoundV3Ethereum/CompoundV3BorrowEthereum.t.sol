// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CompoundV3BalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
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
import {
    TransientStorageSetInputsFuse,
    TransientStorageSetInputsFuseEnterData
} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {FusesLib} from "../../../contracts/libraries/FusesLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {FeeManager} from "../../../contracts/managers/fee/FeeManager.sol";
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

/// @notice Test-local view of the real cUSDCv3 Comet (errors and views not present in the production IComet interface)
interface ICometCompoundV3BorrowEthereum {
    error NotCollateralized();
    error BorrowTooSmall();

    function baseScale() external view returns (uint256);

    function baseBorrowMin() external view returns (uint256);

    function isBorrowCollateralized(address account) external view returns (bool);
}

/// @title Shared fork setup for the Compound V3 USDC borrow end-to-end tests on Ethereum
/// @notice Deploys real PlasmaVaults (PlasmaVault + PlasmaVaultGovernance + IporFusionAccessManager + FeeManager +
///         WithdrawManager) with a real PriceOracleMiddleware (ERC1967 proxy, production sources) against the real
///         cUSDCv3 Comet. No mocks, no etch, no store.
abstract contract CompoundV3BorrowEthereumSetup is Test {
    uint256 internal constant FORK_BLOCK = 25982679;

    address internal constant COMET_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant CB_BTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address internal constant USDC_USD_SOURCE = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant ETH_USD_SOURCE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant WST_ETH_USD_SOURCE = 0x4329e2178D41D058Cf2808c11436A9e83BC5D8b0;
    address internal constant WBTC_USD_SOURCE = 0x106f9537Dd66423E6674e85CA187B43055B59fe9;
    address internal constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    uint256 internal constant COMPOUND_MARKET_ID = IporFusionMarkets.COMPOUND_V3_USDC;
    uint256 internal constant ERC20_MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;

    /// @dev 10% IPOR DAO performance fee (2 decimals precision, 10000 = 100%)
    uint256 internal constant PERFORMANCE_FEE_IN_PERCENTAGE = 1000;

    uint256 internal constant BORROW_AMOUNT = 40_000e6;
    uint256 internal constant PARTIAL_REPAY_AMOUNT = 15_000e6;

    IComet internal constant COMET = IComet(COMET_USDC);
    ICometCompoundV3BorrowEthereum internal constant COMET_EXT = ICometCompoundV3BorrowEthereum(COMET_USDC);

    address internal admin;
    address internal alpha;
    address internal user;
    address internal daoFeeRecipient;

    PriceOracleMiddleware internal priceOracleMiddleware;
    CompoundV3SupplyFuse internal supplyFuse;
    CompoundV3BorrowFuse internal borrowFuse;
    CompoundV3WithPriceOracleMiddlewareBalanceFuse internal balanceFuse;
    ERC20BalanceFuse internal erc20BalanceFuse;
    TransientStorageSetInputsFuse internal transientStorageSetInputsFuse;

    function _setUpForkAndFuses() internal {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        admin = makeAddr("admin");
        alpha = makeAddr("alpha");
        user = makeAddr("user");
        daoFeeRecipient = makeAddr("daoFeeRecipient");

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(CHAINLINK_FEED_REGISTRY);
        priceOracleMiddleware = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin)))
        );

        address[] memory assets = new address[](4);
        address[] memory sources = new address[](4);
        assets[0] = USDC;
        sources[0] = USDC_USD_SOURCE;
        assets[1] = WETH;
        sources[1] = ETH_USD_SOURCE;
        assets[2] = WST_ETH;
        sources[2] = WST_ETH_USD_SOURCE;
        assets[3] = WBTC;
        sources[3] = WBTC_USD_SOURCE;
        /// @dev cbBTC has no explicit source: priced through the Chainlink Feed Registry fallback (production setup)

        vm.prank(admin);
        priceOracleMiddleware.setAssetsPricesSources(assets, sources);

        supplyFuse = new CompoundV3SupplyFuse(COMPOUND_MARKET_ID, COMET_USDC);
        borrowFuse = new CompoundV3BorrowFuse(COMPOUND_MARKET_ID, COMET_USDC);
        balanceFuse = new CompoundV3WithPriceOracleMiddlewareBalanceFuse(COMPOUND_MARKET_ID, COMET_USDC);
        erc20BalanceFuse = new ERC20BalanceFuse(ERC20_MARKET_ID);
        transientStorageSetInputsFuse = new TransientStorageSetInputsFuse();
    }

    // ------------------------------------------------------------------------------------------------
    // Vault deployment
    // ------------------------------------------------------------------------------------------------

    function _deployVault(address underlying_, address compoundBalanceFuse_) internal returns (PlasmaVault vault) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = admin;
        usersToRoles.atomist = admin;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;

        IporFusionAccessManager accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vault = new PlasmaVault();

        vm.prank(admin);
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Compound V3 Borrow Vault",
                assetSymbol: "cv3BRW",
                underlyingToken: underlying_,
                priceOracleMiddleware: address(priceOracleMiddleware),
                feeConfig: FeeConfig({
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: PERFORMANCE_FEE_IN_PERCENTAGE,
                    iporDaoFeeRecipientAddress: daoFeeRecipient
                }),
                accessManager: address(accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(vault), accessManager, withdrawManager);

        address[] memory fuses = new address[](3);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(borrowFuse);
        fuses[2] = address(transientStorageSetInputsFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(COMPOUND_MARKET_ID, compoundBalanceFuse_);
        balanceFuses[1] = MarketBalanceFuseConfig(ERC20_MARKET_ID, address(erc20BalanceFuse));

        bytes32[] memory erc20Substrates = new bytes32[](1);
        erc20Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);
        marketConfigs[0] = MarketSubstratesConfig(COMPOUND_MARKET_ID, _compoundSubstrates(true));
        marketConfigs[1] = MarketSubstratesConfig(ERC20_MARKET_ID, erc20Substrates);

        PlasmaVaultConfigurator.setupPlasmaVault(vm, admin, address(vault), fuses, balanceFuses, marketConfigs);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = COMPOUND_MARKET_ID;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = ERC20_MARKET_ID;

        vm.prank(admin);
        PlasmaVaultGovernance(address(vault)).updateDependencyBalanceGraphs(marketIds, dependencies);

        assertEq(
            PlasmaVaultGovernance(address(vault)).getPerformanceFeeData().feeInPercentage,
            PERFORMANCE_FEE_IN_PERCENTAGE,
            "performance fee configured"
        );
    }

    function _compoundSubstrates(bool includeUsdc_) internal pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](includeUsdc_ ? 5 : 4);
        uint256 i;
        if (includeUsdc_) {
            substrates[i++] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        }
        substrates[i++] = PlasmaVaultConfigLib.addressToBytes32(CB_BTC);
        substrates[i++] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        substrates[i++] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        substrates[i] = PlasmaVaultConfigLib.addressToBytes32(WBTC);
    }

    function _compoundSubstrateAssets() internal pure returns (address[] memory assets) {
        assets = new address[](5);
        assets[0] = USDC;
        assets[1] = CB_BTC;
        assets[2] = WETH;
        assets[3] = WST_ETH;
        assets[4] = WBTC;
    }

    // ------------------------------------------------------------------------------------------------
    // Vault actions (all protocol actions through PlasmaVault.execute as alpha)
    // ------------------------------------------------------------------------------------------------

    function _depositToVault(PlasmaVault vault_, uint256 amount_) internal returns (uint256 shares) {
        address underlying = vault_.asset();
        deal(underlying, user, amount_);
        vm.startPrank(user);
        ERC20(underlying).approve(address(vault_), amount_);
        shares = vault_.deposit(amount_, user);
        vm.stopPrank();
    }

    function _execute(PlasmaVault vault_, FuseAction[] memory calls_) internal {
        vm.prank(alpha);
        vault_.execute(calls_);
    }

    function _supplyCollateralAction(address asset_, uint256 amount_) internal view returns (FuseAction memory) {
        return
            FuseAction(
                address(supplyFuse),
                abi.encodeCall(
                    CompoundV3SupplyFuse.enter,
                    (CompoundV3SupplyFuseEnterData({asset: asset_, amount: amount_}))
                )
            );
    }

    function _withdrawCollateralAction(address asset_, uint256 amount_) internal view returns (FuseAction memory) {
        return
            FuseAction(
                address(supplyFuse),
                abi.encodeCall(
                    CompoundV3SupplyFuse.exit,
                    (CompoundV3SupplyFuseExitData({asset: asset_, amount: amount_}))
                )
            );
    }

    function _borrowAction(address fuse_, uint256 amount_) internal pure returns (FuseAction memory) {
        return
            FuseAction(
                fuse_,
                abi.encodeCall(CompoundV3BorrowFuse.enter, (CompoundV3BorrowFuseEnterData({amount: amount_})))
            );
    }

    function _repayAction(uint256 amount_) internal view returns (FuseAction memory) {
        return
            FuseAction(
                address(borrowFuse),
                abi.encodeCall(CompoundV3BorrowFuse.exit, (CompoundV3BorrowFuseExitData({amount: amount_})))
            );
    }

    function _single(FuseAction memory action_) internal pure returns (FuseAction[] memory calls) {
        calls = new FuseAction[](1);
        calls[0] = action_;
    }

    function _supplyCollateral(PlasmaVault vault_, address asset_, uint256 amount_) internal {
        _execute(vault_, _single(_supplyCollateralAction(asset_, amount_)));
    }

    function _withdrawCollateral(PlasmaVault vault_, address asset_, uint256 amount_) internal {
        _execute(vault_, _single(_withdrawCollateralAction(asset_, amount_)));
    }

    function _borrow(PlasmaVault vault_, uint256 amount_) internal {
        _execute(vault_, _single(_borrowAction(address(borrowFuse), amount_)));
    }

    function _repay(PlasmaVault vault_, uint256 amount_) internal {
        _execute(vault_, _single(_repayAction(amount_)));
    }

    function _refreshCompoundMarket(PlasmaVault vault_) internal {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = COMPOUND_MARKET_ID;
        vm.prank(admin);
        vault_.updateMarketsBalances(marketIds);
    }

    /// @dev Comet stores debt as principal and presents it through the borrow index, so the presented debt can exceed
    ///      the idle USDC originally borrowed by a few base units. Funds only that shortfall (test funding).
    function _fundRepayShortfall(PlasmaVault vault_) internal returns (uint256 shortfall) {
        uint256 debt = COMET.borrowBalanceOf(address(vault_));
        uint256 idle = ERC20(USDC).balanceOf(address(vault_));
        if (debt > idle) {
            shortfall = debt - idle;
            deal(USDC, address(vault_), debt);
        }
    }

    function _performanceFeeAccount(PlasmaVault vault_) internal view returns (address) {
        return PlasmaVaultGovernance(address(vault_)).getPerformanceFeeData().feeAccount;
    }

    // ------------------------------------------------------------------------------------------------
    // Expected values (reproduce the balance fuse USD WAD value and PlasmaVaultMarketsLib conversion)
    // ------------------------------------------------------------------------------------------------

    /// @dev Mirrors IporMath.convertToWadInt / convertToWad for non-negative values:
    ///      decimals > 18 -> division rounded half up (IporMath.divisionInt), decimals < 18 -> exact multiplication
    function _toWad(uint256 value_, uint256 decimals_) internal pure returns (uint256) {
        if (value_ == 0 || decimals_ == 18) {
            return value_;
        }
        if (decimals_ > 18) {
            uint256 divisor = 10 ** (decimals_ - 18);
            return (value_ + divisor / 2) / divisor;
        }
        return value_ * 10 ** (18 - decimals_);
    }

    /// @dev Expected CompoundV3WithPriceOracleMiddlewareBalanceFuse.balanceOf() of the vault, in USD WAD:
    ///      sum(position x middleware price) - borrowBalanceOf x middleware price(USDC)
    function _expectedCompoundUsdWad(PlasmaVault vault_) internal view returns (int256 usdWad) {
        address[] memory assets = _compoundSubstrateAssets();
        for (uint256 i; i < assets.length; ++i) {
            uint256 amount = assets[i] == USDC
                ? COMET.balanceOf(address(vault_))
                : COMET.collateralBalanceOf(address(vault_), assets[i]);
            if (amount == 0) {
                continue;
            }
            (uint256 price, uint256 priceDecimals) = priceOracleMiddleware.getAssetPrice(assets[i]);
            usdWad += int256(_toWad(amount * price, ERC20(assets[i]).decimals() + priceDecimals));
        }

        uint256 debt = COMET.borrowBalanceOf(address(vault_));
        if (debt > 0) {
            (uint256 usdcPrice, uint256 usdcPriceDecimals) = priceOracleMiddleware.getAssetPrice(USDC);
            usdWad -= int256(_toWad(debt * usdcPrice, 6 + usdcPriceDecimals));
        }
    }

    /// @dev Expected legacy CompoundV3BalanceFuse.balanceOf() of the vault, in USD WAD (Comet prices, 8 decimals)
    function _expectedLegacyCompoundUsdWad(PlasmaVault vault_) internal view returns (uint256) {
        address[] memory assets = _compoundSubstrateAssets();
        int256 usdWad;
        for (uint256 i; i < assets.length; ++i) {
            uint256 amount;
            uint256 price;
            if (assets[i] == USDC) {
                amount = COMET.balanceOf(address(vault_));
                price = COMET.getPrice(COMET.baseTokenPriceFeed());
            } else {
                amount = COMET.collateralBalanceOf(address(vault_), assets[i]);
                price = COMET.getPrice(COMET.getAssetInfoByAddress(assets[i]).priceFeed);
            }
            usdWad += int256(_toWad(amount * price, ERC20(assets[i]).decimals() + 8));
        }
        uint256 debt = COMET.borrowBalanceOf(address(vault_));
        usdWad -= int256(_toWad(debt * COMET.getPrice(COMET.baseTokenPriceFeed()), 6 + 8));
        return uint256(usdWad);
    }

    /// @dev Mirrors PlasmaVaultMarketsLib.updateMarketsBalances: floor(usdWad x 10^priceDecimals / price) as WAD,
    ///      then IporMath.convertWadToAssetDecimals (floor division for underlying decimals < 18)
    function _usdWadToUnderlying(PlasmaVault vault_, uint256 usdWad_) internal view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = priceOracleMiddleware.getAssetPrice(vault_.asset());
        uint256 wadAmount = (usdWad_ * 10 ** priceDecimals) / price;
        uint256 underlyingDecimals = ERC20(vault_.asset()).decimals();
        if (underlyingDecimals == 18) {
            return wadAmount;
        }
        return wadAmount / 10 ** (18 - underlyingDecimals);
    }

    function _expectedCompoundMarketBalance(PlasmaVault vault_) internal view returns (uint256) {
        int256 usdWad = _expectedCompoundUsdWad(vault_);
        assertGe(usdWad, 0, "expected Compound net value must not be negative");
        return _usdWadToUnderlying(vault_, uint256(usdWad));
    }

    function _expectedErc20MarketBalance(PlasmaVault vault_) internal view returns (uint256) {
        if (vault_.asset() == USDC) {
            return 0;
        }
        (uint256 price, uint256 priceDecimals) = priceOracleMiddleware.getAssetPrice(USDC);
        return _usdWadToUnderlying(vault_, _toWad(ERC20(USDC).balanceOf(address(vault_)) * price, 6 + priceDecimals));
    }

    /// @dev Rounding budget for totalAssets() in same-block steps, in underlying units:
    ///      - each market value is floored once to WAD-of-underlying and once to underlying decimals (<= 2 units x 2 markets),
    ///      - USD WAD terms are rounded half up (< 1 USD-wei each, far below one underlying unit),
    ///      - Comet principal/index rounding can make the presented debt exceed the borrowed USDC by a few base units
    ///        (budget: 4 USDC base units valued in the underlying, rounded up).
    function _roundingTolerance(PlasmaVault vault_) internal view returns (uint256) {
        (uint256 usdcPrice, uint256 usdcPriceDecimals) = priceOracleMiddleware.getAssetPrice(USDC);
        uint256 usdcDustUsdWad = _toWad(4 * usdcPrice, 6 + usdcPriceDecimals);
        return 4 + _usdWadToUnderlying(vault_, usdcDustUsdWad) + 1;
    }

    function _assertMarketsMatchExpected(PlasmaVault vault_, string memory step_) internal view {
        assertEq(
            vault_.totalAssetsInMarket(COMPOUND_MARKET_ID),
            _expectedCompoundMarketBalance(vault_),
            string.concat(step_, ": Compound V3 market balance")
        );
        assertEq(
            vault_.totalAssetsInMarket(ERC20_MARKET_ID),
            _expectedErc20MarketBalance(vault_),
            string.concat(step_, ": ERC20 vault balance market")
        );
        assertEq(
            vault_.totalAssets(),
            ERC20(vault_.asset()).balanceOf(address(vault_)) +
                vault_.totalAssetsInMarket(COMPOUND_MARKET_ID) +
                vault_.totalAssetsInMarket(ERC20_MARKET_ID),
            string.concat(step_, ": totalAssets composition")
        );
    }

    function _assertTotalAssetsUnchanged(
        PlasmaVault vault_,
        uint256 referenceTotalAssets_,
        string memory step_
    ) internal view {
        assertApproxEqAbs(
            vault_.totalAssets(),
            referenceTotalAssets_,
            _roundingTolerance(vault_),
            string.concat(step_, ": totalAssets unchanged within rounding")
        );
    }
}

/// @title Compound V3 USDC borrow scenarios executed against a fresh vault whose underlying is the tested collateral
abstract contract CompoundV3BorrowEthereumScenarios is CompoundV3BorrowEthereumSetup {
    PlasmaVault internal plasmaVault;
    address internal collateral;
    uint256 internal collateralAmount;

    function _collateral() internal pure virtual returns (address);

    /// @dev ~100k USD of collateral at the fork block
    function _collateralAmount() internal pure virtual returns (uint256);

    function setUp() public {
        _setUpForkAndFuses();
        collateral = _collateral();
        collateralAmount = _collateralAmount();
        plasmaVault = _deployVault(collateral, address(balanceFuse));
    }

    function testShouldExecuteFullBorrowLifecycle() public {
        // step 1: user deposit (real ERC-4626 flow)
        _depositToVault(plasmaVault, collateralAmount);

        uint256 referenceTotalAssets = plasmaVault.totalAssets();
        assertEq(referenceTotalAssets, collateralAmount, "deposit: totalAssets");
        assertEq(plasmaVault.totalAssetsInMarket(COMPOUND_MARKET_ID), 0, "deposit: market balance");

        // step 2: supply collateral
        _supplyCollateral(plasmaVault, collateral, collateralAmount);

        assertEq(ERC20(collateral).balanceOf(address(plasmaVault)), 0, "supply: idle collateral");
        assertEq(
            COMET.collateralBalanceOf(address(plasmaVault), collateral),
            collateralAmount,
            "supply: Comet collateral"
        );
        assertEq(COMET.borrowBalanceOf(address(plasmaVault)), 0, "supply: debt");
        assertGt(plasmaVault.totalAssetsInMarket(COMPOUND_MARKET_ID), 0, "supply: market balance positive");
        _assertMarketsMatchExpected(plasmaVault, "supply");
        _assertTotalAssetsUnchanged(plasmaVault, referenceTotalAssets, "supply");

        // step 3: borrow
        _borrow(plasmaVault, BORROW_AMOUNT);

        uint256 debtAfterBorrow = COMET.borrowBalanceOf(address(plasmaVault));
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), BORROW_AMOUNT, "borrow: idle USDC");
        assertGe(debtAfterBorrow, BORROW_AMOUNT, "borrow: debt >= borrowed");
        assertApproxEqAbs(debtAfterBorrow, BORROW_AMOUNT, 2, "borrow: debt");
        assertEq(COMET.balanceOf(address(plasmaVault)), 0, "borrow: base supply");
        assertEq(
            COMET.collateralBalanceOf(address(plasmaVault), collateral),
            collateralAmount,
            "borrow: Comet collateral"
        );
        assertTrue(COMET_EXT.isBorrowCollateralized(address(plasmaVault)), "borrow: collateralized");
        _assertMarketsMatchExpected(plasmaVault, "borrow");
        _assertTotalAssetsUnchanged(plasmaVault, referenceTotalAssets, "borrow");

        // step 4: repay part
        _repay(plasmaVault, PARTIAL_REPAY_AMOUNT);

        assertApproxEqAbs(
            COMET.borrowBalanceOf(address(plasmaVault)),
            debtAfterBorrow - PARTIAL_REPAY_AMOUNT,
            2,
            "repay part: debt"
        );
        assertEq(
            ERC20(USDC).balanceOf(address(plasmaVault)),
            BORROW_AMOUNT - PARTIAL_REPAY_AMOUNT,
            "repay part: idle USDC"
        );
        assertEq(COMET.balanceOf(address(plasmaVault)), 0, "repay part: base supply");
        assertEq(ERC20(USDC).allowance(address(plasmaVault), COMET_USDC), 0, "repay part: allowance");
        _assertMarketsMatchExpected(plasmaVault, "repay part");
        _assertTotalAssetsUnchanged(plasmaVault, referenceTotalAssets, "repay part");

        // step 5: repay rest
        uint256 shortfall = _fundRepayShortfall(plasmaVault);
        assertLe(shortfall, 4, "repay rest: principal rounding shortfall");
        uint256 remainingDebt = COMET.borrowBalanceOf(address(plasmaVault));

        _repay(plasmaVault, remainingDebt);

        assertEq(COMET.borrowBalanceOf(address(plasmaVault)), 0, "repay rest: debt");
        assertEq(COMET.balanceOf(address(plasmaVault)), 0, "repay rest: base supply");
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), 0, "repay rest: idle USDC");
        assertEq(ERC20(USDC).allowance(address(plasmaVault), COMET_USDC), 0, "repay rest: allowance");
        _assertMarketsMatchExpected(plasmaVault, "repay rest");
        _assertTotalAssetsUnchanged(plasmaVault, referenceTotalAssets, "repay rest");

        // step 6: withdraw collateral
        _withdrawCollateral(plasmaVault, collateral, collateralAmount);

        assertEq(COMET.collateralBalanceOf(address(plasmaVault), collateral), 0, "withdraw: Comet collateral");
        assertEq(COMET.borrowBalanceOf(address(plasmaVault)), 0, "withdraw: debt");
        assertEq(ERC20(collateral).balanceOf(address(plasmaVault)), collateralAmount, "withdraw: idle collateral");
        assertEq(plasmaVault.totalAssetsInMarket(COMPOUND_MARKET_ID), 0, "withdraw: market balance");
        assertEq(plasmaVault.totalAssetsInMarket(ERC20_MARKET_ID), 0, "withdraw: ERC20 market balance");
        _assertMarketsMatchExpected(plasmaVault, "withdraw");
        assertEq(plasmaVault.totalAssets(), referenceTotalAssets, "withdraw: totalAssets back to deposit");
    }

    function testShouldNotChangeTotalAssetsWhenMovingCollateralBetweenVaultAndComet() public {
        _depositToVault(plasmaVault, collateralAmount);

        /// @dev initialise the performance fee high-water mark on the real FeeManager with an unchanged NAV
        _refreshCompoundMarket(plasmaVault);

        address feeAccount = _performanceFeeAccount(plasmaVault);
        uint256 feeSharesBefore = plasmaVault.balanceOf(feeAccount);
        uint256 totalSupplyBefore = plasmaVault.totalSupply();
        uint256 referenceTotalAssets = plasmaVault.totalAssets();

        _supplyCollateral(plasmaVault, collateral, collateralAmount);

        _assertMarketsMatchExpected(plasmaVault, "supply");
        _assertTotalAssetsUnchanged(plasmaVault, referenceTotalAssets, "supply");
        assertEq(plasmaVault.balanceOf(feeAccount), feeSharesBefore, "supply: performance fee shares");

        _withdrawCollateral(plasmaVault, collateral, collateralAmount);

        assertEq(plasmaVault.totalAssets(), referenceTotalAssets, "withdraw: totalAssets");
        assertEq(plasmaVault.totalAssetsInMarket(COMPOUND_MARKET_ID), 0, "withdraw: market balance");
        assertEq(plasmaVault.balanceOf(feeAccount), feeSharesBefore, "withdraw: performance fee shares");
        assertEq(plasmaVault.totalSupply(), totalSupplyBefore, "withdraw: total supply");
    }

    function testShouldRevertBorrowAboveCollateralFactor() public {
        _depositToVault(plasmaVault, collateralAmount);
        _supplyCollateral(plasmaVault, collateral, collateralAmount);

        /// @dev Comet enforces the limit with its own feeds: liquidity = collateral x pComet / scale x borrowCF / 1e18
        IComet.AssetInfo memory assetInfo = COMET.getAssetInfoByAddress(collateral);
        uint256 collateralPrice = COMET.getPrice(assetInfo.priceFeed);
        uint256 basePrice = COMET.getPrice(COMET.baseTokenPriceFeed());
        uint256 collateralValue = (collateralAmount * collateralPrice) / assetInfo.scale;
        uint256 borrowCapacityValue = (collateralValue * assetInfo.borrowCollateralFactor) / 1e18;
        uint256 maxBorrow = (borrowCapacityValue * COMET_EXT.baseScale()) / basePrice;

        assertGt(maxBorrow, BORROW_AMOUNT, "sanity: capacity above lifecycle borrow");

        vm.expectRevert(ICometCompoundV3BorrowEthereum.NotCollateralized.selector);
        _borrow(plasmaVault, maxBorrow + 1e6);

        assertEq(COMET.borrowBalanceOf(address(plasmaVault)), 0, "no debt after revert");

        /// @dev boundary control: 1 USDC below the Comet limit succeeds
        _borrow(plasmaVault, maxBorrow - 1e6);

        assertApproxEqAbs(COMET.borrowBalanceOf(address(plasmaVault)), maxBorrow - 1e6, 2, "debt at limit");
        assertTrue(COMET_EXT.isBorrowCollateralized(address(plasmaVault)), "collateralized at limit");
        _assertMarketsMatchExpected(plasmaVault, "borrow at limit");
    }

    function testShouldCapRepayAboveDebt() public {
        _depositToVault(plasmaVault, collateralAmount);
        _supplyCollateral(plasmaVault, collateral, collateralAmount);
        _borrow(plasmaVault, BORROW_AMOUNT);

        /// @dev test funding: extra idle USDC so an inflated repay amount is fully backed
        uint256 extraUsdc = 1_000e6;
        deal(USDC, address(plasmaVault), BORROW_AMOUNT + extraUsdc);

        uint256 debt = COMET.borrowBalanceOf(address(plasmaVault));

        _repay(plasmaVault, 2 * debt);

        assertEq(COMET.borrowBalanceOf(address(plasmaVault)), 0, "debt");
        assertEq(COMET.balanceOf(address(plasmaVault)), 0, "no base supply created");
        assertEq(
            ERC20(USDC).balanceOf(address(plasmaVault)),
            BORROW_AMOUNT + extraUsdc - debt,
            "vault keeps USDC above debt"
        );
        assertEq(ERC20(USDC).allowance(address(plasmaVault), COMET_USDC), 0, "allowance");
        assertEq(COMET.collateralBalanceOf(address(plasmaVault), collateral), collateralAmount, "collateral untouched");
        _assertMarketsMatchExpected(plasmaVault, "inflated repay");
    }

    function testShouldRevertCollateralWithdrawWhileUndercollateralized() public {
        _depositToVault(plasmaVault, collateralAmount);
        _supplyCollateral(plasmaVault, collateral, collateralAmount);
        _borrow(plasmaVault, BORROW_AMOUNT);

        vm.expectRevert(ICometCompoundV3BorrowEthereum.NotCollateralized.selector);
        _withdrawCollateral(plasmaVault, collateral, collateralAmount);

        assertEq(COMET.collateralBalanceOf(address(plasmaVault), collateral), collateralAmount, "collateral unchanged");
        assertApproxEqAbs(COMET.borrowBalanceOf(address(plasmaVault)), BORROW_AMOUNT, 2, "debt unchanged");
        _assertMarketsMatchExpected(plasmaVault, "after reverted withdraw");
    }

    function testShouldRevertBorrowWhenFuseNotAddedToVault() public {
        _depositToVault(plasmaVault, collateralAmount);
        _supplyCollateral(plasmaVault, collateral, collateralAmount);

        /// @dev a correctly configured borrow fuse that was never added to the vault
        CompoundV3BorrowFuse notAddedBorrowFuse = new CompoundV3BorrowFuse(COMPOUND_MARKET_ID, COMET_USDC);

        vm.expectRevert(PlasmaVault.UnsupportedFuse.selector);
        _execute(plasmaVault, _single(_borrowAction(address(notAddedBorrowFuse), BORROW_AMOUNT)));

        /// @dev the configured borrow fuse, removed by the atomist
        address[] memory fusesToRemove = new address[](1);
        fusesToRemove[0] = address(borrowFuse);
        vm.prank(admin);
        PlasmaVaultGovernance(address(plasmaVault)).removeFuses(fusesToRemove);

        vm.expectRevert(PlasmaVault.UnsupportedFuse.selector);
        _borrow(plasmaVault, BORROW_AMOUNT);

        assertEq(COMET.borrowBalanceOf(address(plasmaVault)), 0, "debt");
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), 0, "idle USDC");
    }

    function testShouldRevertBorrowWhenUsdcSubstrateRevoked() public {
        _depositToVault(plasmaVault, collateralAmount);
        _supplyCollateral(plasmaVault, collateral, collateralAmount);

        /// @dev re-grant the market without USDC (grantMarketSubstrates replaces the whole list)
        vm.prank(admin);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            COMPOUND_MARKET_ID,
            _compoundSubstrates(false)
        );

        assertFalse(
            PlasmaVaultGovernance(address(plasmaVault)).isMarketSubstrateGranted(
                COMPOUND_MARKET_ID,
                PlasmaVaultConfigLib.addressToBytes32(USDC)
            ),
            "USDC revoked"
        );

        vm.expectRevert(
            abi.encodeWithSelector(CompoundV3BorrowFuse.CompoundV3BorrowFuseUnsupportedAsset.selector, "enter", USDC)
        );
        _borrow(plasmaVault, BORROW_AMOUNT);

        assertEq(COMET.borrowBalanceOf(address(plasmaVault)), 0, "debt");
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), 0, "idle USDC");
    }

    function testShouldBorrowAndRepayWithTransientStorageChain() public {
        _depositToVault(plasmaVault, collateralAmount);
        _supplyCollateral(plasmaVault, collateral, collateralAmount);

        uint256 referenceTotalAssets = plasmaVault.totalAssets();

        // chain 1: set inputs -> borrow (transient) -> set inputs -> partial repay (transient), one execute
        FuseAction[] memory calls = new FuseAction[](4);
        calls[0] = _setBorrowFuseInputAction(BORROW_AMOUNT);
        calls[1] = FuseAction(address(borrowFuse), abi.encodeCall(CompoundV3BorrowFuse.enterTransient, ()));
        calls[2] = _setBorrowFuseInputAction(PARTIAL_REPAY_AMOUNT);
        calls[3] = FuseAction(address(borrowFuse), abi.encodeCall(CompoundV3BorrowFuse.exitTransient, ()));
        _execute(plasmaVault, calls);

        assertApproxEqAbs(
            COMET.borrowBalanceOf(address(plasmaVault)),
            BORROW_AMOUNT - PARTIAL_REPAY_AMOUNT,
            2,
            "chain 1: debt"
        );
        assertEq(
            ERC20(USDC).balanceOf(address(plasmaVault)),
            BORROW_AMOUNT - PARTIAL_REPAY_AMOUNT,
            "chain 1: idle USDC"
        );
        assertEq(ERC20(USDC).allowance(address(plasmaVault), COMET_USDC), 0, "chain 1: allowance");
        _assertMarketsMatchExpected(plasmaVault, "chain 1");
        _assertTotalAssetsUnchanged(plasmaVault, referenceTotalAssets, "chain 1");

        // chain 2: set inputs (max) -> full repay (transient)
        _fundRepayShortfall(plasmaVault);

        calls = new FuseAction[](2);
        calls[0] = _setBorrowFuseInputAction(type(uint256).max);
        calls[1] = FuseAction(address(borrowFuse), abi.encodeCall(CompoundV3BorrowFuse.exitTransient, ()));
        _execute(plasmaVault, calls);

        assertEq(COMET.borrowBalanceOf(address(plasmaVault)), 0, "chain 2: debt");
        assertEq(COMET.balanceOf(address(plasmaVault)), 0, "chain 2: base supply");
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), 0, "chain 2: idle USDC");
        assertEq(ERC20(USDC).allowance(address(plasmaVault), COMET_USDC), 0, "chain 2: allowance");
        _assertMarketsMatchExpected(plasmaVault, "chain 2");
        _assertTotalAssetsUnchanged(plasmaVault, referenceTotalAssets, "chain 2");
    }

    function _setBorrowFuseInputAction(uint256 amount_) internal view returns (FuseAction memory) {
        address[] memory fuses = new address[](1);
        fuses[0] = address(borrowFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(amount_);

        return
            FuseAction(
                address(transientStorageSetInputsFuse),
                abi.encodeCall(
                    TransientStorageSetInputsFuse.enter,
                    (TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse}))
                )
            );
    }
}

/// @notice cbBTC (8 decimals, Feed Registry priced) as the sole collateral and vault underlying
contract CompoundV3BorrowCbBtcEthereumTest is CompoundV3BorrowEthereumScenarios {
    function _collateral() internal pure override returns (address) {
        return CB_BTC;
    }

    /// @dev 1.3 cbBTC ~ 100k USD; well inside the 900 cbBTC supply cap (~359 used)
    function _collateralAmount() internal pure override returns (uint256) {
        return 1.3e8;
    }
}

/// @notice WETH (18 decimals) as the sole collateral and vault underlying
contract CompoundV3BorrowWethEthereumTest is CompoundV3BorrowEthereumScenarios {
    function _collateral() internal pure override returns (address) {
        return WETH;
    }

    /// @dev 40 WETH ~ 99k USD
    function _collateralAmount() internal pure override returns (uint256) {
        return 40e18;
    }
}

/// @notice wstETH (18 decimals) as the sole collateral and vault underlying
contract CompoundV3BorrowWstEthEthereumTest is CompoundV3BorrowEthereumScenarios {
    function _collateral() internal pure override returns (address) {
        return WST_ETH;
    }

    /// @dev 32 wstETH ~ 99k USD
    function _collateralAmount() internal pure override returns (uint256) {
        return 32e18;
    }
}

/// @notice WBTC (8 decimals) as the sole collateral and vault underlying
contract CompoundV3BorrowWbtcEthereumTest is CompoundV3BorrowEthereumScenarios {
    function _collateral() internal pure override returns (address) {
        return WBTC;
    }

    /// @dev 1.3 WBTC ~ 100k USD
    function _collateralAmount() internal pure override returns (uint256) {
        return 1.3e8;
    }
}

/// @notice Scenarios that need a single dedicated vault: USDC-underlying redemption and balance fuse migration
contract CompoundV3BorrowAuxiliaryEthereumTest is CompoundV3BorrowEthereumSetup {
    function setUp() public {
        _setUpForkAndFuses();
    }

    function testShouldRedeemFromIdleBorrowedUsdcWithOpenDebt() public {
        PlasmaVault usdcVault = _deployVault(USDC, address(balanceFuse));

        uint256 userDeposit = 10_000e6;
        uint256 collateralAmount = 40e18;

        _depositToVault(usdcVault, userDeposit);

        /// @dev test funding: collateral sent directly to the vault (not a user deposit), then supplied through the vault
        deal(WETH, address(usdcVault), collateralAmount);
        _supplyCollateral(usdcVault, WETH, collateralAmount);
        _borrow(usdcVault, BORROW_AMOUNT);

        uint256 idleUsdc = ERC20(USDC).balanceOf(address(usdcVault));
        assertEq(idleUsdc, userDeposit + BORROW_AMOUNT, "idle USDC = deposit + borrowed");
        assertEq(usdcVault.totalAssetsInMarket(ERC20_MARKET_ID), 0, "ERC20 market skips the underlying");
        _assertMarketsMatchExpected(usdcVault, "before redeem");

        uint256 debtBefore = COMET.borrowBalanceOf(address(usdcVault));
        uint256 collateralBefore = COMET.collateralBalanceOf(address(usdcVault), WETH);
        uint256 marketBalanceBefore = usdcVault.totalAssetsInMarket(COMPOUND_MARKET_ID);

        uint256 assetsToRedeem = 20_000e6;
        uint256 shares = usdcVault.convertToShares(assetsToRedeem);

        /// @dev PlasmaVault enters _withdrawFromMarkets only when assets + 2% slippage >= idle underlying
        uint256 assetsWithSlippage = usdcVault.convertToAssets(shares) +
            (usdcVault.convertToAssets(shares) * usdcVault.DEFAULT_SLIPPAGE_IN_PERCENTAGE()) / 100;
        assertLt(assetsWithSlippage, idleUsdc, "redeem served from idle USDC only");

        uint256 userUsdcBefore = ERC20(USDC).balanceOf(user);

        vm.prank(user);
        uint256 withdrawn = usdcVault.redeem(shares, user, user);

        assertApproxEqAbs(withdrawn, assetsToRedeem, 1, "withdrawn assets");
        assertEq(ERC20(USDC).balanceOf(user) - userUsdcBefore, withdrawn, "user received USDC");
        assertEq(ERC20(USDC).balanceOf(address(usdcVault)), idleUsdc - withdrawn, "idle USDC decreased");
        assertEq(COMET.borrowBalanceOf(address(usdcVault)), debtBefore, "debt unchanged");
        assertEq(COMET.collateralBalanceOf(address(usdcVault), WETH), collateralBefore, "collateral unchanged");
        assertEq(COMET.balanceOf(address(usdcVault)), 0, "no base supply");
        assertEq(usdcVault.totalAssetsInMarket(COMPOUND_MARKET_ID), marketBalanceBefore, "market balance unchanged");
    }

    function testShouldOverrideCompoundV3BalanceFuse() public {
        CompoundV3BalanceFuse legacyBalanceFuse = new CompoundV3BalanceFuse(COMPOUND_MARKET_ID, COMET_USDC);
        PlasmaVault vault = _deployVault(WETH, address(legacyBalanceFuse));
        PlasmaVaultGovernance governance = PlasmaVaultGovernance(address(vault));

        uint256 collateralAmount = 40e18;
        _depositToVault(vault, collateralAmount);
        _refreshCompoundMarket(vault);
        _supplyCollateral(vault, WETH, collateralAmount);
        _borrow(vault, BORROW_AMOUNT);

        assertTrue(
            governance.isBalanceFuseSupported(COMPOUND_MARKET_ID, address(legacyBalanceFuse)),
            "legacy fuse set"
        );

        uint256 legacyUsdWad = _expectedLegacyCompoundUsdWad(vault);
        assertEq(
            vault.totalAssetsInMarket(COMPOUND_MARKET_ID),
            _usdWadToUnderlying(vault, legacyUsdWad),
            "legacy fuse: Comet-priced market balance"
        );

        /// @dev explicit removal is refused while the legacy fuse reports more than dust
        vm.expectRevert(
            abi.encodeWithSelector(
                FusesLib.BalanceFuseNotReadyToRemove.selector,
                COMPOUND_MARKET_ID,
                address(legacyBalanceFuse),
                legacyUsdWad
            )
        );
        vm.prank(admin);
        governance.removeBalanceFuse(COMPOUND_MARKET_ID, address(legacyBalanceFuse));

        uint256[] memory activeMarketsBefore = governance.getActiveMarketsInBalanceFuses();
        assertEq(_countMarket(activeMarketsBefore, COMPOUND_MARKET_ID), 1, "market listed once before override");

        uint256 totalAssetsBeforeOverride = vault.totalAssets();
        address feeAccount = _performanceFeeAccount(vault);
        assertEq(vault.balanceOf(feeAccount), 0, "no performance fee before override");

        /// @dev variant: high-water mark synchronised to the Comet-priced NAV before migrating a live position ->
        ///      the one-time price-source NAV delta is charged as performance fee on the next refresh
        uint256 snapshotId = vm.snapshotState();
        FeeManager feeManager = FeeManager(FeeAccount(feeAccount).FEE_MANAGER());
        vm.prank(alpha);
        feeManager.updateHighWaterMarkPerformanceFee();
        vm.prank(admin);
        governance.addBalanceFuse(COMPOUND_MARKET_ID, address(balanceFuse));
        _refreshCompoundMarket(vault);
        uint256 feeSharesWithSyncedHighWaterMark = vault.balanceOf(feeAccount);
        assertGt(feeSharesWithSyncedHighWaterMark, 0, "HWM at Comet-priced NAV: migration delta charged as fee");
        emit log_named_uint("performance fee shares when HWM synced before override", feeSharesWithSyncedHighWaterMark);
        vm.revertToState(snapshotId);

        /// @dev direct override with an open position, no remove-then-add
        vm.prank(admin);
        governance.addBalanceFuse(COMPOUND_MARKET_ID, address(balanceFuse));

        assertTrue(governance.isBalanceFuseSupported(COMPOUND_MARKET_ID, address(balanceFuse)), "new fuse mapped");
        assertFalse(
            governance.isBalanceFuseSupported(COMPOUND_MARKET_ID, address(legacyBalanceFuse)),
            "legacy fuse unmapped"
        );

        uint256[] memory activeMarketsAfter = governance.getActiveMarketsInBalanceFuses();
        assertEq(activeMarketsAfter.length, activeMarketsBefore.length, "active markets length unchanged");
        assertEq(_countMarket(activeMarketsAfter, COMPOUND_MARKET_ID), 1, "market not duplicated");

        _refreshCompoundMarket(vault);

        _assertMarketsMatchExpected(vault, "after override");
        emit log_named_int(
            "one-time NAV delta from Comet to middleware pricing (WETH wei)",
            int256(vault.totalAssets()) - int256(totalAssetsBeforeOverride)
        );
        /// @dev HWM set at the deposit NAV; the legacy Comet pricing lowered NAV and the override only restores it
        assertEq(vault.balanceOf(feeAccount), 0, "HWM at deposit NAV: no performance fee after override");

        /// @dev after the override the legacy fuse is no longer the market fuse, so removing it is a different error
        vm.expectRevert(
            abi.encodeWithSelector(
                FusesLib.BalanceFuseDoesNotExist.selector,
                COMPOUND_MARKET_ID,
                address(legacyBalanceFuse)
            )
        );
        vm.prank(admin);
        governance.removeBalanceFuse(COMPOUND_MARKET_ID, address(legacyBalanceFuse));
    }

    function _countMarket(uint256[] memory markets_, uint256 marketId_) internal pure returns (uint256 count) {
        for (uint256 i; i < markets_.length; ++i) {
            if (markets_[i] == marketId_) {
                ++count;
            }
        }
    }
}
