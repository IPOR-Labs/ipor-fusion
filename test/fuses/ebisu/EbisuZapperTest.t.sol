// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";

import {EbisuZapperCreateFuse, EbisuZapperCreateFuseEnterData, EbisuZapperCreateFuseExitData} from "../../../contracts/fuses/ebisu/EbisuZapperCreateFuse.sol";

import {EbisuAdjustInterestRateFuse} from "../../../contracts/fuses/ebisu/EbisuAdjustInterestRateFuse.sol";
import {EbisuAdjustTroveFuse} from "../../../contracts/fuses/ebisu/EbisuAdjustTroveFuse.sol";

import {EbisuZapperBalanceFuse} from "../../../contracts/fuses/ebisu/EbisuZapperBalanceFuse.sol";
import {ITroveManager} from "../../../contracts/fuses/ebisu/ext/ITroveManager.sol";
import {ILeverageZapper} from "../../../contracts/fuses/ebisu/ext/ILeverageZapper.sol";
import {EbisuMathLib} from "../../../contracts/fuses/ebisu/lib/EbisuMathLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {EbisuWethEthAdapterAddressReader} from "../../../contracts/readers/EbisuWethEthAdapterAddressReader.sol";
import {UniversalReader, ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperData, UniversalTokenSwapperEnterData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {SwapExecutor} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";

import {EbisuZapperLeverModifyFuse, EbisuZapperLeverModifyFuseEnterData, EbisuZapperLeverModifyFuseExitData} from "../../../contracts/fuses/ebisu/EbisuZapperLeverModifyFuse.sol";
import {WethEthAdapterStorageLib} from "../../../contracts/fuses/ebisu/lib/WethEthAdapterStorageLib.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "../../../contracts/fuses/ebisu/lib/EbisuZapperSubstrateLib.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {TransientStorageSetterFuse} from "../../test_helpers/TransientStorageSetterFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";

contract MockDex {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) public {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        ERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

interface EbisuPriceFeed {
    function lastGoodPrice() external view returns (uint256);
}

interface EBUSDPriceFeed {
    function latestRound() external view returns (uint256);
}

interface IEbisuBorrowerOperationsHelperMinimal {
    function getInterestIndividualDelegateOf(
        uint256 troveId
    ) external view returns (address account, uint128 minRate, uint128 maxRate, uint256 minInterestRateChangePeriod);
}

contract EbisuZapperTest is Test {
    // Base Asset
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Gas Asset
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // Borrow Asset
    address internal constant EBUSD = 0x09fD37d9AA613789c517e76DF1c53aEce2b60Df4; // debt token
    // Collateral Assets
    address internal constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497; // collateral token
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;
    // Zapper Addresses
    address internal constant WEETH_ZAPPER = 0x54965fD4Dacbc5Ab969C2F52E866c1a37AD66923;
    address internal constant SUSDE_ZAPPER = 0x10C14374104f9FC2dAE4b38F945ff8a52f48151d;
    address internal constant WBTC_ZAPPER = 0x175a17755ea596875CB3c996D007072C3f761F6B;
    address internal constant LBTC_ZAPPER = 0xe32E9aB36558e5341A4C05FD635Db4Ba1F3F51cF;
    // Address Registries
    address internal constant WEETH_REGISTRY = 0x329a7BAA50BB43A6149AF8C9cF781876b6Fd7B3A;
    address internal constant SUSDE_REGISTRY = 0x411ED8575a1e3822Bbc763DC578dd9bFAF526C1f;
    address internal constant WBTC_REGISTRY = 0x0CAc6a40EE0D35851Fd6d9710C5180F30B494350;
    address internal constant LBTC_REGISTRY = 0x7f034988AF49248D3d5bD81a2CE76ED4a3006243;

    PlasmaVault private plasmaVault;
    EbisuZapperCreateFuse private zapperFuse;
    EbisuZapperLeverModifyFuse private leverModifyFuse;
    EbisuZapperBalanceFuse private balanceFuse;
    ERC20BalanceFuse private erc20BalanceFuse;
    UniversalTokenSwapperFuse private swapFuse;
    TransientStorageSetterFuse private transientStorageSetterFuse;
    EbisuAdjustInterestRateFuse private adjustRateFuse;
    EbisuAdjustTroveFuse private adjustTroveFuse;

    address private accessManager;
    PriceOracleMiddleware private priceOracle;

    EbisuWethEthAdapterAddressReader private wethEthAdapterAddressReader;
    // ETH gas compensation constant from zapper (keep in sync with fuse)
    uint256 private constant ETH_GAS_COMPENSATION = 0.0375 ether;

    MockDex private mockDex;

    receive() external payable {}

    function setUp() public {
        // block height -> 23277699 | Sep-02-2025 08:23:23 PM +UTC
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23277699);
        // assets
        address[] memory assets = new address[](7);
        assets[0] = EBUSD; // borrowed
        assets[1] = WEETH; // collateral
        assets[2] = SUSDE; // collateral
        assets[3] = WBTC; // collateral
        assets[4] = LBTC; // collateral
        assets[5] = WETH; // compensation
        assets[6] = USDC; // base token

        // price feeders
        address[] memory priceFeeds = new address[](7);
        priceFeeds[0] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // EBUSD (USD feed)
        priceFeeds[1] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WEETH ~ ETH
        priceFeeds[2] = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099; // sUSDe
        priceFeeds[3] = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // WBTC
        priceFeeds[4] = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // LBTC (reuse WBTC)
        priceFeeds[5] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WETH ~ ETH
        priceFeeds[6] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC (USD feed)

        // instantiate oracle middleware
        priceOracle = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        priceOracle.initialize(address(this));
        // then set assets prices sources on the oracle middleware
        priceOracle.setAssetsPricesSources(assets, priceFeeds);

        // create plasma vault in a single step
        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "TEST sUSDe PLASMA VAULT",
                "zpTEST",
                USDC,
                address(priceOracle),
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                address(new WithdrawManager(accessManager)),
                address(0)
            )
        );

        // mock dex to swap USDC into sUSDe
        mockDex = new MockDex();
        // deal 1_000_000_000 sUSDe to mockDex
        deal(SUSDE, address(mockDex), 1e9 * 1e18);
        // deal 1_000_000_000 ebUSD to mockDex
        deal(EBUSD, address(mockDex), 1e9 * 1e18);

        _setupRoles();

        // setup plasma vault
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs(address(mockDex))
        );

        // setup dependency balance graph for the Ebisu Zapper
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.EBISU;
        marketIds[1] = IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](2);
        dependenceMarkets[0] = dependence; // Ebisu -> ERC20_VAULT_BALANCE
        dependenceMarkets[1] = dependence; // Universal Swapper -> ERC20_VAULT_BALANCE

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        // adapter address reader
        wethEthAdapterAddressReader = new EbisuWethEthAdapterAddressReader();
    }

    function testShouldEnterToEbisuZapper() public {
        // given
        EbisuZapperCreateFuseEnterData memory enterData = EbisuZapperCreateFuseEnterData({
            zapper: SUSDE_ZAPPER,
            registry: SUSDE_REGISTRY,
            collAmount: 4_000 * 1e18, // 4_000 sUSDe collateral
            ebusdAmount: 5_000 * 1e18, // 5_000 ebUSD debt
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 1_000 * 1e18, // 1_000 further sUSDe from flashloan
            annualInterestRate: 20 * 1e16, // 20%
            maxUpfrontFee: 5 * 1e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
                enterData
            )
        );

        // deposit 100,000 USDC in the vault
        deal(USDC, address(this), 100_000 * 1e6);
        ERC20(USDC).approve(address(plasmaVault), 100_000 * 1e6);
        plasmaVault.deposit(100_000 * 1e6, address(this));

        // send to vault rather than deal
        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);

        // check plasmaVault assets before all
        uint256 totalAssetsBeforeSwap = plasmaVault.totalAssets();

        // -- 100,000 USDC
        assertEq(totalAssetsBeforeSwap, 100_000 * 1e6);

        // now, in order to open a trove, we need to get collateral sUSDe through the Swapper (beware of decimals)
        _swapUSDCtoToken(enterData.collAmount / 1e12, SUSDE);
        uint256 totalAssetsAfterSwap = plasmaVault.totalAssets();

        {
            // -- 90,000 USDC (6 decimals) -> USDC value identity
            // -- 10,000 SUSDE (18 decimals) -> USDC value multiply * SUSDE price and divide by USDC price
            uint256 susdeBalance = ERC20(SUSDE).balanceOf(address(plasmaVault));
            assertEq(susdeBalance, 4_000 * 1e18, "sUSDe balance incorrect");
            uint256 usdcBalance = ERC20(USDC).balanceOf(address(plasmaVault));
            assertEq(usdcBalance, 96_000 * 1e6, "USDC balance incorrect");

            (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
            uint256 susdeUSDValue = IporMath.convertToWad(susdeBalance * price, 18 + priceDecimals);
            (price, priceDecimals) = priceOracle.getAssetPrice(USDC);
            uint256 susdeUSDCvalue = IporMath.convertWadToAssetDecimals(
                IporMath.division(susdeUSDValue * IporMath.BASIS_OF_POWER ** 8, price),
                16
            );
            assertEq(totalAssetsAfterSwap, susdeUSDCvalue + usdcBalance, "total assets after swap incorrect");
        }

        // when
        plasmaVault.execute(enterCalls);

        // Verify adapter was created
        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        assertTrue(wethEthAdapter != address(0), "Adapter should be created after execution");
        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);

        // Inspect trove state
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);

        {
            // -- 90,000 USDC (6 decimals) -> USDC value identity
            // -- ebusdAmount - flashloanAmount worth of sUSDe (18 decimals)
            // -- trove open with totalColl = collAmount + flashloanAmount and boldAmount = ebusdAmount + upfrontFee

            // then
            // check troveData is populated, with upfront fee less than maximum
            assertGe(troveData.entireDebt, enterData.ebusdAmount, "debt less than expected");
            assertLe(troveData.entireDebt, enterData.ebusdAmount + enterData.maxUpfrontFee, "upfront fee exceeded");
            assertEq(troveData.entireColl, enterData.collAmount + enterData.flashLoanAmount, "entire coll wrong");

            // ------ CHECK EBISU ASSETS -------
            uint256 totalAssetsInEbisu = plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU);

            // coll (sUSDe) value in USD
            (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
            uint256 collUSDvalue = IporMath.convertToWad(troveData.entireColl * price, 18 + priceDecimals);

            // debt (ebUSD) value in USD
            (price, priceDecimals) = priceOracle.getAssetPrice(EBUSD);
            uint256 debtUSDvalue = IporMath.convertToWad(troveData.entireDebt * price, 18 + priceDecimals);

            // check balanceOf() matches
            ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
                address(balanceFuse),
                abi.encodeWithSignature("balanceOf()")
            );
            uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));

            // then
            assertEq(balanceOfFromFuse, collUSDvalue - debtUSDvalue, "balanceOf() incorrect after entering");

            // transport all in USDC
            (price, priceDecimals) = priceOracle.getAssetPrice(USDC);
            uint256 ebisuUSDCvalue = IporMath.convertWadToAssetDecimals(
                IporMath.division(balanceOfFromFuse * IporMath.BASIS_OF_POWER ** 8, price),
                16
            );

            // then
            assertEq(ebisuUSDCvalue, totalAssetsInEbisu);
        }
        {
            // ------ CHECK ERC20 ASSETS -------
            // assets in ERC20 are now USDC and a value of sUSDe equal to ebusdAmount * price(EBUSD) - flashloanAmount * price(SUSDE)
            uint256 totalAssetsInERC20 = plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
            (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(EBUSD);
            uint256 ebisuUSDvalue = IporMath.convertToWad(enterData.ebusdAmount * price, 18 + priceDecimals);

            // transport value in sUSDe
            (price, priceDecimals) = priceOracle.getAssetPrice(SUSDE);
            uint256 ebisuSUSDEvalue = IporMath.convertWadToAssetDecimals(
                IporMath.division(ebisuUSDvalue * IporMath.BASIS_OF_POWER ** 8, price),
                28
            );

            uint256 susdeBalance = ERC20(SUSDE).balanceOf(address(plasmaVault));
            // slippage + oracles not matching Balancer's ones cause discrepancies of around 2%
            _eqWithTolerance(susdeBalance, ebisuSUSDEvalue - enterData.flashLoanAmount, 200);

            uint256 susdeUSDvalue = IporMath.convertToWad(susdeBalance * price, 18 + priceDecimals);
            // transport value in USDC
            (price, priceDecimals) = priceOracle.getAssetPrice(USDC);
            uint256 susdeUSDCBalance = IporMath.convertWadToAssetDecimals(
                IporMath.division(susdeUSDvalue * IporMath.BASIS_OF_POWER ** 8, price),
                16
            );
            // then
            assertEq(totalAssetsInERC20, susdeUSDCBalance, "total ERC20 assets mismatch");
        }
        {
            // ----- CHECK TOTAL ASSETS -------
            uint256 totalAssetsInERC20 = plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
            uint256 totalAssetsInEbisu = plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU);
            uint256 totalAssetsAfterExecution = plasmaVault.totalAssets();
            // They are simply the assets in ERC20 and Ebisu plus the USDC residual balance
            // then
            assertEq(totalAssetsAfterExecution, totalAssetsInERC20 + totalAssetsInEbisu + 96_000 * 1e6);
        }
        {
            // ----- CHECK ASSET CHANGE ------
            // from the previous tests, the vault balance of opening a position is:
            // 1. - collAmount sUSDe (paid collAmount sUSDe to Trove)
            // 2. + collAmount sUSDe + flashloanAmount sUSDe - ebusdAmount ebUSD - upfrontFee ebUSD (from the open Trove)
            // 3. + ebusdAmount ebUSD (converted in sUSDe by swap) - flashloanAmount sUSDe (repaid by Zapper as dust)
            // therefore the net balance change is only -upfrontFee, with some tolerance due to the swap slippage
            uint256 totalAssetsAfterExecution = plasmaVault.totalAssets();

            // the only leakage is the upfront fee paid to Liquity, which is debt - ebusdAmount in ebUSD tokens
            (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(EBUSD);
            uint256 feeUSDValue = IporMath.convertToWad(
                (troveData.entireDebt - enterData.ebusdAmount) * price,
                18 + priceDecimals
            );
            // transport value in USDC
            (price, priceDecimals) = priceOracle.getAssetPrice(USDC);
            uint256 feeUSDCBalance = IporMath.convertWadToAssetDecimals(
                IporMath.division(feeUSDValue * IporMath.BASIS_OF_POWER ** 8, price),
                16
            );
            // then
            _eqWithTolerance(totalAssetsAfterExecution, totalAssetsAfterSwap - feeUSDCBalance, 10); // 0.1% tolerance
        }
    }

    function testShouldExitToETHFromEbisuZapper() public {
        // given
        testShouldEnterToEbisuZapper();

        // now, in order to close a trove, we need to get EBUSD through the Swapper
        // this is necessary because dealing doesn't update market balances
        _swapUSDCtoToken(6_000 * 1e6, EBUSD);

        EbisuZapperCreateFuseExitData memory exitData = EbisuZapperCreateFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 0,
            minExpectedCollateral: 0,
            exitFromCollateral: false
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256,bool))", exitData)
        );

        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());

        uint256 totalAssetsBefore = plasmaVault.totalAssets();

        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);

        // when
        plasmaVault.execute(exitCalls);
        troveData = troveManager.getLatestTroveData(troveId);

        // then
        assertEq(troveData.entireColl, 0);
        assertEq(troveData.entireDebt, 0);

        ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
            address(balanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );
        uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));
        assertEq(balanceOfFromFuse, 0, "residual balanceOf after exit");

        uint256 ebisuAfter = plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU);
        assertEq(ebisuAfter, 0, "Ebisu market should be empty after exit");

        // ----- CHECK ASSET CHANGE ------
        // Vault effect of closing a position to raw ETH is
        // 1. - troveData.entireDebt ebUSD
        // 2. + troveData.totalColl sUSDe
        // this is exactly balanceOf() of the EbisuBalanceFuse that is now 0
        // so the net asset change is 0
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore + 1); // extremely tiny rounding error
    }

    function testShouldExitFromCollateralFromEbisuZapper() public {
        // given
        testShouldEnterToEbisuZapper();

        // no need of EBUSD to repay debt if closing from collateral
        EbisuZapperCreateFuseExitData memory exitData = EbisuZapperCreateFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 5_000 * 1e18, // sUSDe needed to repay the debt
            minExpectedCollateral: 0,
            exitFromCollateral: true
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256,bool))", exitData)
        );

        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        // when
        plasmaVault.execute(exitCalls);
        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        assertTrue(wethEthAdapter != address(0), "Adapter should be created after execution");

        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);

        // then
        assertEq(troveData.entireColl, 0);
        assertEq(troveData.entireDebt, 0);

        uint256 totalAssetsInEbisu = plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU);
        assertEq(totalAssetsInEbisu, 0);

        // ----- CHECK ASSET CHANGE ------
        // Vault effect of closing a position from collateral is
        // 1. + exitData.flashLoanAmount (which in in sUSDe) - troveData.entireDebt in ebUSD
        // 2. + troveData.totalColl - exitData.flashLoanAmount in sUSDe
        // therefore the net change is + troveData.totalColl (sUSDe) - troveData.entireDebt (ebUSD)
        // exactly the same as closeTroveToRawETH, this is balanceOf() of the EbisuBalanceFuse
        // therefore the net change of totalAssets() is 0

        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        _eqWithTolerance(totalAssetsAfter, totalAssetsBefore, 10); // this time allow 0.1% error since there have been swaps
    }

    function testLeverUpEffectsEbisu() public {
        // given
        testShouldEnterToEbisuZapper();
        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        assertTrue(wethEthAdapter != address(0), "Adapter should be created after execution");

        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());

        ITroveManager.LatestTroveData memory initialData = troveManager.getLatestTroveData(troveId);
        uint256 initialDebt = initialData.entireDebt;
        uint256 initialColl = initialData.entireColl;

        EbisuZapperLeverModifyFuseEnterData memory leverUpData = EbisuZapperLeverModifyFuseEnterData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 500 * 1e18,
            ebusdAmount: 700 * 1e18,
            maxUpfrontFee: 2 * 1e18
        });

        FuseAction[] memory leverUpCalls = new FuseAction[](1);
        leverUpCalls[0] = FuseAction(
            address(leverModifyFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256,uint256))", leverUpData)
        );

        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 totalAssetsInMarketBefore = plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU);
        // when
        plasmaVault.execute(leverUpCalls);

        ITroveManager.LatestTroveData memory finalData = troveManager.getLatestTroveData(troveId);

        // then
        assertGe(
            finalData.entireDebt,
            initialDebt + leverUpData.ebusdAmount,
            "Debt should be at least initial debt + ebusd amount"
        );
        assertLe(
            finalData.entireDebt,
            initialDebt + leverUpData.ebusdAmount + leverUpData.maxUpfrontFee,
            "Debt increased too much"
        );
        assertEq(
            finalData.entireColl,
            initialColl + leverUpData.flashLoanAmount,
            "Collateral should have increased after lever up"
        );

        {
            // balanceOf() should be up to date
            ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
                address(balanceFuse),
                abi.encodeWithSignature("balanceOf()")
            );

            uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));
            (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
            uint256 collUSDvalue = IporMath.convertToWad(finalData.entireColl * price, 18 + priceDecimals);
            (price, priceDecimals) = priceOracle.getAssetPrice(EBUSD);
            uint256 debtUSDvalue = IporMath.convertToWad(finalData.entireDebt * price, 18 + priceDecimals);
            assertEq(balanceOfFromFuse, collUSDvalue - debtUSDvalue, "balance after lever up incorrect");
        }
        {
            // check assets change in EBISU
            (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
            uint256 collUSDvalueChange = IporMath.convertToWad(
                (finalData.entireColl - initialData.entireColl) * price,
                18 + priceDecimals
            );
            (price, priceDecimals) = priceOracle.getAssetPrice(EBUSD);
            uint256 debtUSDvalueChange = IporMath.convertToWad(
                (finalData.entireDebt - initialData.entireDebt) * price,
                18 + priceDecimals
            );

            // transport in USDC
            (price, priceDecimals) = priceOracle.getAssetPrice(USDC);
            uint256 collChange = IporMath.convertWadToAssetDecimals(
                IporMath.division(collUSDvalueChange * IporMath.BASIS_OF_POWER ** 8, price),
                16
            );
            uint256 debtChange = IporMath.convertWadToAssetDecimals(
                IporMath.division(debtUSDvalueChange * IporMath.BASIS_OF_POWER ** 8, price),
                16
            );

            assertEq(
                plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU),
                totalAssetsInMarketBefore + collChange - debtChange,
                "Extra assets in EBISU mismatch"
            );
        }

        // ------ CHECK ASSETS CHANGE ------
        // Vault effect of closing a position from collateral is
        // 1. + leverUpData.ebusdAmount (which is in ebUSD) - leverUpData.flashLoanAmount in ebUSD
        // 2. trove collateral has increased of flashLoanAmount and debt increased of ebusdAmount
        // therefore the net change is zero
        _eqWithTolerance(plasmaVault.totalAssets(), totalAssetsBefore, 1); // 0.01% tolerance due to slippage
    }

    function testLeverDownEffectsEbisu() public {
        // given
        testShouldEnterToEbisuZapper();
        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        assertTrue(wethEthAdapter != address(0), "Adapter should be created after execution");

        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());

        ITroveManager.LatestTroveData memory initialData = troveManager.getLatestTroveData(troveId);

        EbisuZapperLeverModifyFuseExitData memory leverDownData = EbisuZapperLeverModifyFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 500 * 1e18,
            minBoldAmount: 200 * 1e18
        });

        FuseAction[] memory leverDownCalls = new FuseAction[](1);
        leverDownCalls[0] = FuseAction(
            address(leverModifyFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256))", leverDownData)
        );
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 totalAssetsInMarketBefore = plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU);
        // when
        plasmaVault.execute(leverDownCalls);

        ITroveManager.LatestTroveData memory finalData = troveManager.getLatestTroveData(troveId);
        uint256 finalDebt = finalData.entireDebt;
        uint256 finalColl = finalData.entireColl;

        // then
        assertLt(finalDebt, initialData.entireDebt, "Debt should have decreased after lever down");
        assertLt(finalColl, initialData.entireColl, "Collateral should have decreased after lever down");
        {
            // balanceOf() should be up to date
            ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
                address(balanceFuse),
                abi.encodeWithSignature("balanceOf()")
            );

            uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));
            (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
            uint256 collValue = IporMath.convertToWad(finalColl * price, 18 + priceDecimals);
            (price, priceDecimals) = priceOracle.getAssetPrice(EBUSD);
            uint256 debtValue = IporMath.convertToWad(finalDebt * price, 18 + priceDecimals);
            assertEq(balanceOfFromFuse, collValue - debtValue, "balance after lever up incorrect");
        }
        {
            // check assets change in EBISU
            (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
            uint256 collUSDvalueChange = IporMath.convertToWad(
                (initialData.entireColl - finalData.entireColl) * price,
                18 + priceDecimals
            );
            (price, priceDecimals) = priceOracle.getAssetPrice(EBUSD);
            uint256 debtUSDvalueChange = IporMath.convertToWad(
                (initialData.entireDebt - finalData.entireDebt) * price,
                18 + priceDecimals
            );

            // transport in USDC
            (price, priceDecimals) = priceOracle.getAssetPrice(USDC);
            uint256 collChange = IporMath.convertWadToAssetDecimals(
                IporMath.division(collUSDvalueChange * IporMath.BASIS_OF_POWER ** 8, price),
                16
            );
            uint256 debtChange = IporMath.convertWadToAssetDecimals(
                IporMath.division(debtUSDvalueChange * IporMath.BASIS_OF_POWER ** 8, price),
                16
            );

            assertEq(
                plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU),
                totalAssetsInMarketBefore + debtChange - collChange,
                "Change of assets in EBISU mismatch"
            );
        }
        // ------ CHECK ASSETS CHANGE ------
        // Vault effect of closing a position from collateral is
        // 1. - leverUpData.ebusdAmount (which is in ebUSD) + leverUpData.flashLoanAmount in ebUSD
        // 2. trove collateral has increased of flashLoanAmount and debt increased of ebusdAmount
        // therefore the net change is zero
        _eqWithTolerance(plasmaVault.totalAssets(), totalAssetsBefore, 1); // 0.01% tolerance due to slippage
    }

    function testShouldRevertWhenEnterWithUnsupportedSubstrate() public {
        EbisuZapperCreateFuseEnterData memory enterData = EbisuZapperCreateFuseEnterData({
            zapper: address(0x123), // unsupported
            registry: SUSDE_REGISTRY,
            collAmount: 10_000 * 1e18,
            ebusdAmount: 5_000 * 1e18,
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 0,
            annualInterestRate: 20 * 1e16,
            maxUpfrontFee: 5 * 1e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
                enterData
            )
        );

        vm.expectRevert(abi.encodeWithSignature("UnsupportedSubstrate()"));
        plasmaVault.execute(enterCalls);
    }

    function testShouldRevertWhenExitWithUnsupportedSubstrate() public {
        EbisuZapperCreateFuseExitData memory exitData = EbisuZapperCreateFuseExitData({
            zapper: address(0x123), // unsupported
            flashLoanAmount: 0,
            minExpectedCollateral: 0,
            exitFromCollateral: false
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256,bool))", exitData)
        );

        vm.expectRevert(abi.encodeWithSignature("UnsupportedSubstrate()"));
        plasmaVault.execute(exitCalls);
    }

    function testShouldRevertWhenExitWithTroveNotOpen() public {
        // Use a supported zapper but no trove open
        EbisuZapperCreateFuseExitData memory exitData = EbisuZapperCreateFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 0,
            minExpectedCollateral: 0,
            exitFromCollateral: false
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256,bool))", exitData)
        );

        vm.expectRevert(abi.encodeWithSignature("TroveNotOpen()"));
        plasmaVault.execute(exitCalls);
    }

    function testShouldRevertWhenUpfrontFeeTooHigh() public {
        EbisuZapperCreateFuseEnterData memory enterData = EbisuZapperCreateFuseEnterData({
            zapper: SUSDE_ZAPPER,
            registry: SUSDE_REGISTRY,
            collAmount: 10_000 * 1e18,
            ebusdAmount: 5_000 * 1e18,
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 0,
            annualInterestRate: 300 * 1e16, // 300% > 250%
            maxUpfrontFee: 5 * 1e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
                enterData
            )
        );

        vm.expectRevert(abi.encodeWithSignature("UpfrontFeeTooHigh(uint256)", 300 * 1e16));
        plasmaVault.execute(enterCalls);
    }

    function testShouldRevertWhenDebtBelowMin() public {
        EbisuZapperCreateFuseEnterData memory enterData = EbisuZapperCreateFuseEnterData({
            zapper: SUSDE_ZAPPER,
            registry: SUSDE_REGISTRY,
            collAmount: 10_000 * 1e18,
            ebusdAmount: 1_000 * 1e18, // < MIN_DEBT (2000)
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 0,
            annualInterestRate: 20 * 1e16,
            maxUpfrontFee: 5 * 1e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
                enterData
            )
        );

        vm.expectRevert();
        plasmaVault.execute(enterCalls);
    }

    function testShouldRevertWhenICRBelowMCR() public {
        EbisuZapperCreateFuseEnterData memory enterData = EbisuZapperCreateFuseEnterData({
            zapper: SUSDE_ZAPPER,
            registry: SUSDE_REGISTRY,
            collAmount: 100 * 1e18,
            ebusdAmount: 5_000 * 1e18,
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 0,
            annualInterestRate: 20 * 1e16,
            maxUpfrontFee: 5 * 1e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
                enterData
            )
        );

        deal(USDC, address(this), 100_000 * 1e6);
        ERC20(USDC).approve(address(plasmaVault), 100_000 * 1e6);
        plasmaVault.deposit(100_000 * 1e6, address(this));
        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);
        _swapUSDCtoToken(enterData.collAmount / 1e12, SUSDE);

        vm.expectRevert();
        plasmaVault.execute(enterCalls);
    }

    function testShouldBeAbleToEnterAndExitTransient() public {
        // given
        EbisuZapperCreateFuseEnterData memory enterData = EbisuZapperCreateFuseEnterData({
            zapper: SUSDE_ZAPPER,
            registry: SUSDE_REGISTRY,
            collAmount: 10_000 * 1e18, // 10_000 sUSDe collateral
            ebusdAmount: 5_000 * 1e18, // 5_000 ebUSD debt
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 1_000 * 1e18, // 1_000 further sUSDe from flashloan
            annualInterestRate: 20 * 1e16, // 20%
            maxUpfrontFee: 5 * 1e18
        });

        bytes32[] memory inputs = new bytes32[](9);
        inputs[0] = TypeConversionLib.toBytes32(enterData.zapper);
        inputs[1] = TypeConversionLib.toBytes32(enterData.registry);
        inputs[2] = TypeConversionLib.toBytes32(enterData.collAmount);
        inputs[3] = TypeConversionLib.toBytes32(enterData.ebusdAmount);
        inputs[4] = TypeConversionLib.toBytes32(enterData.upperHint);
        inputs[5] = TypeConversionLib.toBytes32(enterData.lowerHint);
        inputs[6] = TypeConversionLib.toBytes32(enterData.flashLoanAmount);
        inputs[7] = TypeConversionLib.toBytes32(enterData.annualInterestRate);
        inputs[8] = TypeConversionLib.toBytes32(enterData.maxUpfrontFee);

        // deposit 100,000 USDC in the vault
        deal(USDC, address(this), 100_000 * 1e6);
        ERC20(USDC).approve(address(plasmaVault), 100_000 * 1e6);
        plasmaVault.deposit(100_000 * 1e6, address(this));

        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);

        _swapUSDCtoToken(enterData.collAmount / 1e12, SUSDE);

        address predictedAdapter = vm.computeCreateAddress(address(plasmaVault), vm.getNonce(address(plasmaVault)));
        uint256 predictedTroveId = EbisuMathLib.calculateTroveId(
            predictedAdapter,
            address(plasmaVault),
            SUSDE_ZAPPER,
            1
        );

        bytes32[] memory expectedOutputs = new bytes32[](2);
        expectedOutputs[0] = TypeConversionLib.toBytes32(enterData.zapper);
        expectedOutputs[1] = TypeConversionLib.toBytes32(predictedTroveId);

        FuseAction[] memory enterCalls = new FuseAction[](3);
        enterCalls[0] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("setInputs(address,bytes32[])", address(zapperFuse), inputs)
        );
        enterCalls[1] = FuseAction(address(zapperFuse), abi.encodeWithSignature("enterTransient()"));
        enterCalls[2] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("checkOutputs(address,bytes32[])", address(zapperFuse), expectedOutputs)
        );

        // when
        plasmaVault.execute(enterCalls);

        // Verify adapter was created
        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        assertTrue(wethEthAdapter != address(0), "Adapter should be created after execution");
        assertEq(wethEthAdapter, predictedAdapter, "Adapter address mismatch");

        // Now EXIT Transient
        _swapUSDCtoToken(6_000 * 1e6, EBUSD);

        EbisuZapperCreateFuseExitData memory exitData = EbisuZapperCreateFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 0,
            minExpectedCollateral: 0,
            exitFromCollateral: false
        });

        bytes32[] memory exitInputs = new bytes32[](4);
        exitInputs[0] = TypeConversionLib.toBytes32(exitData.zapper);
        exitInputs[1] = TypeConversionLib.toBytes32(exitData.flashLoanAmount);
        exitInputs[2] = TypeConversionLib.toBytes32(exitData.minExpectedCollateral);
        // bool to uint256
        exitInputs[3] = TypeConversionLib.toBytes32(uint256(exitData.exitFromCollateral ? 1 : 0));

        bytes32[] memory expectedExitOutputs = new bytes32[](2);
        expectedExitOutputs[0] = TypeConversionLib.toBytes32(exitData.zapper);
        expectedExitOutputs[1] = TypeConversionLib.toBytes32(uint256(1));

        FuseAction[] memory exitCalls = new FuseAction[](3);
        exitCalls[0] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("setInputs(address,bytes32[])", address(zapperFuse), exitInputs)
        );
        exitCalls[1] = FuseAction(address(zapperFuse), abi.encodeWithSignature("exitTransient()"));
        exitCalls[2] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("checkOutputs(address,bytes32[])", address(zapperFuse), expectedExitOutputs)
        );

        plasmaVault.execute(exitCalls);

        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(predictedTroveId);
        assertEq(troveData.entireColl, 0);
        assertEq(troveData.entireDebt, 0);
    }

    function testLeverModifyTransient() public {
        // Setup similar to testLeverUpEffectsEbisu
        testShouldEnterToEbisuZapper();
        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());

        ITroveManager.LatestTroveData memory initialData = troveManager.getLatestTroveData(troveId);

        // Lever Up
        EbisuZapperLeverModifyFuseEnterData memory leverUpData = EbisuZapperLeverModifyFuseEnterData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 500 * 1e18,
            ebusdAmount: 700 * 1e18,
            maxUpfrontFee: 2 * 1e18
        });

        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(leverUpData.zapper);
        inputs[1] = TypeConversionLib.toBytes32(leverUpData.flashLoanAmount);
        inputs[2] = TypeConversionLib.toBytes32(leverUpData.ebusdAmount);
        inputs[3] = TypeConversionLib.toBytes32(leverUpData.maxUpfrontFee);

        bytes32[] memory expectedOutputs = new bytes32[](2);
        expectedOutputs[0] = TypeConversionLib.toBytes32(leverUpData.zapper);
        expectedOutputs[1] = TypeConversionLib.toBytes32(troveId);

        FuseAction[] memory leverUpCalls = new FuseAction[](3);
        leverUpCalls[0] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("setInputs(address,bytes32[])", address(leverModifyFuse), inputs)
        );
        leverUpCalls[1] = FuseAction(address(leverModifyFuse), abi.encodeWithSignature("enterTransient()"));
        leverUpCalls[2] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("checkOutputs(address,bytes32[])", address(leverModifyFuse), expectedOutputs)
        );

        plasmaVault.execute(leverUpCalls);

        ITroveManager.LatestTroveData memory finalData = troveManager.getLatestTroveData(troveId);
        assertGe(finalData.entireDebt, initialData.entireDebt + leverUpData.ebusdAmount);

        // Lever Down
        EbisuZapperLeverModifyFuseExitData memory leverDownData = EbisuZapperLeverModifyFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 500 * 1e18,
            minBoldAmount: 200 * 1e18
        });

        bytes32[] memory exitInputs = new bytes32[](3);
        exitInputs[0] = TypeConversionLib.toBytes32(leverDownData.zapper);
        exitInputs[1] = TypeConversionLib.toBytes32(leverDownData.flashLoanAmount);
        exitInputs[2] = TypeConversionLib.toBytes32(leverDownData.minBoldAmount);

        bytes32[] memory expectedExitOutputs = new bytes32[](2);
        expectedExitOutputs[0] = TypeConversionLib.toBytes32(leverDownData.zapper);
        expectedExitOutputs[1] = TypeConversionLib.toBytes32(troveId);

        FuseAction[] memory leverDownCalls = new FuseAction[](3);
        leverDownCalls[0] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("setInputs(address,bytes32[])", address(leverModifyFuse), exitInputs)
        );
        leverDownCalls[1] = FuseAction(address(leverModifyFuse), abi.encodeWithSignature("exitTransient()"));
        leverDownCalls[2] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("checkOutputs(address,bytes32[])", address(leverModifyFuse), expectedExitOutputs)
        );

        plasmaVault.execute(leverDownCalls);

        ITroveManager.LatestTroveData memory finalData2 = troveManager.getLatestTroveData(troveId);
        assertLt(finalData2.entireDebt, finalData.entireDebt);
    }

    // --- internal swapper function ---

    function _swapUSDCtoToken(uint256 amountToSwap, address tokenToObtain) private {
        // Swap USDC to tokenToObtain using the mock dex
        address[] memory targets = new address[](3);
        targets[0] = USDC;
        targets[1] = address(mockDex);
        targets[2] = USDC;
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), amountToSwap);
        // assume 1:1 conversion rate with decimals
        data[1] = abi.encodeWithSignature(
            "swap(address,address,uint256,uint256)",
            USDC,
            tokenToObtain,
            amountToSwap,
            amountToSwap * 1e12
        );
        data[2] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), 0);
        UniversalTokenSwapperData memory swapData = UniversalTokenSwapperData({targets: targets, data: data});

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: USDC,
            tokenOut: tokenToObtain,
            amountIn: amountToSwap,
            data: swapData
        });

        FuseAction[] memory swapCalls = new FuseAction[](1);
        swapCalls[0] = FuseAction(
            address(swapFuse),
            abi.encodeWithSignature("enter((address,address,uint256,(address[],bytes[])))", enterData)
        );

        // swap
        plasmaVault.execute(swapCalls);
    }

    function testShouldAdjustInterestRateViaFuseEbisu() public {
        testShouldEnterToEbisuZapper();

        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);

        uint256 newRate = 30 * 1e16; // 30%

        EbisuAdjustInterestRateFuse.EbisuAdjustInterestRateFuseEnterData memory adjustData = EbisuAdjustInterestRateFuse
            .EbisuAdjustInterestRateFuseEnterData({
                zapper: SUSDE_ZAPPER,
                registry: SUSDE_REGISTRY,
                newAnnualInterestRate: newRate,
                maxUpfrontFee: 5 * 1e18,
                upperHint: 0,
                lowerHint: 0
            });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(adjustRateFuse),
            abi.encodeWithSelector(EbisuAdjustInterestRateFuse.enter.selector, adjustData)
        );

        plasmaVault.execute(calls);

        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);
        assertEq(troveData.annualInterestRate, newRate, "Interest rate was not updated by fuse");
    }

    function testShouldAdjustTroveViaFuseEbisu() public {
        testShouldEnterToEbisuZapper();

        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory initialTroveData = troveManager.getLatestTroveData(troveId);

        EbisuAdjustTroveFuse.EbisuAdjustTroveFuseEnterData memory adjustData = EbisuAdjustTroveFuse
            .EbisuAdjustTroveFuseEnterData({
                zapper: SUSDE_ZAPPER,
                registry: SUSDE_REGISTRY,
                collChange: 1000,
                debtChange: 500,
                isCollIncrease: true,
                isDebtIncrease: true,
                maxUpfrontFee: 5 * 1e18
            });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(adjustTroveFuse),
            abi.encodeWithSelector(EbisuAdjustTroveFuse.enter.selector, adjustData)
        );

        plasmaVault.execute(calls);

        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);
        assertEq(
            troveData.entireColl,
            initialTroveData.entireColl + adjustData.collChange,
            "Collateral was not updated by fuse"
        );
        assertEq(
            troveData.entireDebt,
            initialTroveData.entireDebt + adjustData.debtChange,
            "Debt was not updated by fuse"
        );

        // same but with coll and debt decrease
        adjustData = EbisuAdjustTroveFuse.EbisuAdjustTroveFuseEnterData({
            zapper: SUSDE_ZAPPER,
            registry: SUSDE_REGISTRY,
            collChange: 500,
            debtChange: 200,
            isCollIncrease: false,
            isDebtIncrease: false,
            maxUpfrontFee: 5 * 1e18
        });

        calls[0] = FuseAction(
            address(adjustTroveFuse),
            abi.encodeWithSelector(EbisuAdjustTroveFuse.enter.selector, adjustData)
        );

        plasmaVault.execute(calls);
        ITroveManager.LatestTroveData memory finalTroveData = troveManager.getLatestTroveData(troveId);
        assertEq(
            finalTroveData.entireColl,
            troveData.entireColl - 500, // 1000 - 500
            "Collateral was not updated by fuse"
        );
        assertEq(
            finalTroveData.entireDebt,
            troveData.entireDebt - 200, // 500 - 200
            "Debt was not updated by fuse"
        );
    }
    // --- helpers ---

    function _setupMarketConfigs(
        address _mockDex
    ) private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        // EBISU market substrates must include:
        // - all zappers used
        // - the corresponding address registries used
        bytes32[] memory ebisuSubs = new bytes32[](8);
        ebisuSubs[0] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: WEETH_ZAPPER, substrateType: EbisuZapperSubstrateType.ZAPPER})
        );
        ebisuSubs[1] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: SUSDE_ZAPPER, substrateType: EbisuZapperSubstrateType.ZAPPER})
        );
        ebisuSubs[2] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: WBTC_ZAPPER, substrateType: EbisuZapperSubstrateType.ZAPPER})
        );
        ebisuSubs[3] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: LBTC_ZAPPER, substrateType: EbisuZapperSubstrateType.ZAPPER})
        );
        ebisuSubs[4] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: WEETH_REGISTRY, substrateType: EbisuZapperSubstrateType.REGISTRY})
        );
        ebisuSubs[5] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: SUSDE_REGISTRY, substrateType: EbisuZapperSubstrateType.REGISTRY})
        );
        ebisuSubs[6] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: WBTC_REGISTRY, substrateType: EbisuZapperSubstrateType.REGISTRY})
        );
        ebisuSubs[7] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: LBTC_REGISTRY, substrateType: EbisuZapperSubstrateType.REGISTRY})
        );

        bytes32[] memory erc20Assets = new bytes32[](2);
        erc20Assets[0] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        erc20Assets[1] = PlasmaVaultConfigLib.addressToBytes32(SUSDE);

        bytes32[] memory swapperAssets = new bytes32[](4);
        swapperAssets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        swapperAssets[1] = PlasmaVaultConfigLib.addressToBytes32(SUSDE);
        swapperAssets[2] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        swapperAssets[3] = PlasmaVaultConfigLib.addressToBytes32(_mockDex);

        marketConfigs_ = new MarketSubstratesConfig[](3);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Assets);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.EBISU, ebisuSubs);
        marketConfigs_[2] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, swapperAssets);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        zapperFuse = new EbisuZapperCreateFuse(IporFusionMarkets.EBISU, WETH); // OPEN + CLOSE
        leverModifyFuse = new EbisuZapperLeverModifyFuse(IporFusionMarkets.EBISU);
        swapFuse = new UniversalTokenSwapperFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            address(new SwapExecutor()),
            1e18
        );
        transientStorageSetterFuse = new TransientStorageSetterFuse();

        adjustRateFuse = new EbisuAdjustInterestRateFuse(IporFusionMarkets.EBISU);
        adjustTroveFuse = new EbisuAdjustTroveFuse(IporFusionMarkets.EBISU);

        fuses = new address[](6);
        fuses[0] = address(zapperFuse);
        fuses[1] = address(leverModifyFuse);
        fuses[2] = address(adjustRateFuse);
        fuses[3] = address(adjustTroveFuse);
        fuses[4] = address(swapFuse);
        fuses[5] = address(transientStorageSetterFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = new EbisuZapperBalanceFuse(IporFusionMarkets.EBISU);
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses_ = new MarketBalanceFuseConfig[](3);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.EBISU, address(balanceFuse));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, address(zeroBalance));
        balanceFuses_[2] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager_ = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
        accessManager = accessManager_;
    }

    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            address(plasmaVault),
            IporFusionAccessManager(accessManager),
            address(0)
        );
    }

    function _eqWithTolerance(uint256 a, uint256 b, uint256 tol) private pure {
        // tol in basis points 1 = 0.01%
        assertLe(a, (b * (10000 + tol)) / 10000, "Equality with tolerance exceeded: a too big");
        assertGe((a * (10000 + tol)) / 10000, b, "Equality with tolerance exceeded: b too big");
    }
}
