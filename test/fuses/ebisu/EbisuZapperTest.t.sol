// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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
    EbisuZapperCreateFuseExitData,
    ExitType
} from "../../../contracts/fuses/ebisu/EbisuZapperCreateFuse.sol";

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
import {UniversalTokenSwapperFuse, UniversalTokenSwapperData, UniversalTokenSwapperEnterData} 
    from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {SwapExecutor} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";

import {
    EbisuZapperLeverModifyFuse,
    EbisuLeverDownData,
    EbisuLeverUpData
} from "../../../contracts/fuses/ebisu/EbisuZapperLeverModifyFuse.sol";
import {WethEthAdapterStorageLib} from "../../../contracts/fuses/ebisu/lib/WethEthAdapterStorageLib.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} 
    from "../../../contracts/fuses/ebisu/lib/EbisuZapperSubstrateLib.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";

import {console2} from "forge-std/console2.sol";

contract MockDex {
    address tokenIn;
    address tokenOut;

    constructor(address _tokenIn, address _tokenOut) {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
    }

    function swap(uint256 amountIn, uint256 amountOut) public {
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
        assets[3] = WBTC;  // collateral
        assets[4] = LBTC;  // collateral
        assets[5] = WETH;  // compensation
        assets[6] = USDC;  // base token

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
                address(new WithdrawManager(accessManager))
            )
        );

        // mock dex to swap USDC into sUSDe
        mockDex = new MockDex(USDC, SUSDE);
        // deal 1_000_000_000 sUSDe to mockDex
        deal(SUSDE, address(mockDex), 1e9 * 1e18);
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
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EBISU;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence; // Ebisu -> ERC20_VAULT_BALANCE

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        // adapter address reader
        wethEthAdapterAddressReader = new EbisuWethEthAdapterAddressReader();

    }

    function testShouldEnterToEbisuZapper() public {
        // given
        EbisuZapperCreateFuseEnterData memory enterData = EbisuZapperCreateFuseEnterData({
            zapper: SUSDE_ZAPPER,
            registry: SUSDE_REGISTRY,
            collAmount: 10_000 * 1e18,        // 10_000 sUSDe collateral
            ebusdAmount: 5_000 * 1e18,        // 5_000 ebUSD debt
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 1_000 * 1e18,    // 1_000 further sUSDe from flashloan
            annualInterestRate: 20 * 1e16,    // 20%
            maxUpfrontFee: 5 * 1e18,
            wethForGas: ETH_GAS_COMPENSATION
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
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

        // check plasmaVault assets before executing
        uint256 totalAssets = plasmaVault.totalAssets();
        assertEq(totalAssets, 100_000 * 1e6);

        // now, in order to open a trove, we need to get collateral sUSDe through the Swapper (beware of decimals)
        _swapUSDCtoSUSDE(enterData.collAmount / 1e12);
        // check we have enough sUSDe
        assertEq(ERC20(SUSDE).balanceOf(address(plasmaVault)), enterData.collAmount, "Not enough sUSDe to enter");

        // when
        plasmaVault.execute(enterCalls);

        // Verify adapter was created
        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        assertTrue(wethEthAdapter != address(0), "Adapter should be created after execution");

        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);

        // Inspect trove state
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);

        // then
        // check troveData is populated (debt is a bit higher due to fees)
        assertGe(troveData.entireDebt, enterData.ebusdAmount);
        assertLt(troveData.entireDebt, (enterData.ebusdAmount * 101) / 100);
        assertEq(troveData.entireColl, enterData.collAmount + enterData.flashLoanAmount);

        // check balanceOf is updated with the collateral of the trove
        ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
            address(balanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );

        uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));
        // balanceOf() should be coll - debt
        (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
        uint256 collValue = IporMath.convertToWad(
            troveData.entireColl * price,
            18 + priceDecimals
        );
        (price, priceDecimals) = priceOracle.getAssetPrice(EBUSD);
        uint256 debtValue =  IporMath.convertToWad(
            troveData.entireDebt * price,
            18 + priceDecimals
        );

        assertEq(balanceOfFromFuse, 
            collValue - debtValue, 
            "balance after enter incorrect"
        );
    }

    function testShouldExitToETHFromEbisuZapper() public {
        // given
        testShouldEnterToEbisuZapper();

        // exiting to ETH means we need to manually pay the debt in EBUSD (through swapper but let's not overcomplicate)
        deal(EBUSD, address(this), 6_000 * 1e18);
        ERC20(EBUSD).transfer(address(plasmaVault), 6_000 * 1e18);

        EbisuZapperCreateFuseExitData memory exitData = EbisuZapperCreateFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 0,
            minExpectedCollateral: 0,
            exitType: ExitType.ETH
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "exit((address,uint256,uint256,uint8))",
                exitData
            )
        );

        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        assertTrue(wethEthAdapter != address(0), "Adapter should be created after execution");

        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        // when
        plasmaVault.execute(exitCalls);

        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);

        // then
        // trove should be closed
        assertEq(troveData.entireColl, 0);
        assertEq(troveData.entireDebt, 0);

        // balanceOf() should be zero (entirely ERC20 now)
        ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
            address(balanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );

        uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));
        assertEq(balanceOfFromFuse, 0, "residual balanceOf after exit");
    }

    function testShouldExitFromCollateralFromEbisuZapper() public {
        // given
        testShouldEnterToEbisuZapper();

        // no need of EBUSD to repay debt if closing from collateral
        EbisuZapperCreateFuseExitData memory exitData = EbisuZapperCreateFuseExitData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 10_000 * 1e18, // sUSDe needed to repay the debt
            minExpectedCollateral: 1_000 * 1e18,
            exitType: ExitType.COLLATERAL
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "exit((address,uint256,uint256,uint8))",
                exitData
            )
        );

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

        // balanceOf() should be zero (entirely ERC20 now)
        ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
            address(balanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );

        uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));
        assertEq(balanceOfFromFuse, 0, "residual balanceOf after exit");
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

        EbisuLeverUpData memory leverUpData = EbisuLeverUpData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 100 * 1e18,
            ebusdAmount: 500 * 1e18,
            maxUpfrontFee: 2 * 1e18
        });

        FuseAction[] memory leverUpCalls = new FuseAction[](1);
        leverUpCalls[0] = FuseAction(
            address(leverModifyFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256,uint256))", leverUpData)
        );

        // when
        plasmaVault.execute(leverUpCalls);

        ITroveManager.LatestTroveData memory finalData = troveManager.getLatestTroveData(troveId);
        uint256 finalDebt = finalData.entireDebt;
        uint256 finalColl = finalData.entireColl;

        // then
        assertGt(finalDebt, initialDebt, "Debt should have increased after lever up");
        assertGt(finalColl, initialColl, "Collateral should have increased after lever up");

        uint256 debtIncrease = finalDebt - initialDebt;
        assertGe(debtIncrease, (leverUpData.ebusdAmount * 90) / 100);
        assertLe(debtIncrease, (leverUpData.ebusdAmount * 110) / 100);


        // balanceOf() should be up to date
        ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
            address(balanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );

        uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));
        (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
        uint256 collValue = IporMath.convertToWad(
            finalColl * price,
            18 + priceDecimals
        );
        (price, priceDecimals) = priceOracle.getAssetPrice(EBUSD);
        uint256 debtValue =  IporMath.convertToWad(
            finalDebt * price,
            18 + priceDecimals
        );
        assertEq(balanceOfFromFuse, collValue - debtValue, "balance after lever up incorrect");
    }

    function testLeverDownEffectsEbisu() public {
        // given
        testShouldEnterToEbisuZapper();
        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        assertTrue(wethEthAdapter != address(0), "Adapter should be created after execution");

        uint256 troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());

        ITroveManager.LatestTroveData memory initialData = troveManager.getLatestTroveData(troveId);
        uint256 initialDebt = initialData.entireDebt;
        uint256 initialColl = initialData.entireColl;

        EbisuLeverDownData memory leverDownData = EbisuLeverDownData({
            zapper: SUSDE_ZAPPER,
            flashLoanAmount: 500 * 1e18,
            minBoldAmount: 200 * 1e18
        });

        FuseAction[] memory leverDownCalls = new FuseAction[](1);
        leverDownCalls[0] = FuseAction(
            address(leverModifyFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256))", leverDownData)
        );

        // when
        plasmaVault.execute(leverDownCalls);

        ITroveManager.LatestTroveData memory finalData = troveManager.getLatestTroveData(troveId);
        uint256 finalDebt = finalData.entireDebt;
        uint256 finalColl = finalData.entireColl;

        // then
        assertLt(finalDebt, initialDebt, "Debt should have decreased after lever down");
        assertLt(finalColl, initialColl, "Collateral should have decreased after lever down");

        // balanceOf() should be up to date
        ReadResult memory readResult = UniversalReader(address(plasmaVault)).read(
            address(balanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );

        uint256 balanceOfFromFuse = abi.decode(readResult.data, (uint256));
        (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(SUSDE);
        uint256 collValue = IporMath.convertToWad(
            finalColl * price,
            18 + priceDecimals
        );
        (price, priceDecimals) = priceOracle.getAssetPrice(EBUSD);
        uint256 debtValue =  IporMath.convertToWad(
            finalDebt * price,
            18 + priceDecimals
        );
        assertEq(balanceOfFromFuse, collValue - debtValue, "balance after lever up incorrect");
    }

    // --- internal swapper function ---

    function _swapUSDCtoSUSDE(uint256 amountToSwap) private {
        // Swap USDC to SUSDE using the mock dex
        address[] memory targets = new address[](3);
        targets[0] = USDC;
        targets[1] = address(mockDex);
        targets[2] = USDC;
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), amountToSwap);
        data[1] = abi.encodeWithSignature("swap(uint256,uint256)", amountToSwap, amountToSwap * 1e12); // assume 1:1 conversion rate with decimals
        data[2] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), 0);
        UniversalTokenSwapperData memory swapData = UniversalTokenSwapperData({targets: targets, data: data});

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: USDC,
            tokenOut: SUSDE,
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

    // --- helpers ---

    function _setupMarketConfigs(
        address _mockDex
    ) private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        // EBISU market substrates must include:
        // - all zappers used
        // - the corresponding address registries used
        bytes32[] memory ebisuSubs = new bytes32[](8);
        ebisuSubs[0] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({
                substrateAddress: WEETH_ZAPPER,
                substrateType: EbisuZapperSubstrateType.Zapper
            })
        );
        ebisuSubs[1] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({
                substrateAddress: SUSDE_ZAPPER,
                substrateType: EbisuZapperSubstrateType.Zapper
            })
        );
        ebisuSubs[2] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({
                substrateAddress: WBTC_ZAPPER,
                substrateType: EbisuZapperSubstrateType.Zapper
            })
        );
        ebisuSubs[3] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({
                substrateAddress: LBTC_ZAPPER,
                substrateType: EbisuZapperSubstrateType.Zapper
            })
        );
        ebisuSubs[4] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({
                substrateAddress: WEETH_REGISTRY,
                substrateType: EbisuZapperSubstrateType.Registry
            })
        );
        ebisuSubs[5] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({
                substrateAddress: SUSDE_REGISTRY,
                substrateType: EbisuZapperSubstrateType.Registry
            })
        );
        ebisuSubs[6] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({
                substrateAddress: WBTC_REGISTRY,
                substrateType: EbisuZapperSubstrateType.Registry
            })
        );
        ebisuSubs[7] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({
                substrateAddress: LBTC_REGISTRY,
                substrateType: EbisuZapperSubstrateType.Registry
            })
        );

        bytes32[] memory erc20Assets = new bytes32[](4);
        erc20Assets[0] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        erc20Assets[1] = PlasmaVaultConfigLib.addressToBytes32(SUSDE);
        erc20Assets[2] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        erc20Assets[3] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        bytes32[] memory swapperAssets = new bytes32[](3);
        swapperAssets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        swapperAssets[1] = PlasmaVaultConfigLib.addressToBytes32(SUSDE);
        swapperAssets[2] = PlasmaVaultConfigLib.addressToBytes32(_mockDex);

        marketConfigs_ = new MarketSubstratesConfig[](3);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Assets);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.EBISU, ebisuSubs);
        marketConfigs_[2] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, swapperAssets);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        zapperFuse   = new EbisuZapperCreateFuse(IporFusionMarkets.EBISU, WETH);      // OPEN + CLOSE
        leverModifyFuse  = new EbisuZapperLeverModifyFuse(IporFusionMarkets.EBISU);
        swapFuse = new UniversalTokenSwapperFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            address(new SwapExecutor()),
            1e18
        );

        fuses = new address[](3);
        fuses[0] = address(zapperFuse);
        fuses[1] = address(leverModifyFuse);
        fuses[2] = address(swapFuse);
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
}
