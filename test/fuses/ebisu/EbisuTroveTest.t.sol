// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {EbisuFuse, EbisuTroveEnterData, EbisuTroveExitData} from "../../../contracts/fuses/ebisu/EbisuFuse.sol";
import {EbisuTroveBalanceFuse} from "../../../contracts/fuses/ebisu/EbisuTroveBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperData, UniversalTokenSwapperEnterData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {SwapExecutor} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";
import {FixedValuePriceFeed} from "../../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";

interface EbisuPriceFeed {
    function lastGoodPrice() external view returns (uint256);
}

interface EBUSDPriceFeed {
    function latestRound() external view returns (uint256);
}

contract EbisuTroveTest is Test {
    // Borrow Asset
    address internal constant EBUSD = 0x09fD37d9AA613789c517e76DF1c53aEce2b60Df4; // debt token    
    // Collateral Assets
    address internal constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // collateral token    
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;
    // Gas Asset
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Ebisu registries for collateral asset
    address internal constant REGISTRY_WEETH = 0x329a7BAA50BB43A6149AF8C9cF781876b6Fd7B3A;
    address internal constant REGISTRY_SUSDE = 0x411ED8575a1e3822Bbc763DC578dd9bFAF526C1f;
    address internal constant REGISTRY_WBTC = 0x0CAc6a40EE0D35851Fd6d9710C5180F30B494350;
    address internal constant REGISTRY_LBTC = 0x7f034988AF49248D3d5bD81a2CE76ED4a3006243;

    address private plasmaVault;
    address private accessManager;
    address private priceOracle;
    ERC20BalanceFuse private erc20BalanceFuse;
    address private balanceFuse;
    EbisuFuse private _ebisuFuse;

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

        PlasmaVaultInitData memory initData = PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvWEETH",
                WEETH,
                priceOracle,
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                address(new WithdrawManager(accessManager))
            );
        
        plasmaVault = address(new PlasmaVault(initData));

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EBISU_STABILITY_POOL;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence; // Ebisu -> ERC20_VAULT_BALANCE

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
    }

    function testEbisuTroveShouldEnter() public {
        EbisuTroveEnterData memory enterData = EbisuTroveEnterData({
            registry: REGISTRY_WEETH,
            newIndex: 1,
            collAmount: 2000 * 1e18,
            ebusdAmount: 2000 * 1e18,
            upperHint: 0,
            lowerHint: 0,
            annualInterestRate: 1e16,
            maxUpfrontFee: 4e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ebisuFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        deal(WEETH, address(this), 200000 * 1e18);
        deal(WETH, plasmaVault, 100 * 1e18); // Provide WETH directly to PlasmaVault for upfront fees
        ERC20(WEETH).approve(plasmaVault, 200000 * 1e18); // approve 200.000 WEETH
        PlasmaVault(plasmaVault).deposit(200000 * 1e18, address(this)); // deposit 200.000 WEETH
        PlasmaVault(plasmaVault).execute(enterCalls);
    }


    function testEbisuTroveShouldExit() public {
        testEbisuTroveShouldEnter();

        uint256[] memory ownerIndexes = new uint256[](1);
        ownerIndexes[0] = 1;
        EbisuTroveExitData memory exitData = EbisuTroveExitData(
            REGISTRY_WEETH,
            ownerIndexes
        );
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(_ebisuFuse),
            abi.encodeWithSignature("exit((address,uint256[]))", exitData)
        );

        // deal enough EBUSD to pay for the entire debt
        deal(EBUSD, plasmaVault, 3 * 1e22);
        PlasmaVault(plasmaVault).execute(exitCalls);
    }


    function _setupMarketConfigs() private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory registries = new bytes32[](4);
        registries[0] = PlasmaVaultConfigLib.addressToBytes32(REGISTRY_WEETH);
        registries[1] = PlasmaVaultConfigLib.addressToBytes32(REGISTRY_SUSDE);
        registries[2] = PlasmaVaultConfigLib.addressToBytes32(REGISTRY_WBTC);
        registries[3] = PlasmaVaultConfigLib.addressToBytes32(REGISTRY_LBTC);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.EBISU_TROVE, registries);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _ebisuFuse = new EbisuFuse(IporFusionMarkets.EBISU_TROVE);

        fuses = new address[](1);
        fuses[0] = address(_ebisuFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = address(new EbisuTroveBalanceFuse(IporFusionMarkets.EBISU_TROVE));
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses_ = new MarketBalanceFuseConfig[](3);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.EBISU_TROVE, balanceFuse);
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
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, plasmaVault, IporFusionAccessManager(accessManager),
            address(0));
    }
}