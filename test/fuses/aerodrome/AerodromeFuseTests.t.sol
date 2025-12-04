// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {AerodromeBalanceFuse} from "../../../contracts/fuses/aerodrome/AerodromeBalanceFuse.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "../../../contracts/fuses/aerodrome/AreodromeLib.sol";
import {AerodromeClaimFeesFuse, AerodromeClaimFeesFuseEnterData} from "../../../contracts/fuses/aerodrome/AerodromeClaimFeesFuse.sol";
import {AerodromeLiquidityFuse, AerodromeLiquidityFuseEnterData, AerodromeLiquidityFuseExitData} from "../../../contracts/fuses/aerodrome/AerodromeLiquidityFuse.sol";
import {AerodromeGaugeFuse, AerodromeGaugeFuseEnterData, AerodromeGaugeFuseExitData} from "../../../contracts/fuses/aerodrome/AerodromeGaugeFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IRouter} from "../../../contracts/fuses/aerodrome/ext/IRouter.sol";
import {AerodromeGaugeClaimFuse} from "../../../contracts/rewards_fuses/aerodrome/AerodromeGaugeClaimFuse.sol";
import {IGauge} from "../../../contracts/fuses/aerodrome/ext/IGauge.sol";

import {IWETH9} from "../erc4626/IWETH9.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {UniversalReader, ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";

/// @title AerodromeFuseTests
/// @notice Test suite for Aerodrome fuses on Base blockchain
/// @dev Tests Aerodrome liquidity provision, balance management, and fee claiming functionality
contract AerodromeFuseTests is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    // Test constants
    address private constant _UNDERLYING_TOKEN = TestAddresses.BASE_USDC;
    address private constant _WETH = TestAddresses.BASE_WETH;
    string private constant _UNDERLYING_TOKEN_NAME = "USDC";
    address private constant _USER = TestAddresses.USER;
    address private constant _ATOMIST = TestAddresses.ATOMIST;
    address private constant _FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant _ALPHA = TestAddresses.ALPHA;
    uint256 private constant ERROR_DELTA = 40000;

    address private constant _fusionFactory = 0x1455717668fA96534f675856347A973fA907e922;
    address private constant _AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    /// @dev Aerodrome Gauge address for USDC/WETH stable pool, for 0x3548029694fbB241D45FB24Ba0cd9c9d4E745f16 pool
    address private constant _AERODROME_GAUGE = 0xaeBA79D1108788E5754Eb30aaC64EB868a3247FC;
    address private constant _AERODROME_REWARD_TOKEN = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    PriceOracleMiddleware private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    AerodromeBalanceFuse private _aerodromeBalanceFuse;
    AerodromeClaimFeesFuse private _aerodromeClaimFeesFuse;
    AerodromeLiquidityFuse private _aerodromeLiquidityFuse;
    AerodromeGaugeFuse private _aerodromeGaugeFuse;
    AerodromeGaugeClaimFuse private _aerodromeGaugeClaimFuse;
    RewardsClaimManager private _rewardsClaimManager;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 32889330);

        FusionFactory fusionFactory = FusionFactory(_fusionFactory);

        FusionFactoryLib.FusionInstance memory fusionInstance = fusionFactory.create(
            "Aerodrome",
            "AERO",
            _UNDERLYING_TOKEN,
            0,
            _ATOMIST
        );

        _plasmaVault = PlasmaVault(fusionInstance.plasmaVault);
        _priceOracleMiddleware = PriceOracleMiddleware(fusionInstance.priceManager);
        _accessManager = IporFusionAccessManager(fusionInstance.accessManager);
        _plasmaVaultGovernance = PlasmaVaultGovernance(fusionInstance.plasmaVault);
        _rewardsClaimManager = RewardsClaimManager(fusionInstance.rewardsManager);

        vm.startPrank(_ATOMIST);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, _ATOMIST, 0);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, _FUSE_MANAGER, 0);
        _accessManager.grantRole(Roles.ALPHA_ROLE, _ALPHA, 0);
        _accessManager.grantRole(Roles.CLAIM_REWARDS_ROLE, _ALPHA, 0);
        _plasmaVaultGovernance.convertToPublicVault();
        _plasmaVaultGovernance.enableTransferShares();
        vm.stopPrank();

        // Provide initial liquidity to user
        deal(_UNDERLYING_TOKEN, _USER, 1_000_000e6);

        deal(_WETH, _USER, 100e18);
        vm.startPrank(_USER);
        IERC20(_WETH).transfer(address(_plasmaVault), 100e18);
        vm.stopPrank();

        vm.startPrank(_USER);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 1_000_000e6);
        _plasmaVault.deposit(1_000_000e6, _USER);
        vm.stopPrank();

        _aerodromeBalanceFuse = new AerodromeBalanceFuse(IporFusionMarkets.AERODROME);
        _aerodromeClaimFeesFuse = new AerodromeClaimFeesFuse(IporFusionMarkets.AERODROME);
        _aerodromeLiquidityFuse = new AerodromeLiquidityFuse(IporFusionMarkets.AERODROME, _AERODROME_ROUTER);
        _aerodromeGaugeFuse = new AerodromeGaugeFuse(IporFusionMarkets.AERODROME);

        address[] memory fuses = new address[](3);
        fuses[0] = address(_aerodromeClaimFeesFuse);
        fuses[1] = address(_aerodromeLiquidityFuse);
        fuses[2] = address(_aerodromeGaugeFuse);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = address(_aerodromeGaugeClaimFuse);

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.addBalanceFuse(IporFusionMarkets.AERODROME, address(_aerodromeBalanceFuse));
        _plasmaVaultGovernance.addBalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
        _plasmaVaultGovernance.addFuses(fuses);
        vm.stopPrank();

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(_UNDERLYING_TOKEN);

        bytes32[] memory aerodromeSubstrates = new bytes32[](2);

        aerodromeSubstrates[0] = AerodromeSubstrateLib.substrateToBytes32(
            AerodromeSubstrate({
                substrateAddress: IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0)),
                substrateType: AerodromeSubstrateType.Pool
            })
        );
        aerodromeSubstrates[1] = AerodromeSubstrateLib.substrateToBytes32(
            AerodromeSubstrate({substrateAddress: _AERODROME_GAUGE, substrateType: AerodromeSubstrateType.Gauge})
        );

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.AERODROME, aerodromeSubstrates);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AERODROME;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
        vm.stopPrank();
    }

    function test_shouldAddLiquidityToAerodromePool() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Create AerodromeLiquidityFuseEnterData
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        // Create FuseAction for adding liquidity
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Verify balances changed correctly
        uint256 finalUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 finalWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // USDC and WETH balances should have decreased
        assertLt(finalUsdcBalance, initialUsdcBalance, "USDC balance should have decreased");
        assertLt(finalWethBalance, initialWethBalance, "WETH balance should have decreased");

        // Aerodrome market balance should have increased
        assertGt(finalAerodromeBalance, initialAerodromeBalance, "Aerodrome market balance should have increased");
    }

    function test_shouldRevertWhenPoolNotGranted() public {
        // given - Use volatile pool which is not granted in setUp (only stable pool is granted)
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 1e18;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0.99e18;
        uint256 deadline = block.timestamp + 3600;

        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: false, // Use volatile pool which is not granted
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, false, address(0));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                AerodromeLiquidityFuse.AerodromeLiquidityFuseUnsupportedPool.selector,
                "enter",
                poolAddress
            )
        );
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenLiquidityEnterWithZeroTokenA() public {
        // given - Use zero address as tokenA
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: address(0),
            tokenB: _WETH,
            stable: true,
            amountADesired: 1000e6,
            amountBDesired: 1e18,
            amountAMin: 990e6,
            amountBMin: 0.99e18,
            deadline: block.timestamp + 3600
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(AerodromeLiquidityFuse.AerodromeLiquidityFuseInvalidToken.selector);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenLiquidityEnterWithZeroTokenB() public {
        // given - Use zero address as tokenB
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: address(0),
            stable: true,
            amountADesired: 1000e6,
            amountBDesired: 1e18,
            amountAMin: 990e6,
            amountBMin: 0.99e18,
            deadline: block.timestamp + 3600
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(AerodromeLiquidityFuse.AerodromeLiquidityFuseInvalidToken.selector);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenLiquidityExitWithZeroTokenA() public {
        // given - Use zero address as tokenA
        AerodromeLiquidityFuseExitData memory exitData = AerodromeLiquidityFuseExitData({
            tokenA: address(0),
            tokenB: _WETH,
            stable: true,
            liquidity: 1000e18,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp + 3600
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("exit((address,address,bool,uint256,uint256,uint256,uint256))", exitData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(AerodromeLiquidityFuse.AerodromeLiquidityFuseInvalidToken.selector);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenLiquidityExitWithZeroTokenB() public {
        // given - Use zero address as tokenB
        AerodromeLiquidityFuseExitData memory exitData = AerodromeLiquidityFuseExitData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: address(0),
            stable: true,
            liquidity: 1000e18,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp + 3600
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("exit((address,address,bool,uint256,uint256,uint256,uint256))", exitData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(AerodromeLiquidityFuse.AerodromeLiquidityFuseInvalidToken.selector);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenLiquidityExitWithPoolNotGranted() public {
        // given - First add liquidity to stable pool
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 172503737333611236;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Now try to exit from volatile pool which is not granted
        AerodromeLiquidityFuseExitData memory exitData = AerodromeLiquidityFuseExitData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: false, // Use volatile pool which is not granted
            liquidity: lpTokenBalance,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp + 3600
        });

        address volatilePoolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, false, address(0));

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("exit((address,address,bool,uint256,uint256,uint256,uint256))", exitData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                AerodromeLiquidityFuse.AerodromeLiquidityFuseUnsupportedPool.selector,
                "exit",
                volatilePoolAddress
            )
        );
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldAddLiquidityTwiceToAerodromePool() public {
        // given
        uint256 amountADesired1 = 1000e6; // 1000 USDC
        uint256 amountBDesired1 = 172503737333611236; // 1 WETH
        uint256 amountAMin1 = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin1 = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        uint256 amountADesired2 = 500e6; // 500 USDC
        uint256 amountBDesired2 = 86251868666805618; // 0.5 WETH
        uint256 amountAMin2 = 495e6; // 495 USDC (1% slippage)
        uint256 amountBMin2 = 0; // 0.495 WETH (1% slippage)

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First liquidity addition
        AerodromeLiquidityFuseEnterData memory enterData1 = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired1,
            amountBDesired: amountBDesired1,
            amountAMin: amountAMin1,
            amountBMin: amountBMin1,
            deadline: deadline
        });

        FuseAction[] memory actions1 = new FuseAction[](1);
        actions1[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData1)
        );

        // Execute first liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions1);
        vm.stopPrank();

        // Record balances after first addition
        uint256 afterFirstUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 afterFirstWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 afterFirstAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Second liquidity addition
        enterData1 = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired2,
            amountBDesired: amountBDesired2,
            amountAMin: amountAMin2,
            amountBMin: amountBMin2,
            deadline: deadline
        });

        actions1[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData1)
        );

        // Execute second liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions1);
        vm.stopPrank();

        // then
        // Verify final balances
        uint256 finalUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 finalWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // USDC and WETH balances should have decreased from initial
        assertLt(finalUsdcBalance, initialUsdcBalance, "Final USDC balance should be less than initial");
        assertLt(finalWethBalance, initialWethBalance, "Final WETH balance should be less than initial");

        // Second addition should have decreased balances further
        assertLt(finalUsdcBalance, afterFirstUsdcBalance, "Second addition should decrease USDC balance further");
        assertLt(finalWethBalance, afterFirstWethBalance, "Second addition should decrease WETH balance further");

        // Aerodrome market balance should have increased from initial
        assertGt(
            finalAerodromeBalance,
            initialAerodromeBalance,
            "Final Aerodrome market balance should be greater than initial"
        );

        // Second addition should have increased Aerodrome balance further
        assertGt(
            finalAerodromeBalance,
            afterFirstAerodromeBalance,
            "Second addition should increase Aerodrome balance further"
        );
    }

    function test_shouldRemoveAllLiquidityFromAerodromePool() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First, add liquidity
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after adding liquidity
        uint256 afterAddUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 afterAddWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 afterAddAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Now remove all liquidity
        AerodromeLiquidityFuseExitData memory exitData = AerodromeLiquidityFuseExitData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            liquidity: 2780286892198, // read form event after add liquidity
            amountAMin: 0, // Accept any amount back
            amountBMin: 0, // Accept any amount back
            deadline: deadline
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("exit((address,address,bool,uint256,uint256,uint256,uint256))", exitData)
        );

        // Execute liquidity removal
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then

        // Verify final balances
        uint256 finalUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 finalWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // USDC and WETH balances should have increased after removal
        assertGt(
            finalUsdcBalance,
            afterAddUsdcBalance,
            "Final USDC balance should be greater than after adding liquidity"
        );
        assertGt(
            finalWethBalance,
            afterAddWethBalance,
            "Final WETH balance should be greater than after adding liquidity"
        );

        // Aerodrome market balance should have decreased after removal
        assertLt(
            finalAerodromeBalance,
            afterAddAerodromeBalance,
            "Final Aerodrome market balance should be less than after adding liquidity"
        );

        // Final balances should be approximately equal to initial balances (within slippage)
        assertApproxEqAbs(
            finalUsdcBalance,
            initialUsdcBalance,
            ERROR_DELTA,
            "Final USDC balance should be approximately equal to initial"
        );
        assertApproxEqAbs(
            finalWethBalance,
            initialWethBalance,
            ERROR_DELTA,
            "Final WETH balance should be approximately equal to initial"
        );
        assertApproxEqAbs(
            finalAerodromeBalance,
            initialAerodromeBalance,
            ERROR_DELTA,
            "Final Aerodrome balance should be approximately equal to initial"
        );
    }

    function test_shouldClaimFeesAfterAddingLiquidity() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Get pool address for USDC/WETH stable pool
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));

        // First, add liquidity
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Now claim fees
        address[] memory pools = new address[](1);
        pools[0] = poolAddress;

        AerodromeClaimFeesFuseEnterData memory claimFeesData = AerodromeClaimFeesFuseEnterData({pools: pools});

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeClaimFeesFuse),
            abi.encodeWithSignature("enter((address[]))", claimFeesData)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenClaimFeesWithPoolNotGranted() public {
        // given - Use a pool address that is not granted (use a different pool or random address)
        // We'll use a different pool that exists but is not granted in setUp
        // Using a volatile pool instead of stable pool
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, false, address(0));

        address[] memory pools = new address[](1);
        pools[0] = poolAddress;

        AerodromeClaimFeesFuseEnterData memory claimFeesData = AerodromeClaimFeesFuseEnterData({pools: pools});

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeClaimFeesFuse),
            abi.encodeWithSignature("enter((address[]))", claimFeesData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                AerodromeClaimFeesFuse.AerodromeClaimFeesFuseUnsupportedPool.selector,
                "enter",
                poolAddress
            )
        );
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldDepositLiquidityToAerodromeGauge() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First, add liquidity to get LP tokens
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Now deposit LP tokens to gauge
        uint256 gaugeDepositAmount = lpTokenBalance / 2; // Deposit half of LP tokens
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: gaugeDepositAmount
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then
        // Verify LP token balance decreased
        uint256 finalLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        assertLt(finalLpTokenBalance, lpTokenBalance, "LP token balance should have decreased");

        // Verify gauge balance increased
        uint256 gaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertEq(gaugeBalance, gaugeDepositAmount, "Gauge balance should equal deposited amount");

        // Aerodrome market balance should remain the same (LP tokens are still in the market)
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);
        assertApproxEqAbs(
            finalAerodromeBalance,
            afterLiquidityAerodromeBalance,
            ERROR_DELTA,
            "Aerodrome market balance should remain approximately the same"
        );
    }

    function test_shouldRevertWhenGaugeNotGranted() public {
        // given - Don't grant the gauge substrate
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 172503737333611236;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        // First, add liquidity to get LP tokens
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Try to deposit to an unsupported gauge
        address unsupportedGauge = address(0x1234567890123456789012345678901234567890);
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: unsupportedGauge,
            amount: lpTokenBalance / 2
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(); // Should revert with AerodromeGaugeFuseUnsupportedGauge error
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldDepositAllLiquidityToAerodromeGauge() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First, add liquidity to get LP tokens
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Now deposit all LP tokens to gauge
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: lpTokenBalance
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then
        // Verify LP token balance is zero
        uint256 finalLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        assertEq(finalLpTokenBalance, 0, "LP token balance should be zero");

        // Verify gauge balance equals the full LP token amount
        uint256 gaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertEq(gaugeBalance, lpTokenBalance, "Gauge balance should equal full LP token amount");

        // Aerodrome market balance should remain the same (LP tokens are still in the market via gauge)
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);
        assertApproxEqAbs(
            finalAerodromeBalance,
            afterLiquidityAerodromeBalance,
            ERROR_DELTA,
            "Aerodrome market balance should remain approximately the same"
        );
    }

    function test_shouldDepositLiquidityToGaugeTwice() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First, add liquidity to get LP tokens
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First gauge deposit - half of LP tokens
        uint256 firstDepositAmount = lpTokenBalance / 2;
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: firstDepositAmount
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // Execute first gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after first deposit
        uint256 afterFirstLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterFirstGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));

        // Second gauge deposit - remaining LP tokens
        uint256 secondDepositAmount = afterFirstLpTokenBalance;
        gaugeEnterData = AerodromeGaugeFuseEnterData({gaugeAddress: _AERODROME_GAUGE, amount: secondDepositAmount});

        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // Execute second gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then
        // Verify final balances
        uint256 finalLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 finalGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));

        // LP token balance should be zero after second deposit
        assertEq(finalLpTokenBalance, 0, "Final LP token balance should be zero");

        // Gauge balance should equal the full LP token amount
        assertEq(finalGaugeBalance, lpTokenBalance, "Final gauge balance should equal full LP token amount");

        // Second deposit should have increased gauge balance further
        assertGt(finalGaugeBalance, afterFirstGaugeBalance, "Second deposit should increase gauge balance further");

        // Aerodrome market balance should remain the same
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);
        assertApproxEqAbs(
            finalAerodromeBalance,
            afterLiquidityAerodromeBalance,
            ERROR_DELTA,
            "Aerodrome market balance should remain approximately the same"
        );
    }

    function test_shouldWithdrawLiquidityFromAerodromeGauge() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First, add liquidity to get LP tokens
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Deposit all LP tokens to gauge
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: lpTokenBalance
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after gauge deposit
        uint256 afterGaugeDepositLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Now withdraw half of the LP tokens from gauge
        uint256 withdrawAmount = lpTokenBalance / 2;
        AerodromeGaugeFuseExitData memory gaugeExitData = AerodromeGaugeFuseExitData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: withdrawAmount
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then
        // Verify LP token balance increased
        uint256 finalLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        assertGt(finalLpTokenBalance, afterGaugeDepositLpTokenBalance, "LP token balance should have increased");

        // Verify gauge balance decreased
        uint256 finalGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertLt(finalGaugeBalance, afterGaugeDepositGaugeBalance, "Gauge balance should have decreased");

        // Verify the withdrawn amount matches
        assertEq(finalGaugeBalance, lpTokenBalance - withdrawAmount, "Gauge balance should equal remaining amount");

        // Aerodrome market balance should remain the same (LP tokens are still in the market)
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);
        assertApproxEqAbs(
            finalAerodromeBalance,
            afterGaugeDepositAerodromeBalance,
            ERROR_DELTA,
            "Aerodrome market balance should remain approximately the same"
        );
    }

    function test_shouldWithdrawAllLiquidityFromAerodromeGauge() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First, add liquidity to get LP tokens
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Deposit all LP tokens to gauge
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: lpTokenBalance
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after gauge deposit
        uint256 afterGaugeDepositLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Now withdraw all LP tokens from gauge
        AerodromeGaugeFuseExitData memory gaugeExitData = AerodromeGaugeFuseExitData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: lpTokenBalance
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then
        // Verify LP token balance is restored to original amount
        uint256 finalLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        assertEq(finalLpTokenBalance, lpTokenBalance, "LP token balance should be restored to original amount");

        // Verify gauge balance is zero
        uint256 finalGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertEq(finalGaugeBalance, 0, "Gauge balance should be zero");

        // Aerodrome market balance should remain the same
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);
        assertApproxEqAbs(
            finalAerodromeBalance,
            afterGaugeDepositAerodromeBalance,
            ERROR_DELTA,
            "Aerodrome market balance should remain approximately the same"
        );
    }

    function test_shouldWithdrawLiquidityFromGaugeTwice() public {
        // given
        uint256 amountADesired = 1000e6; // 1000 USDC
        uint256 amountBDesired = 172503737333611236; // 1 WETH
        uint256 amountAMin = 990e6; // 990 USDC (1% slippage)
        uint256 amountBMin = 0; // 0.99 WETH (1% slippage)
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First, add liquidity to get LP tokens
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // Deposit all LP tokens to gauge
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: lpTokenBalance
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after gauge deposit
        uint256 afterGaugeDepositLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);

        // First withdrawal - half of LP tokens
        uint256 firstWithdrawAmount = lpTokenBalance / 2;
        AerodromeGaugeFuseExitData memory gaugeExitData = AerodromeGaugeFuseExitData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: firstWithdrawAmount
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // Execute first withdrawal
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after first withdrawal
        uint256 afterFirstWithdrawLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterFirstWithdrawGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));

        // Second withdrawal - remaining LP tokens
        uint256 secondWithdrawAmount = lpTokenBalance - firstWithdrawAmount;
        gaugeExitData = AerodromeGaugeFuseExitData({gaugeAddress: _AERODROME_GAUGE, amount: secondWithdrawAmount});

        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // Execute second withdrawal
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then
        // Verify final balances
        uint256 finalLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 finalGaugeBalance = IGauge(_AERODROME_GAUGE).balanceOf(address(_plasmaVault));

        // LP token balance should be restored to original amount
        assertEq(finalLpTokenBalance, lpTokenBalance, "Final LP token balance should equal original amount");

        // Gauge balance should be zero
        assertEq(finalGaugeBalance, 0, "Final gauge balance should be zero");

        // Second withdrawal should have increased LP token balance further
        assertGt(
            finalLpTokenBalance,
            afterFirstWithdrawLpTokenBalance,
            "Second withdrawal should increase LP token balance further"
        );

        // Aerodrome market balance should remain the same
        uint256 finalAerodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AERODROME);
        assertApproxEqAbs(
            finalAerodromeBalance,
            afterGaugeDepositAerodromeBalance,
            ERROR_DELTA,
            "Aerodrome market balance should remain approximately the same"
        );
    }

    function test_shouldRevertWhenGaugeExitNotGranted() public {
        // given - Don't grant the gauge substrate
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 172503737333611236;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        // First, add liquidity to get LP tokens
        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get LP token balance
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Deposit LP tokens to gauge
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: lpTokenBalance
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Try to withdraw from an unsupported gauge
        address unsupportedGauge = address(0x1234567890123456789012345678901234567890);
        AerodromeGaugeFuseExitData memory gaugeExitData = AerodromeGaugeFuseExitData({
            gaugeAddress: unsupportedGauge,
            amount: lpTokenBalance / 2
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(); // Should revert with AerodromeGaugeFuseUnsupportedGauge error
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenGaugeEnterWithZeroAddress() public {
        // given - Use zero address as gauge
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: address(0),
            amount: 1000e18
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(AerodromeGaugeFuse.AerodromeGaugeFuseInvalidGauge.selector);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenGaugeExitWithZeroAddress() public {
        // given - Use zero address as gauge
        AerodromeGaugeFuseExitData memory gaugeExitData = AerodromeGaugeFuseExitData({
            gaugeAddress: address(0),
            amount: 1000e18
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(AerodromeGaugeFuse.AerodromeGaugeFuseInvalidGauge.selector);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldReturnWhenGaugeEnterWithZeroBalance() public {
        // given - Try to enter with amount but vault has no LP tokens (zero balance)
        // Use a gauge that is granted but vault has no staking tokens
        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: 1000e18 // Request amount but vault has 0 balance
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        // when - Should return early without error when balance is 0
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions); // Should not revert, just return early
        vm.stopPrank();
    }

    function test_shouldReturnWhenGaugeExitWithZeroBalance() public {
        // given - Try to exit from gauge but vault has no balance in gauge
        // First deposit some LP tokens to gauge
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 172503737333611236;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Now try to exit more than what's in the gauge (which is 0 since we didn't deposit to gauge)
        AerodromeGaugeFuseExitData memory gaugeExitData = AerodromeGaugeFuseExitData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: 1000e18 // Request amount but gauge balance is 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // when - Should return early without error when gauge balance is 0
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions); // Should not revert, just return early
        vm.stopPrank();
    }

    function test_shouldClaimRewardsFromGauge() public {
        //given
        test_shouldDepositAllLiquidityToAerodromeGauge();
        vm.warp(block.timestamp + 4 days);

        address[] memory gauges = new address[](1);
        gauges[0] = _AERODROME_GAUGE;

        FuseAction[] memory actions = new FuseAction[](1);

        _aerodromeGaugeClaimFuse = new AerodromeGaugeClaimFuse(IporFusionMarkets.AERODROME);

        actions[0] = FuseAction(address(_aerodromeGaugeClaimFuse), abi.encodeWithSignature("claim(address[])", gauges));

        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = address(_aerodromeGaugeClaimFuse);

        vm.startPrank(_FUSE_MANAGER);
        _rewardsClaimManager.addRewardFuses(rewardFuses);
        vm.stopPrank();

        uint256 balanceBefore = IERC20(_AERODROME_REWARD_TOKEN).balanceOf(address(_rewardsClaimManager));

        //when
        vm.startPrank(_ALPHA);
        _rewardsClaimManager.claimRewards(actions);
        vm.stopPrank();

        //then
        uint256 balanceAfter = IERC20(_AERODROME_REWARD_TOKEN).balanceOf(address(_rewardsClaimManager));
        assertEq(balanceBefore, 0, "Balance should be 0");
        assertGt(balanceAfter, 0, "Balance should be greater than 0");
    }

    // ============ Tests for substrateToBytes32 and bytes32ToSubstrate functions ============

    function test_shouldConvertGaugeSubstrateToBytes32AndBack() public {
        // given
        address gaugeAddress = _AERODROME_GAUGE;
        AerodromeSubstrate memory originalSubstrate = AerodromeSubstrate({
            substrateType: AerodromeSubstrateType.Gauge,
            substrateAddress: gaugeAddress
        });

        // when
        bytes32 encodedSubstrate = AerodromeSubstrateLib.substrateToBytes32(originalSubstrate);
        AerodromeSubstrate memory decodedSubstrate = AerodromeSubstrateLib.bytes32ToSubstrate(encodedSubstrate);

        // then
        assertEq(
            uint256(decodedSubstrate.substrateType),
            uint256(originalSubstrate.substrateType),
            "Substrate type should match"
        );
        assertEq(
            decodedSubstrate.substrateAddress,
            originalSubstrate.substrateAddress,
            "Substrate address should match"
        );
    }

    function test_shouldConvertPoolSubstrateToBytes32AndBack() public {
        // given
        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        AerodromeSubstrate memory originalSubstrate = AerodromeSubstrate({
            substrateType: AerodromeSubstrateType.Pool,
            substrateAddress: poolAddress
        });

        // when
        bytes32 encodedSubstrate = AerodromeSubstrateLib.substrateToBytes32(originalSubstrate);
        AerodromeSubstrate memory decodedSubstrate = AerodromeSubstrateLib.bytes32ToSubstrate(encodedSubstrate);

        // then
        assertEq(
            uint256(decodedSubstrate.substrateType),
            uint256(originalSubstrate.substrateType),
            "Substrate type should match"
        );
        assertEq(
            decodedSubstrate.substrateAddress,
            originalSubstrate.substrateAddress,
            "Substrate address should match"
        );
    }

    function test_shouldConvertUndefinedSubstrateToBytes32AndBack() public {
        // given
        address someAddress = address(0x1234567890123456789012345678901234567890);
        AerodromeSubstrate memory originalSubstrate = AerodromeSubstrate({
            substrateType: AerodromeSubstrateType.UNDEFINED,
            substrateAddress: someAddress
        });

        // when
        bytes32 encodedSubstrate = AerodromeSubstrateLib.substrateToBytes32(originalSubstrate);
        AerodromeSubstrate memory decodedSubstrate = AerodromeSubstrateLib.bytes32ToSubstrate(encodedSubstrate);

        // then
        assertEq(
            uint256(decodedSubstrate.substrateType),
            uint256(originalSubstrate.substrateType),
            "Substrate type should match"
        );
        assertEq(
            decodedSubstrate.substrateAddress,
            originalSubstrate.substrateAddress,
            "Substrate address should match"
        );
    }

    function test_shouldConvertZeroAddressSubstrateToBytes32AndBack() public {
        // given
        address zeroAddress = address(0);
        AerodromeSubstrate memory originalSubstrate = AerodromeSubstrate({
            substrateType: AerodromeSubstrateType.Gauge,
            substrateAddress: zeroAddress
        });

        // when
        bytes32 encodedSubstrate = AerodromeSubstrateLib.substrateToBytes32(originalSubstrate);
        AerodromeSubstrate memory decodedSubstrate = AerodromeSubstrateLib.bytes32ToSubstrate(encodedSubstrate);

        // then
        assertEq(
            uint256(decodedSubstrate.substrateType),
            uint256(originalSubstrate.substrateType),
            "Substrate type should match"
        );
        assertEq(
            decodedSubstrate.substrateAddress,
            originalSubstrate.substrateAddress,
            "Substrate address should match"
        );
    }

    function test_shouldConvertMaxAddressSubstrateToBytes32AndBack() public {
        // given
        address maxAddress = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        AerodromeSubstrate memory originalSubstrate = AerodromeSubstrate({
            substrateType: AerodromeSubstrateType.Pool,
            substrateAddress: maxAddress
        });

        // when
        bytes32 encodedSubstrate = AerodromeSubstrateLib.substrateToBytes32(originalSubstrate);
        AerodromeSubstrate memory decodedSubstrate = AerodromeSubstrateLib.bytes32ToSubstrate(encodedSubstrate);

        // then
        assertEq(
            uint256(decodedSubstrate.substrateType),
            uint256(originalSubstrate.substrateType),
            "Substrate type should match"
        );
        assertEq(
            decodedSubstrate.substrateAddress,
            originalSubstrate.substrateAddress,
            "Substrate address should match"
        );
    }

    function test_shouldVerifyBytes32EncodingStructure() public {
        // given
        address testAddress = address(0x1234567890123456789012345678901234567890);
        AerodromeSubstrateType testType = AerodromeSubstrateType.Gauge;
        AerodromeSubstrate memory originalSubstrate = AerodromeSubstrate({
            substrateType: testType,
            substrateAddress: testAddress
        });

        // when
        bytes32 encodedSubstrate = AerodromeSubstrateLib.substrateToBytes32(originalSubstrate);

        // then
        // Verify the lower 160 bits contain the address
        address extractedAddress = address(uint160(uint256(encodedSubstrate)));
        assertEq(extractedAddress, testAddress, "Address should be in lower 160 bits");

        // Verify the upper bits contain the type
        uint256 extractedType = uint256(encodedSubstrate) >> 160;
        assertEq(extractedType, uint256(testType), "Type should be in upper bits");
    }

    function test_shouldVerifyBytes32DecodingStructure() public {
        // given
        address testAddress = makeAddr("testAddress");
        AerodromeSubstrateType testType = AerodromeSubstrateType.Pool;
        uint256 encodedValue = uint256(uint160(testAddress)) | (uint256(testType) << 160);
        bytes32 encodedSubstrate = bytes32(encodedValue);

        // when
        AerodromeSubstrate memory decodedSubstrate = AerodromeSubstrateLib.bytes32ToSubstrate(encodedSubstrate);

        // then
        assertEq(uint256(decodedSubstrate.substrateType), uint256(testType), "Decoded type should match");
        assertEq(decodedSubstrate.substrateAddress, testAddress, "Decoded address should match");
    }

    function test_shouldHandleAllSubstrateTypes() public {
        // given
        address testAddress = address(0x1111111111111111111111111111111111111111);
        AerodromeSubstrateType[] memory types = new AerodromeSubstrateType[](3);
        types[0] = AerodromeSubstrateType.UNDEFINED;
        types[1] = AerodromeSubstrateType.Gauge;
        types[2] = AerodromeSubstrateType.Pool;

        for (uint256 i = 0; i < types.length; i++) {
            AerodromeSubstrate memory originalSubstrate = AerodromeSubstrate({
                substrateType: types[i],
                substrateAddress: testAddress
            });

            // when
            bytes32 encodedSubstrate = AerodromeSubstrateLib.substrateToBytes32(originalSubstrate);
            AerodromeSubstrate memory decodedSubstrate = AerodromeSubstrateLib.bytes32ToSubstrate(encodedSubstrate);

            // then
            assertEq(
                uint256(decodedSubstrate.substrateType),
                uint256(originalSubstrate.substrateType),
                "Substrate type should match for all types"
            );
            assertEq(
                decodedSubstrate.substrateAddress,
                originalSubstrate.substrateAddress,
                "Substrate address should match for all types"
            );
        }
    }

    function test_shouldRoundTripMultipleAddresses() public {
        // given
        address[] memory testAddresses = new address[](5);
        testAddresses[0] = address(0x1000000000000000000000000000000000000000);
        testAddresses[1] = address(0x2000000000000000000000000000000000000000);
        testAddresses[2] = address(0x3000000000000000000000000000000000000000);
        testAddresses[3] = address(0x4000000000000000000000000000000000000000);
        testAddresses[4] = address(0x5000000000000000000000000000000000000000);

        for (uint256 i = 0; i < testAddresses.length; i++) {
            AerodromeSubstrate memory originalSubstrate = AerodromeSubstrate({
                substrateType: AerodromeSubstrateType.Gauge,
                substrateAddress: testAddresses[i]
            });

            // when
            bytes32 encodedSubstrate = AerodromeSubstrateLib.substrateToBytes32(originalSubstrate);
            AerodromeSubstrate memory decodedSubstrate = AerodromeSubstrateLib.bytes32ToSubstrate(encodedSubstrate);

            // then
            assertEq(
                uint256(decodedSubstrate.substrateType),
                uint256(originalSubstrate.substrateType),
                "Substrate type should match for all addresses"
            );
            assertEq(
                decodedSubstrate.substrateAddress,
                originalSubstrate.substrateAddress,
                "Substrate address should match for all addresses"
            );
        }
    }

    // ============ Tests for AerodromeBalanceFuse ============

    function test_shouldReturnZeroWhenBalanceOfWithNoSubstrates() public {
        // given - Remove all substrates
        vm.startPrank(_FUSE_MANAGER);
        bytes32[] memory emptySubstrates = new bytes32[](0);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.AERODROME, emptySubstrates);
        vm.stopPrank();

        // when - Call balanceOf through UniversalReader in vault context
        ReadResult memory readResult = UniversalReader(address(_plasmaVault)).read(
            address(_aerodromeBalanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );
        uint256 balance = abi.decode(readResult.data, (uint256));

        // then
        assertEq(balance, 0, "Balance should be 0 when no substrates");
    }

    function test_shouldContinueWhenBalanceOfWithUndefinedSubstrateType() public {
        // given - Add an UNDEFINED substrate type
        bytes32[] memory substrates = new bytes32[](1);
        // Create a substrate with UNDEFINED type (value 0)
        substrates[0] = AerodromeSubstrateLib.substrateToBytes32(
            AerodromeSubstrate({substrateAddress: address(0x123), substrateType: AerodromeSubstrateType.UNDEFINED})
        );

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.AERODROME, substrates);
        vm.stopPrank();

        // when - Call balanceOf through UniversalReader in vault context
        ReadResult memory readResult = UniversalReader(address(_plasmaVault)).read(
            address(_aerodromeBalanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );
        uint256 balance = abi.decode(readResult.data, (uint256));

        // then - should return 0 without reverting (continue skips undefined substrates)
        assertEq(balance, 0, "Balance should be 0 when only undefined substrate");
    }

    function test_shouldCalculateBalanceWithClaimableFees() public {
        // given - Add liquidity to pool first
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 172503737333611236;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Wait some time to accumulate fees
        vm.warp(block.timestamp + 1 days);

        // when - Calculate balance through UniversalReader (this should include claimable fees)
        ReadResult memory readResult = UniversalReader(address(_plasmaVault)).read(
            address(_aerodromeBalanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );
        uint256 balance = abi.decode(readResult.data, (uint256));

        // then - Balance should be greater than 0
        assertGt(balance, 0, "Balance should be greater than 0 when liquidity exists");
    }

    function test_shouldCalculateBalanceWithGaugeSubstrate() public {
        // given - Add liquidity and deposit to gauge
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 172503737333611236;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        AerodromeLiquidityFuseEnterData memory enterData = AerodromeLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _WETH,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        address poolAddress = IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0));
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        AerodromeGaugeFuseEnterData memory gaugeEnterData = AerodromeGaugeFuseEnterData({
            gaugeAddress: _AERODROME_GAUGE,
            amount: lpTokenBalance
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_aerodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // when - Calculate balance through UniversalReader (this should include gauge balance)
        ReadResult memory readResult = UniversalReader(address(_plasmaVault)).read(
            address(_aerodromeBalanceFuse),
            abi.encodeWithSignature("balanceOf()")
        );
        uint256 balance = abi.decode(readResult.data, (uint256));

        // then - Balance should be greater than 0
        assertGt(balance, 0, "Balance should be greater than 0 when gauge has liquidity");
    }
}
