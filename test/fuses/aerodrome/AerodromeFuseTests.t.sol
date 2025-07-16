// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
import {AerodromeClaimFeesFuse, AerodromeClaimFeesFuseEnterData} from "../../../contracts/fuses/aerodrome/AerodromeClaimFeesFuse.sol";
import {AerodromeLiquidityFuse, AerodromeLiquidityFuseEnterData, AerodromeLiquidityFuseExitData} from "../../../contracts/fuses/aerodrome/AerodromeLiquidityFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IRouter} from "../../../contracts/fuses/aerodrome/ext/IRouter.sol";

import {IWETH9} from "../erc4626/IWETH9.sol";

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

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    PriceOracleMiddleware private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    AerodromeBalanceFuse private _aerodromeBalanceFuse;
    AerodromeClaimFeesFuse private _aerodromeClaimFeesFuse;
    AerodromeLiquidityFuse private _aerodromeLiquidityFuse;

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

        vm.startPrank(_ATOMIST);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, _ATOMIST, 0);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, _FUSE_MANAGER, 0);
        _accessManager.grantRole(Roles.ALPHA_ROLE, _ALPHA, 0);
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

        address[] memory fuses = new address[](2);
        fuses[0] = address(_aerodromeClaimFeesFuse);
        fuses[1] = address(_aerodromeLiquidityFuse);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.addBalanceFuse(IporFusionMarkets.AERODROME, address(_aerodromeBalanceFuse));
        _plasmaVaultGovernance.addBalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
        _plasmaVaultGovernance.addFuses(fuses);
        vm.stopPrank();

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(_UNDERLYING_TOKEN);

        bytes32[] memory aerodromeSubstrates = new bytes32[](1);
        aerodromeSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(
            IRouter(_AERODROME_ROUTER).poolFor(_UNDERLYING_TOKEN, _WETH, true, address(0))
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
        // given - Don't grant the pool substrate
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 1e18;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0.99e18;
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

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(); // Should revert with AerodromeLiquidityFuseUnsupportedPool error
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
}
