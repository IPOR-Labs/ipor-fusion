// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    MarketSubstratesConfig,
    MarketBalanceFuseConfig,
    FeeConfig,
    FuseAction,
    PlasmaVault,
    PlasmaVaultInitData
} from "../../../contracts/vaults/PlasmaVault.sol";

import {
    EbisuZapperCreateFuse,
    EbisuZapperCreateFuseEnterData,
    EbisuZapperCreateFuseExitData
} from "../../../contracts/fuses/ebisu/EbisuZapperCreateFuse.sol";

import {EbisuAdjustInterestRateFuse} from "../../../contracts/fuses/ebisu/EbisuAdjustInterestRateFuse.sol";
import {EbisuAdjustTroveFuse} from "../../../contracts/fuses/ebisu/EbisuAdjustTroveFuse.sol";
import {
    EbisuClaimCollateralFuse,
    EbisuClaimCollateralFuseEnterData
} from "../../../contracts/fuses/ebisu/EbisuClaimCollateralFuse.sol";
import {ICollSurplusPool} from "../../../contracts/fuses/ebisu/ext/ICollSurplusPool.sol";

import {EbisuZapperBalanceFuse} from "../../../contracts/fuses/ebisu/EbisuZapperBalanceFuse.sol";
import {ITroveManager} from "../../../contracts/fuses/ebisu/ext/ITroveManager.sol";
import {IAddressesRegistry} from "../../../contracts/fuses/ebisu/ext/IAddressesRegistry.sol";
import {IPriceFeed} from "../../../contracts/fuses/ebisu/ext/IPriceFeed.sol";
import {ILeverageZapper} from "../../../contracts/fuses/ebisu/ext/ILeverageZapper.sol";
import {EbisuMathLib} from "../../../contracts/fuses/ebisu/lib/EbisuMathLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
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
import {
    UniversalTokenSwapperFuse,
    UniversalTokenSwapperData,
    UniversalTokenSwapperEnterData
} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {SwapExecutor} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";

import {
    EbisuZapperLeverModifyFuse,
    EbisuZapperLeverModifyFuseEnterData,
    EbisuZapperLeverModifyFuseExitData
} from "../../../contracts/fuses/ebisu/EbisuZapperLeverModifyFuse.sol";
import {WethEthAdapterStorageLib} from "../../../contracts/fuses/ebisu/lib/WethEthAdapterStorageLib.sol";
import {
    EbisuZapperSubstrateLib,
    EbisuZapperSubstrate,
    EbisuZapperSubstrateType
} from "../../../contracts/fuses/ebisu/lib/EbisuZapperSubstrateLib.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {TransientStorageSetterFuse} from "../../test_helpers/TransientStorageSetterFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {UniversalTokenSwapperSubstrateLib} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperSubstrateLib.sol";

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

interface IEbisuRegistryBm {
    function branchManager() external view returns (address);
}

interface IEbisuTroveManagerZombie {
    function setTroveStatusToZombie(uint256 troveId) external;
}

interface ITroveManagerLiquidation {
    function batchLiquidateTroves(uint256[] calldata troveArray) external;
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
    EbisuClaimCollateralFuse private claimCollateralFuse;

    address private accessManager;
    PriceOracleMiddleware private priceOracle;

    EbisuWethEthAdapterAddressReader private wethEthAdapterAddressReader;
    // ETH gas compensation constant from zapper (keep in sync with fuse)
    uint256 private constant ETH_GAS_COMPENSATION = 0.0375 ether;

    MockDex private mockDex;

    /// @dev collateral price (bps of the last good price) at which the vault Trove is liquidatable and leaves a surplus
    uint256 private constant SURPLUS_PRICE_BPS = 9_500;

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
            abi.encodeWithSignature("exit((address,bool,uint256,uint256))", exitData)
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
            abi.encodeWithSignature("exit((address,bool,uint256,uint256))", exitData)
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
            abi.encodeWithSignature("exit((address,bool,uint256,uint256))", exitData)
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
            abi.encodeWithSignature("exit((address,bool,uint256,uint256))", exitData)
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

    // --- liquidation (stale Trove id) ---

    event EbisuZapperCreateFuseStaleTroveCleared(address zapper, uint256 troveId, uint8 status);

    function _susdeEnterData() private pure returns (EbisuZapperCreateFuseEnterData memory) {
        return
            EbisuZapperCreateFuseEnterData({
                zapper: SUSDE_ZAPPER,
                registry: SUSDE_REGISTRY,
                collAmount: 4_000 * 1e18,
                ebusdAmount: 5_000 * 1e18,
                upperHint: 0,
                lowerHint: 0,
                flashLoanAmount: 1_000 * 1e18,
                annualInterestRate: 20 * 1e16,
                maxUpfrontFee: 5 * 1e18
            });
    }

    function _enterCalls(EbisuZapperCreateFuseEnterData memory enterData_) private view returns (FuseAction[] memory) {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
                enterData_
            )
        );
        return calls;
    }

    /// @dev Funds the vault with sUSDe collateral and WETH gas compensation, then opens a Trove with the fuse
    function _fundAndOpenSusdeTrove(bool deposit_) private {
        if (deposit_) {
            deal(USDC, address(this), 100_000 * 1e6);
            ERC20(USDC).approve(address(plasmaVault), 100_000 * 1e6);
            plasmaVault.deposit(100_000 * 1e6, address(this));
        }
        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);
        _swapUSDCtoToken(4_000 * 1e6, SUSDE);
        plasmaVault.execute(_enterCalls(_susdeEnterData()));
    }

    /// @dev Opens a well collateralised Trove from a separate account (liquidation needs more than one Trove)
    function _openForeignSusdeTrove() private {
        address alice = address(0xA11CE);
        vm.deal(alice, 1 ether);
        deal(SUSDE, alice, 10_000 * 1e18);
        vm.startPrank(alice);
        ERC20(SUSDE).approve(SUSDE_ZAPPER, type(uint256).max);
        ILeverageZapper(SUSDE_ZAPPER).openLeveragedTroveWithRawETH{value: ETH_GAS_COMPENSATION}(
            ILeverageZapper.OpenLeveragedTroveParams({
                owner: alice,
                ownerIndex: 0,
                collAmount: 10_000 * 1e18,
                flashLoanAmount: 0,
                boldAmount: 3_000 * 1e18,
                upperHint: 0,
                lowerHint: 0,
                annualInterestRate: 50 * 1e16,
                batchManager: address(0),
                maxUpfrontFee: 100 * 1e18,
                addManager: address(0),
                removeManager: alice,
                receiver: alice
            })
        );
        vm.stopPrank();
    }

    function _liquidateFuseTrove(uint256 troveId_) private {
        // halve the collateral price so the vault Trove (ICR close to MCR) becomes liquidatable
        _liquidateFuseTroveAtPriceBps(troveId_, 5_000);
    }

    /// @dev Liquidates the Trove after scaling the Liquity collateral price to `priceBps_` / 10_000 of the last good price
    function _liquidateFuseTroveAtPriceBps(uint256 troveId_, uint256 priceBps_) private {
        _openForeignSusdeTrove();
        IPriceFeed feed = IAddressesRegistry(SUSDE_REGISTRY).priceFeed();
        uint256 price = (feed.lastGoodPrice() * priceBps_) / 10_000;
        vm.mockCall(address(feed), abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(price, false));
        uint256[] memory ids = new uint256[](1);
        ids[0] = troveId_;
        ITroveManagerLiquidation(ILeverageZapper(SUSDE_ZAPPER).troveManager()).batchLiquidateTroves(ids);
        vm.clearMockedCalls();
        assertEq(
            uint8(ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager()).getTroveStatus(troveId_)),
            uint8(ITroveManager.Status.closedByLiquidation),
            "Trove should be liquidated"
        );
    }

    function _vaultTroveId(uint256 ownerIndex_) private view returns (uint256) {
        return
            EbisuMathLib.calculateTroveId(
                wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault)),
                address(plasmaVault),
                SUSDE_ZAPPER,
                ownerIndex_
            );
    }

    function testShouldOpenNewTroveAfterLiquidation() public {
        // given
        _fundAndOpenSusdeTrove(true);
        uint256 firstTroveId = _vaultTroveId(1);
        _liquidateFuseTrove(firstTroveId);

        // the stale id still blocks nothing: a fresh enter needs fresh collateral and gas compensation
        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);
        _swapUSDCtoToken(4_000 * 1e6, SUSDE);

        // when
        vm.expectEmit(false, false, false, true, address(plasmaVault));
        emit EbisuZapperCreateFuseStaleTroveCleared(
            SUSDE_ZAPPER,
            firstTroveId,
            uint8(ITroveManager.Status.closedByLiquidation)
        );
        plasmaVault.execute(_enterCalls(_susdeEnterData()));

        // then
        uint256 secondTroveId = _vaultTroveId(2);
        assertTrue(secondTroveId != firstTroveId, "new trove id must differ");
        assertEq(
            uint8(ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager()).getTroveStatus(secondTroveId)),
            uint8(ITroveManager.Status.active),
            "new Trove should be active"
        );
    }

    function testShouldClearStaleTroveOnExitAfterLiquidation() public {
        // given
        _fundAndOpenSusdeTrove(true);
        _liquidateFuseTrove(_vaultTroveId(1));

        EbisuZapperCreateFuseExitData memory exitData = EbisuZapperCreateFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 0,
            minExpectedCollateral: 0,
            exitFromCollateral: false
        });
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature("exit((address,bool,uint256,uint256))", exitData)
        );
        // give the vault some ebUSD so that a wrongly executed transfer to the adapter would be visible
        deal(EBUSD, address(plasmaVault), 1_000 * 1e18);
        address adapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        uint256 ebusdBefore = ERC20(EBUSD).balanceOf(address(plasmaVault));
        uint256 adapterEbusdBefore = ERC20(EBUSD).balanceOf(adapter);

        // when
        vm.expectEmit(false, false, false, true, address(plasmaVault));
        emit EbisuZapperCreateFuseStaleTroveCleared(
            SUSDE_ZAPPER,
            _vaultTroveId(1),
            uint8(ITroveManager.Status.closedByLiquidation)
        );
        plasmaVault.execute(exitCalls);

        // then: no ebUSD was moved to the adapter and the slot is empty (a second exit is TroveNotOpen)
        assertEq(ERC20(EBUSD).balanceOf(address(plasmaVault)), ebusdBefore, "vault ebUSD must not change");
        assertEq(ERC20(EBUSD).balanceOf(adapter), adapterEbusdBefore, "adapter ebUSD must not change");
        vm.expectRevert(abi.encodeWithSignature("TroveNotOpen()"));
        plasmaVault.execute(exitCalls);

        ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
            address(balanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );
        assertEq(abi.decode(readResult.data, (uint256)), 0, "Ebisu balance should be 0 after clearing");
    }

    // --- collateral surplus (claim + valuation) ---

    event EbisuClaimCollateralFuseEnter(address registry, address collToken, uint256 amount);

    function _ebisuBalance() private view returns (uint256) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
            address(balanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );
        return abi.decode(readResult.data, (uint256));
    }

    function _claimCalls(address registry_) private view returns (FuseAction[] memory) {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(claimCollateralFuse),
            abi.encodeWithSignature("enter((address))", EbisuClaimCollateralFuseEnterData({registry: registry_}))
        );
        return calls;
    }

    /// @dev Opens the vault Trove and liquidates it at a collateral price that leaves a surplus for the owner
    function _openAndLiquidateWithSurplus() private returns (uint256 surplus) {
        _fundAndOpenSusdeTrove(true);
        _liquidateFuseTroveAtPriceBps(_vaultTroveId(1), SURPLUS_PRICE_BPS);
        surplus = ICollSurplusPool(IAddressesRegistry(SUSDE_REGISTRY).collSurplusPool()).getCollateral(
            address(plasmaVault)
        );
    }

    /// @dev A third party (griefer) opens a Trove that names the vault as owner and gets it liquidated, which books a
    ///      collateral surplus for the vault in the CollSurplusPool. The vault itself never opens a Trove here.
    function _giftSurplusToVault() private returns (uint256 surplus) {
        address griefer = address(0xBADD1E);
        vm.deal(griefer, 1 ether);
        deal(SUSDE, griefer, 4_000 * 1e18);
        vm.startPrank(griefer);
        ERC20(SUSDE).approve(SUSDE_ZAPPER, type(uint256).max);
        ILeverageZapper(SUSDE_ZAPPER).openLeveragedTroveWithRawETH{value: ETH_GAS_COMPENSATION}(
            ILeverageZapper.OpenLeveragedTroveParams({
                owner: address(plasmaVault),
                ownerIndex: 0,
                collAmount: 4_000 * 1e18,
                flashLoanAmount: 1_000 * 1e18,
                boldAmount: 5_000 * 1e18,
                upperHint: 0,
                lowerHint: 0,
                annualInterestRate: 20 * 1e16,
                batchManager: address(0),
                maxUpfrontFee: 5 * 1e18,
                addManager: address(0),
                removeManager: griefer,
                receiver: griefer
            })
        );
        vm.stopPrank();

        /// @dev the Ebisu zapper derives the owner index from the caller, exactly as for the vault adapter
        uint256 troveId = EbisuMathLib.calculateTroveId(griefer, address(plasmaVault), SUSDE_ZAPPER, 0);
        _liquidateFuseTroveAtPriceBps(troveId, SURPLUS_PRICE_BPS);
        surplus = ICollSurplusPool(IAddressesRegistry(SUSDE_REGISTRY).collSurplusPool()).getCollateral(
            address(plasmaVault)
        );
    }

    function _mockSusdePriceUnsupported() private {
        vm.mockCallRevert(
            address(priceOracle),
            abi.encodeWithSelector(priceOracle.getAssetPrice.selector, SUSDE),
            abi.encodeWithSelector(IPriceOracleMiddleware.UnsupportedAsset.selector)
        );
    }

    /// @dev sUSDe is NOT an ERC20_VAULT_BALANCE substrate here, so a claim is enough to recover the refresh
    function testClaimRecoversRefreshWhenGiftedSurplusCollateralUnpriced() public {
        // given: only ebUSD is an ERC20 substrate
        bytes32[] memory erc20Assets = new bytes32[](1);
        erc20Assets[0] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            erc20Assets
        );
        uint256 surplus = _giftSurplusToVault();
        assertGt(surplus, 0, "gifted liquidation should leave a surplus");
        ICollSurplusPool pool = IAddressesRegistry(SUSDE_REGISTRY).collSurplusPool();
        uint256 vaultCollBefore = ERC20(SUSDE).balanceOf(address(plasmaVault));
        _mockSusdePriceUnsupported();

        uint256[] memory markets = new uint256[](1);
        markets[0] = IporFusionMarkets.EBISU;

        // when / then: the refresh is blocked by the unpriced surplus collateral
        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        plasmaVault.updateMarketsBalances(markets);

        // when: the claim moves the surplus into the vault
        plasmaVault.execute(_claimCalls(SUSDE_REGISTRY));

        // then: the next refresh passes
        plasmaVault.updateMarketsBalances(markets);
        assertEq(pool.getCollateral(address(plasmaVault)), 0, "pool surplus must be claimed");
        assertEq(ERC20(SUSDE).balanceOf(address(plasmaVault)), vaultCollBefore + surplus, "vault receives the surplus");
        assertEq(plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU), 0, "Ebisu market must be empty");
    }

    /// @dev sUSDe IS an ERC20_VAULT_BALANCE substrate (default setUp) and unpriced, so the claim itself reverts
    function testClaimRevertsWhenUnpricedSurplusCollateralIsErc20Substrate() public {
        // given
        uint256 surplus = _giftSurplusToVault();
        assertGt(surplus, 0, "gifted liquidation should leave a surplus");
        ICollSurplusPool pool = IAddressesRegistry(SUSDE_REGISTRY).collSurplusPool();
        _mockSusdePriceUnsupported();
        FuseAction[] memory calls = _claimCalls(SUSDE_REGISTRY);

        // when / then: the post-claim refresh of the dependent ERC20 market cannot price sUSDe
        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        plasmaVault.execute(calls);
        assertEq(pool.getCollateral(address(plasmaVault)), surplus, "failed claim must leave the surplus in the pool");

        // when: the price source is back
        vm.clearMockedCalls();
        plasmaVault.execute(calls);

        // then
        assertEq(pool.getCollateral(address(plasmaVault)), 0, "pool surplus must be claimed");
        assertEq(ERC20(SUSDE).balanceOf(address(plasmaVault)), surplus, "vault receives the surplus");
    }

    function testShouldValueCollateralSurplusInBalanceAfterLiquidation() public {
        // given
        uint256 surplus = _openAndLiquidateWithSurplus();
        assertGt(surplus, 0, "liquidation should leave a surplus");

        // when
        uint256 ebisuBalance = _ebisuBalance();

        // then: the Trove is gone, so the whole balance is the pool surplus priced by the oracle
        (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
        uint256 expected = IporMath.convertToWad(surplus * price, ERC20(SUSDE).decimals() + priceDecimals);
        assertGt(expected, 0, "expected surplus value should be positive");
        assertEq(ebisuBalance, expected, "Ebisu balance must equal the surplus value");
    }

    function testShouldNotQueryCollateralPriceWhenRegistryBranchHasNoSurplus() public {
        // given: every branch is granted as REGISTRY, none has a surplus, and the collateral prices revert
        address[4] memory collaterals = [WEETH, SUSDE, WBTC, LBTC];
        for (uint256 i; i < collaterals.length; ++i) {
            vm.mockCallRevert(
                address(priceOracle),
                abi.encodeWithSelector(priceOracle.getAssetPrice.selector, collaterals[i]),
                bytes("price must not be requested")
            );
        }

        // when
        uint256 ebisuBalance = _ebisuBalance();

        // then
        assertEq(ebisuBalance, 0, "no trove and no surplus means zero balance");
    }

    function testShouldClaimCollateralSurplusAndKeepNavUnchanged() public {
        // given
        uint256 surplus = _openAndLiquidateWithSurplus();
        assertGt(surplus, 0, "liquidation should leave a surplus");
        ICollSurplusPool pool = IAddressesRegistry(SUSDE_REGISTRY).collSurplusPool();

        uint256[] memory markets = new uint256[](2);
        markets[0] = IporFusionMarkets.EBISU;
        markets[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        plasmaVault.updateMarketsBalances(markets);
        uint256 navBefore = plasmaVault.totalAssets();
        uint256 ebisuBefore = plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU);
        uint256 erc20Before = plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        uint256 vaultCollBefore = ERC20(SUSDE).balanceOf(address(plasmaVault));
        assertGt(ebisuBefore, 0, "surplus must be inside the Ebisu market before the claim");

        // when
        vm.expectEmit(false, false, false, true, address(plasmaVault));
        emit EbisuClaimCollateralFuseEnter(SUSDE_REGISTRY, SUSDE, surplus);
        plasmaVault.execute(_claimCalls(SUSDE_REGISTRY));

        // then
        assertEq(pool.getCollateral(address(plasmaVault)), 0, "pool surplus must be claimed");
        assertEq(ERC20(SUSDE).balanceOf(address(plasmaVault)), vaultCollBefore + surplus, "vault receives the surplus");

        uint256 ebisuAfter = plasmaVault.totalAssetsInMarket(IporFusionMarkets.EBISU);
        uint256 erc20After = plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        assertEq(ebisuAfter, 0, "Ebisu market must be empty after the claim");
        assertGt(erc20After, erc20Before, "ERC20 market must grow");
        assertApproxEqAbs(erc20After - erc20Before, ebisuBefore, 2, "ERC20 market gains what Ebisu market lost");
        assertApproxEqAbs(plasmaVault.totalAssets(), navBefore, 2, "NAV must not change across the claim");
    }

    function testShouldRevertClaimWhenNothingToClaim() public {
        // given: a vault with no liquidation, so the CollSurplusPool holds nothing for it
        _fundAndOpenSusdeTrove(true);
        assertEq(
            ICollSurplusPool(IAddressesRegistry(SUSDE_REGISTRY).collSurplusPool()).getCollateral(address(plasmaVault)),
            0
        );
        FuseAction[] memory calls = _claimCalls(SUSDE_REGISTRY);

        // when / then: Liquity itself rejects an empty claim, the fuse does not swallow it
        vm.expectRevert(bytes("CollSurplusPool: No collateral available to claim"));
        plasmaVault.execute(calls);
    }

    function testShouldRevertClaimWhenRegistryNotGranted() public {
        // given: a registry that is not a substrate of the market
        address ungranted = address(0xBEEF);
        FuseAction[] memory calls = _claimCalls(ungranted);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                EbisuClaimCollateralFuse.EbisuClaimCollateralFuseUnsupportedSubstrate.selector,
                ungranted
            )
        );
        plasmaVault.execute(calls);
    }

    function testShouldRevertClaimWhenZapperGivenAsRegistry() public {
        // given: the zapper is granted, but only as ZAPPER type, not REGISTRY
        FuseAction[] memory calls = _claimCalls(SUSDE_ZAPPER);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                EbisuClaimCollateralFuse.EbisuClaimCollateralFuseUnsupportedSubstrate.selector,
                SUSDE_ZAPPER
            )
        );
        plasmaVault.execute(calls);
    }

    function testShouldRevertClaimFuseWithZeroMarketId() public {
        vm.expectRevert(EbisuClaimCollateralFuse.EbisuClaimCollateralFuseInvalidMarketId.selector);
        new EbisuClaimCollateralFuse(0);
    }

    function testShouldRevertTroveAlreadyOpenWhenActive() public {
        // given
        _fundAndOpenSusdeTrove(true);
        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);
        _swapUSDCtoToken(4_000 * 1e6, SUSDE);

        // when / then
        FuseAction[] memory calls = _enterCalls(_susdeEnterData());
        vm.expectRevert(abi.encodeWithSignature("TroveAlreadyOpen()"));
        plasmaVault.execute(calls);
    }

    /// @dev Zombie Troves (below MIN_DEBT after a redemption) keep their NFT, so the id must stay stored.
    ///      Status is set through the TroveManager's own setter as the branch manager (the path Ebisu uses after a
    ///      redemption); a real redemption is not reproducible on this fork. Enum order checked against the
    ///      verified impl 0x96d4...3f86.
    function testShouldRevertTroveAlreadyOpenWhenZombie() public {
        // given
        _fundAndOpenSusdeTrove(true);
        uint256 troveId = _vaultTroveId(1);
        address troveManager = ILeverageZapper(SUSDE_ZAPPER).troveManager();
        vm.prank(IEbisuRegistryBm(SUSDE_REGISTRY).branchManager());
        IEbisuTroveManagerZombie(troveManager).setTroveStatusToZombie(troveId);
        assertEq(
            uint8(ITroveManager(troveManager).getTroveStatus(troveId)),
            uint8(ITroveManager.Status.zombie),
            "vendor zombie status"
        );
        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);
        _swapUSDCtoToken(4_000 * 1e6, SUSDE);

        // when / then
        FuseAction[] memory calls = _enterCalls(_susdeEnterData());
        vm.expectRevert(abi.encodeWithSignature("TroveAlreadyOpen()"));
        plasmaVault.execute(calls);
    }

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
        UniversalTokenSwapperData memory swapData = UniversalTokenSwapperData({
            targets: targets,
            data: data,
            tokensToReturn: new address[](0)
        });

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: USDC,
            tokenOut: tokenToObtain,
            amountIn: amountToSwap,
            minAmountOut: 0,
            data: swapData
        });

        FuseAction[] memory swapCalls = new FuseAction[](1);
        swapCalls[0] = FuseAction(
            address(swapFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,(address[],bytes[],address[])))", enterData)
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

        // Use new substrate encoding for UniversalTokenSwapper
        // Tokens used as tokenIn/tokenOut
        // Targets are addresses called during swap (including tokens for approve calls)
        bytes32[] memory swapperAssets = new bytes32[](8);
        swapperAssets[0] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(USDC);
        swapperAssets[1] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(SUSDE);
        swapperAssets[2] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(EBUSD);
        swapperAssets[3] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(_mockDex);
        swapperAssets[4] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(USDC); // called for approve
        swapperAssets[5] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(SUSDE); // called for approve
        swapperAssets[6] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(EBUSD); // called for approve
        swapperAssets[7] = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(5e16); // 5% slippage

        marketConfigs_ = new MarketSubstratesConfig[](3);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Assets);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.EBISU, ebisuSubs);
        marketConfigs_[2] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, swapperAssets);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        zapperFuse = new EbisuZapperCreateFuse(IporFusionMarkets.EBISU, WETH); // OPEN + CLOSE
        leverModifyFuse = new EbisuZapperLeverModifyFuse(IporFusionMarkets.EBISU);
        swapFuse = new UniversalTokenSwapperFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        transientStorageSetterFuse = new TransientStorageSetterFuse();

        adjustRateFuse = new EbisuAdjustInterestRateFuse(IporFusionMarkets.EBISU);
        adjustTroveFuse = new EbisuAdjustTroveFuse(IporFusionMarkets.EBISU);

        claimCollateralFuse = new EbisuClaimCollateralFuse(IporFusionMarkets.EBISU);

        fuses = new address[](7);
        fuses[0] = address(zapperFuse);
        fuses[1] = address(leverModifyFuse);
        fuses[2] = address(adjustRateFuse);
        fuses[3] = address(adjustTroveFuse);
        fuses[4] = address(swapFuse);
        fuses[5] = address(transientStorageSetterFuse);
        fuses[6] = address(claimCollateralFuse);
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
