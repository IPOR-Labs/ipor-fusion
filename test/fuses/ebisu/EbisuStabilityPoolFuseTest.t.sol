// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {EbisuStabilityPoolFuse, EbisuStabilityPoolFuseEnterData, EbisuStabilityPoolFuseExitData} from "../../../contracts/fuses/ebisu/EbisuStabilityPoolFuse.sol";
import {EbisuBalanceFuse} from "../../../contracts/fuses/ebisu/EbisuBalanceFuse.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperData, UniversalTokenSwapperEnterData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStabilityPool} from "../../../contracts/fuses/ebisu/ext/IStabilityPool.sol";
import {IAddressesRegistry} from "../../../contracts/fuses/ebisu/ext/IAddressesRegistry.sol";
import {SwapExecutor} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {FixedValuePriceFeed} from "../../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";

interface EbisuPriceFeed {
    function lastGoodPrice() external view returns (uint256);
}

interface EBUSDPriceFeed {
    function latestRound() external view returns (uint256);
}

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

contract EbisuStabilityPoolFuseTest is Test {
    address internal constant EBUSD = 0x09fD37d9AA613789c517e76DF1c53aEce2b60Df4;

    // Collateral Assets
    address internal constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;

    // Ebisu registries for collateral asset
    address internal constant REGISTRY_WEETH = 0x329a7BAA50BB43A6149AF8C9cF781876b6Fd7B3A;
    address internal constant REGISTRY_SUSDE = 0x411ED8575a1e3822Bbc763DC578dd9bFAF526C1f;
    address internal constant REGISTRY_WBTC = 0x0CAc6a40EE0D35851Fd6d9710C5180F30B494350;
    address internal constant REGISTRY_LBTC = 0x7f034988AF49248D3d5bD81a2CE76ED4a3006243;

    MockDex private mockDex;

    PlasmaVault private plasmaVault;
    EbisuStabilityPoolFuse private sbFuse;
    EbisuBalanceFuse private balanceFuse;
    ERC20BalanceFuse private erc20BalanceFuse;
    UniversalTokenSwapperFuse private swapFuse;
    address private accessManager;
    address private priceOracle;
    address private withdrawManager;

    uint256 private totalEBUSDInVault;
    uint256 private totalEBUSDToDeposit;
    uint256 private totalEBUSDToExit;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"));
        address[] memory assets = new address[](5);
        assets[0] = EBUSD; // borrowed
        assets[1] = WEETH; // collateral
        assets[2] = SUSDE; // collateral
        assets[3] = WBTC; // collateral
        assets[4] = LBTC; // collateral

        address[] memory priceFeeds = new address[](5);
        priceFeeds[0] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // EBUSD
        priceFeeds[1] = 0x36Fb029e6fEeC43d96BE2F8ccC0e572D1663F5fc; // WEETH feed
        priceFeeds[2] = 0x3E58FB6FFd3A568487c72A170411eBf7BE6A2062; // sUSDe feed
        priceFeeds[3] = 0x83387FF1234C2525ec0eb37DFE30d005356A222b; // WBTC feed
        priceFeeds[4] = 0x71AA4e0Ae5435AA3d4724d14dF91C5a26720Cc4f; // LBTC feed

        // Instantiate each PriceFeed and call .lastGoodPrice for the collateral assets skipping EBUSD
        uint256[] memory pricesFromFeeds = new uint256[](5);
        for (uint256 i = 1; i < 5; i++) {
            pricesFromFeeds[i] = EbisuPriceFeed(priceFeeds[i]).lastGoodPrice();
        }

        // now fetch the price of EBUSD from a diff price feed and set it in the priceFeeds[0]
        pricesFromFeeds[0] = EBUSDPriceFeed(priceFeeds[0]).latestRound();

        // logs all prices
        for (uint256 i = 0; i < 5; i++) {
            console.log("pricesFromFeeds[", i, "]", pricesFromFeeds[i]);
        }
        // set a FixedValuePriceFeed based on the pricesFromFeeds[0]
        FixedValuePriceFeed ebusdPriceFeed = new FixedValuePriceFeed(int256(pricesFromFeeds[0]));
        priceFeeds[0] = address(ebusdPriceFeed);

        FixedValuePriceFeed weethPriceFeed = new FixedValuePriceFeed(int256(pricesFromFeeds[1]));
        priceFeeds[1] = address(weethPriceFeed);

        FixedValuePriceFeed susdePriceFeed = new FixedValuePriceFeed(int256(pricesFromFeeds[2]));
        priceFeeds[2] = address(susdePriceFeed);

        FixedValuePriceFeed wbtcPriceFeed = new FixedValuePriceFeed(int256(pricesFromFeeds[3]));
        priceFeeds[3] = address(wbtcPriceFeed);

        FixedValuePriceFeed lbtcPriceFeed = new FixedValuePriceFeed(int256(pricesFromFeeds[4]));
        priceFeeds[4] = address(lbtcPriceFeed);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        implementation.initialize(address(this));
        implementation.setAssetsPricesSources(assets, priceFeeds);
        priceOracle = address(implementation);

        mockDex = new MockDex(WEETH, EBUSD);
        deal(EBUSD, address(mockDex), 1e6 * 1e6); // 1M EBUSD

        plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "TEST EBISU SP",
                "pvEBUSD",
                EBUSD,
                priceOracle,
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                address(new WithdrawManager(accessManager))
            )
        );

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs(address(mockDex))
        );

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EBISU_STABILITY_POOL;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence; // Ebisu -> ERC20_VAULT_BALANCE

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
    }

    function testShouldEnterToEbisuSB() public {
        totalEBUSDInVault = 300000 * 1e18;
        totalEBUSDToDeposit = 200000 * 1e18;

        deal(EBUSD, address(this), totalEBUSDInVault);
        ERC20(EBUSD).approve(address(plasmaVault), totalEBUSDInVault);
        plasmaVault.deposit(totalEBUSDInVault, address(this));

        uint256 assetBefore = plasmaVault.totalAssets();
        EbisuStabilityPoolFuseEnterData memory enterData = EbisuStabilityPoolFuseEnterData({
            registry: REGISTRY_WEETH,
            amount: totalEBUSDToDeposit
        });
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("enter((address,uint256))", enterData));

        // when
        plasmaVault.execute(enterCalls);

        // then
        uint256 assetAfter = plasmaVault.totalAssets();

        uint256 balance = ERC20(EBUSD).balanceOf(address(plasmaVault));

        assertEq(
            balance,
            totalEBUSDInVault - totalEBUSDToDeposit,
            "Balance should be zero after entering Stability Pool"
        );
        assertEq(assetAfter, assetBefore, "Assets should be equal to the initial assets");
    }

    function testShouldExitFromEbisuSB() public {
        // given
        testShouldEnterToEbisuSB();
        totalEBUSDToExit = 100000 * 1e18;

        EbisuStabilityPoolFuseExitData memory exitData = EbisuStabilityPoolFuseExitData({
            registry: REGISTRY_WEETH,
            amount: totalEBUSDToExit
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("exit((address,uint256))", exitData));
        // when
        plasmaVault.execute(exitCalls);

        // then
        uint256 balance = ERC20(EBUSD).balanceOf(address(plasmaVault));
        assertEq(
            balance,
            totalEBUSDInVault - totalEBUSDToDeposit + totalEBUSDToExit,
            "Balance should be equal to the exited amount from Stability Pool"
        );
        uint256 sbBalance = IStabilityPool(IAddressesRegistry(REGISTRY_WEETH).stabilityPool()).deposits(
            address(plasmaVault)
        );

        assertEq(
            sbBalance,
            totalEBUSDToDeposit - totalEBUSDToExit,
            "Stability Pool deposits should match the remaining amount after exit"
        );
    }

        function testShouldClaimCollateralFromEbisuSP() public {
        // given
        testShouldEnterToEbisuSB();

        IStabilityPool stabilityPool = IStabilityPool(IAddressesRegistry(REGISTRY_WEETH).stabilityPool());

        // simulate liquidation and trigger update (only prank troveManager here)
        vm.prank(address(stabilityPool.troveManager()));
        stabilityPool.offset(1e18, 1 ether);

        EbisuStabilityPoolFuseExitData memory exitData = EbisuStabilityPoolFuseExitData({
            registry: REGISTRY_WEETH,
            amount: 1
        });
        FuseAction[] memory exitCalls = new FuseAction[](1);
        // exiting from stability pool to trigger collateral claim
        exitCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("exit((address,uint256))", exitData));
        // when
        plasmaVault.execute(exitCalls);

        // then
        uint256 balance = ERC20(WEETH).balanceOf(address(plasmaVault));
        console.log("balance: ", balance);
        assertGt(balance, 0, "Balance should be greater than zero after claiming collateral");
    }

    function testShouldClaimCollateralFromEbisuSPThenSwap() public {
        // given
        testShouldClaimCollateralFromEbisuSP();

        // Swap WETH to BOLD using the mock dex
        uint256 amountToSwap = ERC20(WEETH).balanceOf(address(plasmaVault));
        assertGt(amountToSwap, 0, "There should be WEETH to swap");

        address[] memory targets = new address[](3);
        targets[0] = WEETH;
        targets[1] = address(mockDex);
        targets[2] = WEETH;
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), amountToSwap);
        data[1] = abi.encodeWithSignature("swap(uint256,uint256)", amountToSwap, 1e10);
        data[2] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), 0);
        UniversalTokenSwapperData memory swapData = UniversalTokenSwapperData({targets: targets, data: data});

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: WEETH,
            tokenOut: EBUSD,
            amountIn: amountToSwap,
            data: swapData
        });

        FuseAction[] memory swapCalls = new FuseAction[](1);
        swapCalls[0] = FuseAction(
            address(swapFuse),
            abi.encodeWithSignature("enter((address,address,uint256,(address[],bytes[])))", enterData)
        );

        uint256 initialBoldBalance = ERC20(EBUSD).balanceOf(address(plasmaVault));

        // when
        plasmaVault.execute(swapCalls);

        // then
        uint256 ebusdBalance = ERC20(EBUSD).balanceOf(address(plasmaVault));
        assertEq(ebusdBalance, initialBoldBalance + 1e10, "EBUSD should be obtained after the swap");
        uint256 wethBalance = ERC20(WEETH).balanceOf(address(plasmaVault));
        assertEq(wethBalance, 0, "WEETH balance should be zero after the swap");
    }

    function testShouldUpdateBalanceWhenProvidingAndLiquidatingToLiquity() external {
        // given
        uint256 initialBalance = plasmaVault.totalAssets();
        assertEq(initialBalance, 0, "Initial balance should be zero");

        deal(EBUSD, address(this), 1000 ether);
        ERC20(EBUSD).approve(address(plasmaVault), 1000 ether);
        plasmaVault.deposit(1000 ether, address(this));
        initialBalance = plasmaVault.totalAssets();
        assertEq(initialBalance, 1000 ether, "Balance should be 1000 EBUSD after dealing");

        EbisuStabilityPoolFuseEnterData memory enterData = EbisuStabilityPoolFuseEnterData({
            registry: REGISTRY_WEETH,
            amount: 500 ether
        });
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("enter((address,uint256))", enterData));

        // when
        plasmaVault.execute(enterCalls);

        // then
        uint256 afterDepBalance = plasmaVault.totalAssets();
        assertEq(afterDepBalance, initialBalance, "Balance should not change after providing to SP");

        IStabilityPool stabilityPool = IStabilityPool(IAddressesRegistry(REGISTRY_WEETH).stabilityPool());
        vm.prank(address(stabilityPool.troveManager()));
        // when
        stabilityPool.offset(1e18, 1 ether);

        //then
        uint256 afterLiquidationBalance = plasmaVault.totalAssets();
        assertEq(afterLiquidationBalance, afterDepBalance, "Balance should be equal after liquidation");

        enterData = EbisuStabilityPoolFuseEnterData({registry: REGISTRY_WEETH, amount: 1});
        enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("enter((address,uint256))", enterData));

        // when
        plasmaVault.execute(enterCalls);

        //then
        uint256 afterLiquidationAndUpdateBalance = plasmaVault.totalAssets();
        assertGt(afterLiquidationAndUpdateBalance, afterLiquidationBalance, "Balance should increase after update");

        EbisuStabilityPoolFuseExitData memory exitData = EbisuStabilityPoolFuseExitData({
            registry: REGISTRY_WEETH,
            amount: 1
        });
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("exit((address,uint256))", exitData));

        // when
        plasmaVault.execute(exitCalls);

        // then
        uint256 afterExitBalance = plasmaVault.totalAssets();
        assertGt(afterExitBalance, afterLiquidationBalance, "Balance should increase after liquidation");
    }

    function _setupMarketConfigs(
        address _mockDex
    ) private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](4);
        bytes32[] memory registries = new bytes32[](4);
        registries[0] = PlasmaVaultConfigLib.addressToBytes32(REGISTRY_WEETH);
        registries[1] = PlasmaVaultConfigLib.addressToBytes32(REGISTRY_SUSDE);
        registries[2] = PlasmaVaultConfigLib.addressToBytes32(REGISTRY_WBTC);
        registries[3] = PlasmaVaultConfigLib.addressToBytes32(REGISTRY_LBTC);
        bytes32[] memory swapperAssets = new bytes32[](3);
        swapperAssets[0] = PlasmaVaultConfigLib.addressToBytes32(WEETH);
        swapperAssets[1] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        swapperAssets[2] = PlasmaVaultConfigLib.addressToBytes32(_mockDex);
        bytes32[] memory erc20Assets = new bytes32[](2);
        erc20Assets[0] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        erc20Assets[1] = PlasmaVaultConfigLib.addressToBytes32(WEETH);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.EBISU_STABILITY_POOL, registries);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, swapperAssets);
        marketConfigs_[2] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Assets);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        sbFuse = new EbisuStabilityPoolFuse(IporFusionMarkets.EBISU_STABILITY_POOL);
        swapFuse = new UniversalTokenSwapperFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            address(new SwapExecutor()),
            1e18
        );

        fuses = new address[](2);
        fuses[0] = address(sbFuse);
        fuses[1] = address(swapFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = new EbisuBalanceFuse(IporFusionMarkets.EBISU_STABILITY_POOL);
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses_ = new MarketBalanceFuseConfig[](3);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.EBISU_STABILITY_POOL, address(balanceFuse));
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
