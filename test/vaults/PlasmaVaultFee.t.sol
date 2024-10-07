// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction, FeeConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";

interface AavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

contract PlasmaVaultFeeTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    address public atomist = address(this);

    string public assetName;
    string public assetSymbol;
    address public underlyingToken;
    address public alpha;
    uint256 public amount;
    uint256 public sharesAmount;

    address public userOne;
    address public userTwo;
    address public performanceFeeManager;
    uint256 public performanceFeeInPercentage;
    address public managementFeeManager;
    uint256 public managementFeeInPercentage;

    PriceOracleMiddleware public priceOracleMiddlewareProxy;
    UsersToRoles public usersToRoles;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);

        userOne = address(0x777);
        userTwo = address(0x888);
        performanceFeeManager = address(0x999);
        managementFeeManager = address(0x555);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldExitFromTwoMarketsAaveV3SupplyAndCompoundV3SupplyAndCalculatePerformanceFee() public {
        //given
        performanceFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(
                    0,
                    0,
                    managementFeeInPercentage,
                    performanceFeeInPercentage,
                    address(new FeeManagerFactory()),
                    address(0),
                    address(0)
                ),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](2);

        amount = 100 * 1e6;

        performanceFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeManager;
        managementFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeManager;

        /// @dev user one deposit
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        /// @dev user two deposit
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);

        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: amount})
            )
        );

        vm.prank(alpha);
        plasmaVault.execute(calls);

        FuseAction[] memory callsSecond = new FuseAction[](2);

        callsSecond[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature("exit((address,uint256))", AaveV3SupplyFuseExitData({asset: USDC, amount: amount}))
        );

        callsSecond[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "exit((address,uint256))",
                CompoundV3SupplyFuseExitData({asset: USDC, amount: amount})
            )
        );

        vm.warp(block.timestamp + 365 days);

        //when
        vm.prank(alpha);
        plasmaVault.execute(callsSecond);

        //then
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 108536113);
        assertEq(userTwoBalanceOfAssets, 108536113);
        assertEq(performanceFeeManagerBalanceOfAssets, 894656);
    }

    function testShouldExitFromTwoMarketsAaveV3SupplyAndCompoundV3SupplyAndCalculatePerformanceFeeTimeIsNotChanged()
        public
    {
        //given
        performanceFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0)),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](2);

        amount = 100 * 1e6;

        /// @dev user one deposit
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        /// @dev user two deposit
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);

        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: amount})
            )
        );

        vm.prank(alpha);
        plasmaVault.execute(calls);

        FuseAction[] memory callsSecond = new FuseAction[](2);

        callsSecond[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature("exit((address,uint256))", AaveV3SupplyFuseExitData({asset: USDC, amount: amount}))
        );

        callsSecond[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "exit((address,uint256))",
                CompoundV3SupplyFuseExitData({asset: USDC, amount: amount})
            )
        );

        //when
        vm.prank(alpha);
        plasmaVault.execute(callsSecond);

        //then
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 99999999);
        assertEq(userTwoBalanceOfAssets, 99999999);
        assertEq(performanceFeeManagerBalanceOfAssets, 0);
    }

    function testShouldInstantWithdrawRequiredExitFromTwoMarketsAaveV3CompoundV3AndCalculatePerformanceFee() public {
        //given
        performanceFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(
                    0,
                    0,
                    managementFeeInPercentage,
                    performanceFeeInPercentage,
                    address(new FeeManagerFactory()),
                    address(0),
                    address(0)
                ),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        performanceFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeManager;
        managementFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeManager;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        /// @dev move time to gather interest
        vm.warp(block.timestamp + 365 days);

        //when
        vm.prank(userOne);
        plasmaVault.withdraw(75 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 28798996, "userOneBalanceOfAssets");
        assertEq(userTwoBalanceOfAssets, 103798996, "userTwoBalanceOfAssets");
        assertEq(performanceFeeManagerBalanceOfAssets, 399085, "daoBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldInstantWithdrawRequiredExitFromTwoMarketsAaveV3CompoundV3AndCalculatePerformanceFeeTimeIsNotChanged()
        public
    {
        //given
        performanceFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0)),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        //when
        vm.prank(userOne);
        plasmaVault.withdraw(75 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 24999999, "userOneBalanceOfAssets on plasma vault stayed 25 usd");
        assertApproxEqAbs(
            userTwoBalanceOfAssets,
            amount,
            1,
            "userTwoBalanceOfAssets on plasma vault stayed 100 usd aprox"
        );
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "daoBalanceOfAssets - no interest when time is not changed");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldInstantWithdrawNoTouchedMarketsAndCalculatePerformanceFeeTimeIsNotChanged() public {
        //given
        performanceFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0)),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        //when
        vm.prank(userOne);
        plasmaVault.withdraw(75 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 24999999, "userOneBalanceOfAssets on plasma vault stayed 25 usd");
        assertApproxEqAbs(
            userTwoBalanceOfAssets,
            amount,
            1,
            "userTwoBalanceOfAssets on plasma vault stayed 100 usd aprox"
        );
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "daoBalanceOfAssets - no interest when time is not changed");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldInstantWithdrawNoTouchedMarketsAndCalculatePerformanceFeeTimeChanged365days() public {
        //given
        performanceFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0)),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        /// @dev move time to gather interest
        vm.warp(block.timestamp + 365 days);

        //when
        vm.prank(userOne);
        plasmaVault.withdraw(75 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 24999999, "userOneBalanceOfAssets on plasma vault stayed 25 usd");
        assertApproxEqAbs(
            userTwoBalanceOfAssets,
            amount,
            1,
            "userTwoBalanceOfAssets on plasma vault stayed 100 usd aprox"
        );
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "daoBalanceOfAssets - no interest when time is not changed");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
        //100000000
        //99999999
    }

    function testShouldRedeemExitFromOneMarketAaveV3AndCalculatePerformanceFeeTimeIsChanged() public {
        //given
        performanceFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(
                    0,
                    0,
                    0,
                    performanceFeeInPercentage,
                    address(new FeeManagerFactory()),
                    address(0),
                    address(0)
                ),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        performanceFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeManager;
        managementFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeManager;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        FuseAction[] memory calls = new FuseAction[](1);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        /// @dev move time to gather interest
        vm.warp(block.timestamp + 365 days);

        uint256 sharesRedeemAmount = 70 * 10 ** plasmaVault.decimals();

        //when
        vm.prank(userOne);
        plasmaVault.redeem(sharesRedeemAmount, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 32279599, "userOneBalanceOfAssets on plasma vault");
        assertEq(userTwoBalanceOfAssets, 107598664, "userTwoBalanceOfAssets on plasma vault");
        assertApproxEqAbs(performanceFeeManagerBalanceOfAssets, 796753, 1, "daoBalanceOfAssets aprox");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldRedeemExitFromOneMarketAaveV3AndCalculatePerformanceFeeTimeIsNOTChanged() public {
        //given
        performanceFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0)),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        FuseAction[] memory calls = new FuseAction[](1);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        uint256 sharesRedeemAmount = 70 * 10 ** plasmaVault.decimals();
        //when
        vm.prank(userOne);
        plasmaVault.redeem(sharesRedeemAmount, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 30000000, "userOneBalanceOfAssets on plasma vault");
        assertEq(userTwoBalanceOfAssets, 100000000, "userTwoBalanceOfAssets on plasma vault");
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "daoBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldCalculateManagementFeeWhenTwoDepositsInDifferentTime() public {
        //given
        performanceFeeInPercentage = 0;
        managementFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        vm.warp(block.timestamp);

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(
                    0,
                    0,
                    managementFeeInPercentage,
                    performanceFeeInPercentage,
                    address(new FeeManagerFactory()),
                    address(0),
                    address(0)
                ),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        performanceFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeManager;
        managementFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeManager;
        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        vm.warp(block.timestamp + 365 days);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );
        uint256 managementFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(managementFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 95238095, "userOneBalanceOfAssets on plasma vault");
        assertEq(userTwoBalanceOfAssets, 99999999, "userTwoBalanceOfAssets on plasma vault");
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "performanceFeeManagerBalanceOfAssets");
        assertEq(managementFeeManagerBalanceOfAssets, 4761904, "managementFeeManagerBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldCalculateManagementFeeWhenTwoMintsInDifferentTime() public {
        //given
        performanceFeeInPercentage = 0;
        managementFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(
                    0,
                    0,
                    managementFeeInPercentage,
                    performanceFeeInPercentage,
                    address(new FeeManagerFactory()),
                    address(0),
                    address(0)
                ),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        performanceFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeManager;
        managementFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeManager;

        vm.warp(block.timestamp);

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);

        vm.prank(userOne);
        plasmaVault.mint(sharesAmount, userOne);

        uint256 userOneBalanceOfAssetsBefore = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));

        vm.warp(block.timestamp + 365 days);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);

        vm.prank(userTwo);
        plasmaVault.mint(sharesAmount, userTwo);

        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssetsAfter = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssetsAfter = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );
        uint256 managementFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(managementFeeManager)
        );

        assertEq(userOneBalanceOfAssetsBefore, 100000000, "userOneBalanceOfAssetsBefore");
        assertEq(userOneBalanceOfAssetsAfter, 95238095, "userOneBalanceOfAssetsAfter");

        assertEq(userTwoBalanceOfAssetsAfter, 95238095, "userTwoBalanceOfAssetsAfter");
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "performanceFeeManagerBalanceOfAssets");
        assertEq(managementFeeManagerBalanceOfAssets, 4761904, "managementFeeManagerBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldNOTCalculateManagementFeeWhenTwoDepositsInDifferentTime() public {
        //given
        performanceFeeInPercentage = 0;
        managementFeeInPercentage = 0; /// @dev management fee is 0

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0)),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        vm.warp(block.timestamp);

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        /// @dev move time to gather potential management fee
        vm.warp(block.timestamp + 365 days);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );
        uint256 managementFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(managementFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 100000000, "userOneBalanceOfAssets on plasma vault");
        assertEq(userTwoBalanceOfAssets, 100000000, "userTwoBalanceOfAssets on plasma vault");
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "performanceFeeManagerBalanceOfAssets");
        assertEq(managementFeeManagerBalanceOfAssets, 0, "managementFeeManagerBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldCalculateManagementFeeWhenTwoDepositsInTheSameTime() public {
        //given
        performanceFeeInPercentage = 0;
        managementFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0)),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        vm.warp(block.timestamp);

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );
        uint256 managementFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(managementFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 100000000, "userOneBalanceOfAssets on plasma vault");
        assertEq(userTwoBalanceOfAssets, 100000000, "userTwoBalanceOfAssets on plasma vault");
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "performanceFeeManagerBalanceOfAssets");
        assertEq(managementFeeManagerBalanceOfAssets, 0, "managementFeeManagerBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldRedeemExitFromOneMarketAaveV3AndCalculateManagementFeeTimeIsChanged() public {
        //given
        performanceFeeInPercentage = 0;
        managementFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(
                    0,
                    0,
                    managementFeeInPercentage,
                    performanceFeeInPercentage,
                    address(new FeeManagerFactory()),
                    address(0),
                    address(0)
                ),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        performanceFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeManager;
        managementFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeManager;

        vm.warp(block.timestamp);

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 2 * amount);
        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plasmaVault.balanceOf(userTwo);

        FuseAction[] memory calls = new FuseAction[](1);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        /// @dev move time to gather interest
        vm.warp(block.timestamp + 365 days);

        uint256 sharesRedeemAmount = 70 * 10 ** plasmaVault.decimals();

        //when
        vm.prank(userOne);
        plasmaVault.redeem(sharesRedeemAmount, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plasmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(userTwo));
        uint256 performanceFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(performanceFeeManager)
        );
        uint256 managementFeeManagerBalanceOfAssets = plasmaVault.convertToAssets(
            plasmaVault.balanceOf(managementFeeManager)
        );

        assertEq(userOneBalanceOfAssets, 30856297, "userOneBalanceOfAssets on plasma vault");
        assertEq(userTwoBalanceOfAssets, 102854325, "userTwoBalanceOfAssets on plasma vault");
        assertEq(performanceFeeManagerBalanceOfAssets, 0, "performanceFeeManagerBalanceOfAssets");
        assertEq(managementFeeManagerBalanceOfAssets, 10285432, "managementFeeManagerBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldNotAccruedManagementFeeWhenDepositWhenVaultIsEmpty() public {
        //given
        performanceFeeInPercentage = 0;
        managementFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(
                    0,
                    0,
                    managementFeeInPercentage,
                    performanceFeeInPercentage,
                    address(new FeeManagerFactory()),
                    address(0),
                    address(0)
                ),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 10_000 * 1e6;

        vm.warp(block.timestamp);

        /// @dev user one
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa);
        ERC20(USDC).transfer(address(userOne), 50 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 50 * amount);

        //when scenario

        /// @dev move time
        vm.warp(block.timestamp + 365 days);

        uint256 managementFeeAfter365DaysBeforeFirstDeposit = plasmaVault.getUnrealizedManagementFee();
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);
        uint256 managementFeeImmediatelyAfterFirstDeposit = plasmaVault.getUnrealizedManagementFee();

        /// @dev move time
        vm.warp(block.timestamp + 365 days);

        uint256 managementFeeAfter365DaysBeforeSecondDeposit = plasmaVault.getUnrealizedManagementFee();
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);
        uint256 managementFeeImmediatelyAfterSecondDeposit = plasmaVault.getUnrealizedManagementFee();

        /// @dev move time
        vm.warp(block.timestamp + 365 days);

        //solhint-disable-next-line
        managementFeeManager = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeManager;

        uint256 managementFeeAfter365DayBeforeMaxRedeem = plasmaVault.getUnrealizedManagementFee();
        vm.startPrank(userOne);
        plasmaVault.redeem(plasmaVault.maxRedeem(userOne), userOne, userOne);
        vm.stopPrank();
        vm.startPrank(managementFeeManager);
        plasmaVault.redeem(plasmaVault.maxRedeem(managementFeeManager), managementFeeManager, managementFeeManager);
        vm.stopPrank();
        uint256 managementFeeImmediatelyAfterMaxRedeem = plasmaVault.getUnrealizedManagementFee();

        vm.warp(block.timestamp + 365 days);

        uint256 managementFeeAfter365daysBeforeThirdDeposit = plasmaVault.getUnrealizedManagementFee();
        vm.prank(userOne);
        plasmaVault.deposit(5 * amount, userOne);
        uint256 managementFeeImmediatelyAfterThirdDeposit = plasmaVault.getUnrealizedManagementFee();

        uint256 managementFeeAfter365BeforeFourDeposit = plasmaVault.getUnrealizedManagementFee();
        vm.prank(userOne);
        plasmaVault.deposit(10 * amount, userOne);
        uint256 managementFeeImmediatelyAfterFourDeposit = plasmaVault.getUnrealizedManagementFee();

        vm.warp(block.timestamp + 365 days);

        uint256 managementFeeAfter365DaysAfterFourDeposit = plasmaVault.getUnrealizedManagementFee();

        //then
        assertEq(managementFeeAfter365DaysBeforeFirstDeposit, 0, "managementFeeAfter365DaysBeforeFirstDeposit");
        assertEq(managementFeeImmediatelyAfterFirstDeposit, 0, "managementFeeImmediatelyAfterFirstDeposit");
        assertEq(
            managementFeeAfter365DaysBeforeSecondDeposit,
            500000000,
            "managementFeeAfter365DaysBeforeSecondDeposit"
        );
        assertEq(managementFeeImmediatelyAfterSecondDeposit, 0, "managementFeeImmediatelyAfterSecondDeposit");
        assertEq(managementFeeAfter365DayBeforeMaxRedeem, 2 * 500000000, "managementFeeAfter365DayBeforeMaxRedeem");
        assertEq(managementFeeImmediatelyAfterMaxRedeem, 0, "managementFeeImmediatelyAfterMaxRedeem");
        assertEq(managementFeeAfter365daysBeforeThirdDeposit, 0, "managementFeeAfter365daysBeforeThirdDeposit");
        assertEq(managementFeeImmediatelyAfterThirdDeposit, 0, "managementFeeImmediatelyAfterThirdDeposit");
        assertEq(managementFeeAfter365BeforeFourDeposit, 0, "managementFeeAfter365BeforeFourDeposit");
        assertEq(managementFeeImmediatelyAfterFourDeposit, 0, "managementFeeImmediatelyAfterFourDeposit");
        assertEq(managementFeeAfter365DaysAfterFourDeposit, 7500000000, "managementFeeAfter365DaysAfterFourDeposit");
    }

    function testShouldNotInfluenceManagementFeeOnOtherDepositors() public {
        //given
        performanceFeeInPercentage = 0;
        managementFeeInPercentage = 500;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        address receiverOne = address(0x1111);
        address receiverTwo = address(0x2222);

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(
                    0,
                    0,
                    managementFeeInPercentage,
                    performanceFeeInPercentage,
                    address(new FeeManagerFactory()),
                    address(0),
                    address(0)
                ),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );

        setupRoles(plasmaVault, accessManager);

        amount = 100_000 * 1e6;

        vm.warp(block.timestamp);

        /// @dev user one
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa);
        ERC20(USDC).transfer(address(userOne), 5 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 5 * amount);

        /// @dev user two
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa);
        ERC20(USDC).transfer(address(userTwo), 5 * amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 5 * amount);

        /// @dev user managementFeeManager
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa);
        ERC20(USDC).transfer(address(managementFeeManager), 5 * amount);
        vm.prank(managementFeeManager);
        ERC20(USDC).approve(address(plasmaVault), 5 * amount);

        // when scenario

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        vm.warp(block.timestamp + 365 days);

        vm.startPrank(userOne);
        plasmaVault.redeem(plasmaVault.maxRedeem(userOne), receiverOne, userOne);
        vm.stopPrank();

        uint256 usdcBalanceOfReceiverOne = ERC20(USDC).balanceOf(receiverOne);

        vm.warp(block.timestamp + 365 days);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        vm.prank(userTwo);
        plasmaVault.deposit(amount, userTwo);

        /// @dev scenario when managementFeeManager have more shares
        vm.prank(managementFeeManager);
        plasmaVault.deposit(amount, managementFeeManager);

        vm.warp(block.timestamp + 365 days);

        vm.startPrank(userTwo);
        plasmaVault.redeem(plasmaVault.maxRedeem(userTwo), receiverTwo, userTwo);
        vm.stopPrank();

        uint256 usdcBalanceOfReceiverTwo = ERC20(USDC).balanceOf(receiverTwo);

        //then
        assertEq(
            usdcBalanceOfReceiverOne,
            usdcBalanceOfReceiverTwo,
            "usdcBalanceOfReceiverOne = usdcBalanceOfReceiverTwo"
        );
    }

    function createAccessManager(
        UsersToRoles memory usersToRoles,
        uint256 redemptionDelay_
    ) public returns (IporFusionAccessManager) {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles, redemptionDelay_, vm);
    }

    function setupRoles(PlasmaVault plasmaVault, IporFusionAccessManager accessManager) public {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }
}
