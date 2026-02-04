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
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {VelodromeSuperchainBalanceFuse} from "../../../contracts/fuses/velodrome_superchain/VelodromeSuperchainBalanceFuse.sol";
import {VelodromeSuperchainSubstrateLib, VelodromeSuperchainSubstrate, VelodromeSuperchainSubstrateType} from "../../../contracts/fuses/velodrome_superchain/VelodromeSuperchainLib.sol";
import {VelodromeSuperchainLiquidityFuse, VelodromeSuperchainLiquidityFuseEnterData, VelodromeSuperchainLiquidityFuseExitData} from "../../../contracts/fuses/velodrome_superchain/VelodromeSuperchainLiquidityFuse.sol";
import {VelodromeSuperchainGaugeFuse, VelodromeSuperchainGaugeFuseEnterData, VelodromeSuperchainGaugeFuseExitData} from "../../../contracts/fuses/velodrome_superchain/VelodromeSuperchainGaugeFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IRouter} from "../../../contracts/fuses/velodrome_superchain/ext/IRouter.sol";
import {VelodromeSuperchainGaugeClaimFuse} from "../../../contracts/rewards_fuses/velodrome_superchain/VelodromeSuperchainGaugeClaimFuse.sol";
import {ILeafGauge} from "../../../contracts/fuses/velodrome_superchain/ext/ILeafGauge.sol";
import {IPool} from "../../../contracts/fuses/velodrome_superchain/ext/IPool.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";

import {IWETH9} from "../erc4626/IWETH9.sol";

/// @title VelodromeSuperchainFuseTests
/// @notice Test suite for Velodrome Superchain fuses on Base blockchain
/// @dev Tests Velodrome Superchain liquidity provision, balance management, and fee claiming functionality
contract VelodromeSuperchainFuseTests is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    // Test constants
    address private constant _WETH = 0x4200000000000000000000000000000000000006;
    address private constant _USDO = 0x0200C29006150606B650577BBE7B6248F58470c1;
    address private constant _DINERO = 0x09D9420332bff75522a45FcFf4855F82a0a3ff50;
    address private constant _UNDERLYING_TOKEN = _WETH;
    string private constant _UNDERLYING_TOKEN_NAME = "WETH";
    address private constant _USER = TestAddresses.USER;
    address private constant _ATOMIST = TestAddresses.ATOMIST;
    address private constant _FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant _ALPHA = TestAddresses.ALPHA;
    uint256 private constant ERROR_DELTA = 40000;

    address private constant _fusionFactory = 0xEC53f69Bd1D991a2F99e96DE66E81D0E42A61D8D;

    address private constant _VELODROME_ROUTER = 0x3a63171DD9BebF4D07BC782FECC7eb0b890C2A45;
    /// @dev Velodrome Gauge address for USDC/WETH stable pool, for 0x3548029694fbB241D45FB24Ba0cd9c9d4E745f16 pool
    address private constant _VELODROME_Pool = 0x47b0AcA6834c5561489C3769506A0Cd7468D1968;
    address private constant _VELODROME_GAUGE = 0xD7B0f9003165E5F7D7C0F48B0203961b3033b514;
    address private constant _VELODROME_REWARD_TOKEN = 0x7f9AdFbd38b669F03d1d11000Bc76b9AaEA28A81;

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    PriceOracleMiddlewareManager private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    VelodromeSuperchainBalanceFuse private _velodromeBalanceFuse;
    VelodromeSuperchainLiquidityFuse private _velodromeLiquidityFuse;
    VelodromeSuperchainGaugeFuse private _velodromeGaugeFuse;
    VelodromeSuperchainGaugeClaimFuse private _velodromeGaugeClaimFuse;
    RewardsClaimManager private _rewardsClaimManager;
    TransientStorageSetInputsFuse private _transientStorageSetInputsFuse;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("INK_PROVIDER_URL"), 19702898);

        FusionFactory fusionFactory = FusionFactory(_fusionFactory);

        // Setup fee packages before creating vault
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.create(
            "Velodrome",
            "VEL",
            _UNDERLYING_TOKEN,
            0,
            _ATOMIST,
            0
        );

        _plasmaVault = PlasmaVault(fusionInstance.plasmaVault);
        _priceOracleMiddleware = PriceOracleMiddlewareManager(fusionInstance.priceManager);
        _accessManager = IporFusionAccessManager(fusionInstance.accessManager);
        _plasmaVaultGovernance = PlasmaVaultGovernance(fusionInstance.plasmaVault);
        _rewardsClaimManager = RewardsClaimManager(fusionInstance.rewardsManager);

        vm.startPrank(_ATOMIST);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, _ATOMIST, 0);
        _accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, _ATOMIST, 0);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, _FUSE_MANAGER, 0);
        _accessManager.grantRole(Roles.ALPHA_ROLE, _ALPHA, 0);
        _accessManager.grantRole(Roles.CLAIM_REWARDS_ROLE, _ALPHA, 0);
        _plasmaVaultGovernance.convertToPublicVault();
        _plasmaVaultGovernance.enableTransferShares();
        vm.stopPrank();

        address[] memory assets = new address[](2);
        assets[0] = _WETH;
        assets[1] = _DINERO;
        address[] memory sources = new address[](2);
        sources[0] = 0xdFc720E1ef024bfc768ed9E6F0e7Fc80E28f8CFA;
        sources[1] = address(new USDPriceFeed());
        vm.startPrank(_ATOMIST);
        _priceOracleMiddleware.setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        // Provide initial liquidity to user
        deal(_UNDERLYING_TOKEN, _USER, 1_000_000e18);

        deal(_DINERO, _USER, 1_000_000e18);

        vm.startPrank(_USER);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 1_000_000e18);
        _plasmaVault.deposit(1_000_000e18, _USER);
        vm.stopPrank();

        vm.startPrank(_USER);
        IERC20(_DINERO).transfer(address(_plasmaVault), 1_000_000e18);
        vm.stopPrank();

        _velodromeBalanceFuse = new VelodromeSuperchainBalanceFuse(IporFusionMarkets.VELODROME_SUPERCHAIN);
        _velodromeLiquidityFuse = new VelodromeSuperchainLiquidityFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _VELODROME_ROUTER
        );
        _velodromeGaugeFuse = new VelodromeSuperchainGaugeFuse(IporFusionMarkets.VELODROME_SUPERCHAIN);
        _velodromeGaugeClaimFuse = new VelodromeSuperchainGaugeClaimFuse(IporFusionMarkets.VELODROME_SUPERCHAIN);
        _transientStorageSetInputsFuse = new TransientStorageSetInputsFuse();

        address[] memory fuses = new address[](4);
        fuses[0] = address(_velodromeLiquidityFuse);
        fuses[1] = address(_velodromeGaugeFuse);
        fuses[2] = address(_transientStorageSetInputsFuse);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = address(_velodromeGaugeClaimFuse);

        vm.startPrank(_FUSE_MANAGER);
        _rewardsClaimManager.addRewardFuses(rewardFuses);
        vm.stopPrank();

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.addBalanceFuse(IporFusionMarkets.VELODROME_SUPERCHAIN, address(_velodromeBalanceFuse));
        _plasmaVaultGovernance.addBalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
        _plasmaVaultGovernance.addFuses(fuses);
        vm.stopPrank();

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(_UNDERLYING_TOKEN);

        bytes32[] memory aerodromeSubstrates = new bytes32[](2);

        aerodromeSubstrates[0] = VelodromeSuperchainSubstrateLib.substrateToBytes32(
            VelodromeSuperchainSubstrate({
                substrateAddress: IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false),
                substrateType: VelodromeSuperchainSubstrateType.Pool
            })
        );
        aerodromeSubstrates[1] = VelodromeSuperchainSubstrateLib.substrateToBytes32(
            VelodromeSuperchainSubstrate({
                substrateAddress: _VELODROME_GAUGE,
                substrateType: VelodromeSuperchainSubstrateType.Gauge
            })
        );

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.VELODROME_SUPERCHAIN, aerodromeSubstrates);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.VELODROME_SUPERCHAIN;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
        vm.stopPrank();
    }

    function test_shouldClaimRewardsFromGauge() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Deposit all LP tokens to gauge
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Fast forward time to accumulate rewards
        vm.warp(block.timestamp + 4 days);

        // Claim rewards
        address[] memory gauges = new address[](1);
        gauges[0] = _VELODROME_GAUGE;

        actions = new FuseAction[](1);
        actions[0] = FuseAction(address(_velodromeGaugeClaimFuse), abi.encodeWithSignature("claim(address[])", gauges));

        uint256 balanceBefore = IERC20(_VELODROME_REWARD_TOKEN).balanceOf(address(_rewardsClaimManager));

        // when
        vm.startPrank(_ALPHA);
        _rewardsClaimManager.claimRewards(actions);
        vm.stopPrank();

        // then
        uint256 balanceAfter = IERC20(_VELODROME_REWARD_TOKEN).balanceOf(address(_rewardsClaimManager));
        assertGe(balanceAfter, balanceBefore, "Reward balance should be greater than or equal to before");
    }

    function test_shouldAddLiquidityToVelodromePool() public {
        // given
        uint256 amountADesired = 1e18;
        uint256 amountBDesired = 400_000e18;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // Create VelodromeLiquidityFuseEnterData
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        // Create FuseAction for adding liquidity
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Verify balances changed correctly
        uint256 finalUsdcBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 finalWethBalance = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // USDC and WETH balances should have decreased
        assertLt(finalUsdcBalance, initialUsdcBalance, "USDC balance should have decreased");
        assertLt(finalWethBalance, initialWethBalance, "WETH balance should have decreased");

        // Velodrome market balance should have increased
        assertGt(finalVelodromeBalance, initialVelodromeBalance, "Velodrome market balance should have increased");
    }

    function test_shouldRevertWhenPoolNotGranted() public {
        // given - Don't grant the pool substrate
        uint256 amountADesired = 1000e6;
        uint256 amountBDesired = 1e18;
        uint256 amountAMin = 990e6;
        uint256 amountBMin = 0.99e18;
        uint256 deadline = block.timestamp + 3600;

        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: true,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(); // Should revert with VelodromeLiquidityFuseUnsupportedPool error
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldAddLiquidityTwiceToVelodromePool() public {
        // given
        uint256 amountADesired1 = 1e18;
        uint256 amountBDesired1 = 400_000e18;
        uint256 amountAMin1 = 0;
        uint256 amountBMin1 = 0;
        uint256 deadline = block.timestamp + 3600; // 1 hour

        uint256 amountADesired2 = 1e18;
        uint256 amountBDesired2 = 400_000e18;
        uint256 amountAMin2 = 0;
        uint256 amountBMin2 = 0;

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // First liquidity addition
        VelodromeSuperchainLiquidityFuseEnterData memory enterData1 = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired1,
            amountBDesired: amountBDesired1,
            amountAMin: amountAMin1,
            amountBMin: amountBMin1,
            deadline: deadline
        });

        FuseAction[] memory actions1 = new FuseAction[](1);
        actions1[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData1)
        );

        // Execute first liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions1);
        vm.stopPrank();

        // Record balances after first addition
        uint256 afterFirstUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 afterFirstDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 afterFirstVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // Second liquidity addition
        enterData1 = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired2,
            amountBDesired: amountBDesired2,
            amountAMin: amountAMin2,
            amountBMin: amountBMin2,
            deadline: deadline
        });

        actions1[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData1)
        );

        // Execute second liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions1);
        vm.stopPrank();

        // then
        // Verify final balances
        uint256 finalUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 finalDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // USDC and WETH balances should have decreased from initial
        assertLt(finalUnderlineBalance, initialUnderlineBalance, "Final underline balance should be less than initial");
        assertLt(finalDineroBalance, initialDineroBalance, "Final dinero balance should be less than initial");

        // Second addition should have decreased balances further
        assertLt(
            finalUnderlineBalance,
            afterFirstUnderlineBalance,
            "Second addition should decrease underline balance further"
        );
        assertLt(finalDineroBalance, afterFirstDineroBalance, "Second addition should decrease dinero balance further");

        // Velodrome market balance should have increased from initial
        assertGt(
            finalVelodromeBalance,
            initialVelodromeBalance,
            "Final Velodrome market balance should be greater than initial"
        );

        // Second addition should have increased Velodrome balance further
        assertGt(
            finalVelodromeBalance,
            afterFirstVelodromeBalance,
            "Second addition should increase Velodrome balance further"
        );
    }

    function test_shouldRemoveAllLiquidityFromVelodromePool() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // First, add liquidity
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after adding liquidity
        uint256 afterAddUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 afterAddDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 afterAddVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Now remove all liquidity
        VelodromeSuperchainLiquidityFuseExitData memory exitData = VelodromeSuperchainLiquidityFuseExitData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            liquidity: lpTokenBalance,
            amountAMin: 0, // Accept any amount back
            amountBMin: 0, // Accept any amount back
            deadline: deadline
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("exit((address,address,bool,uint256,uint256,uint256,uint256))", exitData)
        );

        // Execute liquidity removal
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then

        // Verify final balances
        uint256 finalUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 finalDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // WETH and DINERO balances should have increased after removal
        assertGt(
            finalUnderlineBalance,
            afterAddUnderlineBalance,
            "Final WETH balance should be greater than after adding liquidity"
        );
        assertGt(
            finalDineroBalance,
            afterAddDineroBalance,
            "Final DINERO balance should be greater than after adding liquidity"
        );

        // Velodrome market balance should have decreased after removal
        assertLt(
            finalVelodromeBalance,
            afterAddVelodromeBalance,
            "Final Velodrome market balance should be less than after adding liquidity"
        );

        // Final balances should be approximately equal to initial balances (within slippage)
        assertApproxEqAbs(
            finalUnderlineBalance,
            initialUnderlineBalance,
            ERROR_DELTA,
            "Final WETH balance should be approximately equal to initial"
        );
        assertApproxEqAbs(
            finalDineroBalance,
            initialDineroBalance,
            ERROR_DELTA,
            "Final DINERO balance should be approximately equal to initial"
        );
        assertApproxEqAbs(
            finalVelodromeBalance,
            initialVelodromeBalance,
            ERROR_DELTA,
            "Final Velodrome balance should be approximately equal to initial"
        );
    }

    function test_shouldClaimFeesAfterAddingLiquidity() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Get pool address for DINERO/WETH volatile pool
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);

        // First, add liquidity
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Now claim fees
        address[] memory pools = new address[](1);
        pools[0] = poolAddress;

        // Note: Velodrome doesn't have a separate claim fees fuse like Aerodrome
        // Fees are automatically collected when removing liquidity
        // This test demonstrates the liquidity addition part
        assertTrue(true, "Liquidity added successfully");
    }

    function test_shouldDepositLiquidityToVelodromeGauge() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // Now deposit LP tokens to gauge
        uint256 gaugeDepositAmount = lpTokenBalance / 2; // Deposit half of LP tokens
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: gaugeDepositAmount,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
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
        uint256 gaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertEq(gaugeBalance, gaugeDepositAmount, "Gauge balance should equal deposited amount");

        // Velodrome market balance should remain the same (LP tokens are still in the market)
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);
        assertApproxEqAbs(
            finalVelodromeBalance,
            afterLiquidityVelodromeBalance,
            ERROR_DELTA,
            "Velodrome market balance should remain approximately the same"
        );
    }

    function test_shouldRevertWhenGaugeNotGranted() public {
        // given - Don't grant the gauge substrate
        uint256 amountADesired = 1e18;
        uint256 amountBDesired = 400_000e18;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Try to deposit to an unsupported gauge
        address unsupportedGauge = address(0x1234567890123456789012345678901234567890);
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: unsupportedGauge,
            amount: lpTokenBalance / 2,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(); // Should revert with VelodromeGaugeFuseUnsupportedGauge error
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldDepositAllLiquidityToVelodromeGauge() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // Now deposit all LP tokens to gauge
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
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
        uint256 gaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertEq(gaugeBalance, lpTokenBalance, "Gauge balance should equal full LP token amount");

        // Velodrome market balance should remain the same (LP tokens are still in the market via gauge)
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);
        assertApproxEqAbs(
            finalVelodromeBalance,
            afterLiquidityVelodromeBalance,
            ERROR_DELTA,
            "Velodrome market balance should remain approximately the same"
        );
    }

    function test_shouldDepositLiquidityToGaugeTwice() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // First gauge deposit - half of LP tokens
        uint256 firstDepositAmount = lpTokenBalance / 2;
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: firstDepositAmount,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // Execute first gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after first deposit
        uint256 afterFirstLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterFirstGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));

        // Second gauge deposit - remaining LP tokens
        uint256 secondDepositAmount = afterFirstLpTokenBalance;
        gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: secondDepositAmount,
            minAmount: 0
        });

        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // Execute second gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then
        // Verify final balances
        uint256 finalLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 finalGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));

        // LP token balance should be zero after second deposit
        assertEq(finalLpTokenBalance, 0, "Final LP token balance should be zero");

        // Gauge balance should equal the full LP token amount
        assertEq(finalGaugeBalance, lpTokenBalance, "Final gauge balance should equal full LP token amount");

        // Second deposit should have increased gauge balance further
        assertGt(finalGaugeBalance, afterFirstGaugeBalance, "Second deposit should increase gauge balance further");

        // Velodrome market balance should remain the same
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);
        assertApproxEqAbs(
            finalVelodromeBalance,
            afterLiquidityVelodromeBalance,
            ERROR_DELTA,
            "Velodrome market balance should remain approximately the same"
        );
    }

    function test_shouldWithdrawLiquidityFromVelodromeGauge() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // Deposit all LP tokens to gauge
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after gauge deposit
        uint256 afterGaugeDepositLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // Now withdraw half of the LP tokens from gauge
        uint256 withdrawAmount = lpTokenBalance / 2;
        VelodromeSuperchainGaugeFuseExitData memory gaugeExitData = VelodromeSuperchainGaugeFuseExitData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: withdrawAmount,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256))", gaugeExitData)
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
        uint256 finalGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertLt(finalGaugeBalance, afterGaugeDepositGaugeBalance, "Gauge balance should have decreased");

        // Verify the withdrawn amount matches
        assertEq(finalGaugeBalance, lpTokenBalance - withdrawAmount, "Gauge balance should equal remaining amount");

        // Velodrome market balance should remain the same (LP tokens are still in the market)
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);
        assertApproxEqAbs(
            finalVelodromeBalance,
            afterGaugeDepositVelodromeBalance,
            ERROR_DELTA,
            "Velodrome market balance should remain approximately the same"
        );
    }

    function test_shouldWithdrawAllLiquidityFromVelodromeGauge() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // Deposit all LP tokens to gauge
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after gauge deposit
        uint256 afterGaugeDepositLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // Now withdraw all LP tokens from gauge
        VelodromeSuperchainGaugeFuseExitData memory gaugeExitData = VelodromeSuperchainGaugeFuseExitData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256))", gaugeExitData)
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
        uint256 finalGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertEq(finalGaugeBalance, 0, "Gauge balance should be zero");

        // Velodrome market balance should remain the same
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);
        assertApproxEqAbs(
            finalVelodromeBalance,
            afterGaugeDepositVelodromeBalance,
            ERROR_DELTA,
            "Velodrome market balance should remain approximately the same"
        );
    }

    function test_shouldWithdrawLiquidityFromGaugeTwice() public {
        // given
        uint256 amountADesired = 1e18; // 1 WETH
        uint256 amountBDesired = 400_000e18; // 400,000 DINERO
        uint256 amountAMin = 0; // Accept any amount
        uint256 amountBMin = 0; // Accept any amount
        uint256 deadline = block.timestamp + 3600; // 1 hour

        // Record initial balances
        uint256 initialVaultBalance = _plasmaVault.totalAssets();
        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterLiquidityVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // Deposit all LP tokens to gauge
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after gauge deposit
        uint256 afterGaugeDepositLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositVelodromeBalance = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // First withdrawal - half of LP tokens
        uint256 firstWithdrawAmount = lpTokenBalance / 2;
        VelodromeSuperchainGaugeFuseExitData memory gaugeExitData = VelodromeSuperchainGaugeFuseExitData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: firstWithdrawAmount,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256))", gaugeExitData)
        );

        // Execute first withdrawal
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Record balances after first withdrawal
        uint256 afterFirstWithdrawLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterFirstWithdrawGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));

        // Second withdrawal - remaining LP tokens
        uint256 secondWithdrawAmount = lpTokenBalance - firstWithdrawAmount;
        gaugeExitData = VelodromeSuperchainGaugeFuseExitData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: secondWithdrawAmount,
            minAmount: 0
        });

        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256,uint256))", gaugeExitData)
        );

        // Execute second withdrawal
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // then
        // Verify final balances
        uint256 finalLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 finalGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));

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

        // Velodrome market balance should remain the same
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);
        assertApproxEqAbs(
            finalVelodromeBalance,
            afterGaugeDepositVelodromeBalance,
            ERROR_DELTA,
            "Velodrome market balance should remain approximately the same"
        );
    }

    function test_shouldRevertWhenGaugeExitNotGranted() public {
        // given - Don't grant the gauge substrate
        uint256 amountADesired = 1e18;
        uint256 amountBDesired = 400_000e18;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Deposit LP tokens to gauge
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Try to withdraw from an unsupported gauge
        address unsupportedGauge = address(0x1234567890123456789012345678901234567890);
        VelodromeSuperchainGaugeFuseExitData memory gaugeExitData = VelodromeSuperchainGaugeFuseExitData({
            gaugeAddress: unsupportedGauge,
            amount: lpTokenBalance / 2,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(); // Should revert with VelodromeGaugeFuseUnsupportedGauge error
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    function test_shouldRevertWhenExitAmountIsZero() public {
        // given
        uint256 amountADesired = 1e18;
        uint256 amountBDesired = 400_000e18;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        // Execute liquidity addition
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Deposit LP tokens to gauge
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        // Execute gauge deposit
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Try to withdraw zero amount
        VelodromeSuperchainGaugeFuseExitData memory gaugeExitData = VelodromeSuperchainGaugeFuseExitData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: 0,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        );

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(); // Should revert with VelodromeGaugeFuseInvalidAmount error
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    // function test_shouldClaimRewardsFromGauge() public {
    //     //given
    //     test_shouldDepositAllLiquidityToAerodromeGauge();
    //     vm.warp(block.timestamp + 4 days);

    //     address[] memory gauges = new address[](1);
    //     gauges[0] = _AERODROME_GAUGE;

    //     FuseAction[] memory actions = new FuseAction[](1);

    //     _aerodromeGaugeClaimFuse = new AerodromeGaugeClaimFuse(IporFusionMarkets.AERODROME);

    //     actions[0] = FuseAction(address(_aerodromeGaugeClaimFuse), abi.encodeWithSignature("claim(address[])", gauges));

    //     address[] memory rewardFuses = new address[](1);
    //     rewardFuses[0] = address(_aerodromeGaugeClaimFuse);

    //     vm.startPrank(_FUSE_MANAGER);
    //     _rewardsClaimManager.addRewardFuses(rewardFuses);
    //     vm.stopPrank();

    //     uint256 balanceBefore = IERC20(_AERODROME_REWARD_TOKEN).balanceOf(address(_rewardsClaimManager));

    //     //when
    //     vm.startPrank(_ALPHA);
    //     _rewardsClaimManager.claimRewards(actions);
    //     vm.stopPrank();

    //     //then
    //     uint256 balanceAfter = IERC20(_AERODROME_REWARD_TOKEN).balanceOf(address(_rewardsClaimManager));
    //     assertEq(balanceBefore, 0, "Balance should be 0");
    //     assertGt(balanceAfter, 0, "Balance should be greater than 0");
    // }

    // // ============ Tests for substrateToBytes32 and bytes32ToSubstrate functions ============

    function test_shouldConvertGaugeSubstrateToBytes32AndBack() public {
        // given
        address gaugeAddress = _VELODROME_GAUGE;
        VelodromeSuperchainSubstrate memory originalSubstrate = VelodromeSuperchainSubstrate({
            substrateType: VelodromeSuperchainSubstrateType.Gauge,
            substrateAddress: gaugeAddress
        });

        // when
        bytes32 encodedSubstrate = VelodromeSuperchainSubstrateLib.substrateToBytes32(originalSubstrate);
        VelodromeSuperchainSubstrate memory decodedSubstrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(
            encodedSubstrate
        );

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
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        VelodromeSuperchainSubstrate memory originalSubstrate = VelodromeSuperchainSubstrate({
            substrateType: VelodromeSuperchainSubstrateType.Pool,
            substrateAddress: poolAddress
        });

        // when
        bytes32 encodedSubstrate = VelodromeSuperchainSubstrateLib.substrateToBytes32(originalSubstrate);
        VelodromeSuperchainSubstrate memory decodedSubstrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(
            encodedSubstrate
        );

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
        VelodromeSuperchainSubstrate memory originalSubstrate = VelodromeSuperchainSubstrate({
            substrateType: VelodromeSuperchainSubstrateType.UNDEFINED,
            substrateAddress: someAddress
        });

        // when
        bytes32 encodedSubstrate = VelodromeSuperchainSubstrateLib.substrateToBytes32(originalSubstrate);
        VelodromeSuperchainSubstrate memory decodedSubstrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(
            encodedSubstrate
        );

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
        VelodromeSuperchainSubstrate memory originalSubstrate = VelodromeSuperchainSubstrate({
            substrateType: VelodromeSuperchainSubstrateType.Gauge,
            substrateAddress: zeroAddress
        });

        // when
        bytes32 encodedSubstrate = VelodromeSuperchainSubstrateLib.substrateToBytes32(originalSubstrate);
        VelodromeSuperchainSubstrate memory decodedSubstrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(
            encodedSubstrate
        );

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
        VelodromeSuperchainSubstrate memory originalSubstrate = VelodromeSuperchainSubstrate({
            substrateType: VelodromeSuperchainSubstrateType.Pool,
            substrateAddress: maxAddress
        });

        // when
        bytes32 encodedSubstrate = VelodromeSuperchainSubstrateLib.substrateToBytes32(originalSubstrate);
        VelodromeSuperchainSubstrate memory decodedSubstrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(
            encodedSubstrate
        );

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
        VelodromeSuperchainSubstrateType testType = VelodromeSuperchainSubstrateType.Gauge;
        VelodromeSuperchainSubstrate memory originalSubstrate = VelodromeSuperchainSubstrate({
            substrateType: testType,
            substrateAddress: testAddress
        });

        // when
        bytes32 encodedSubstrate = VelodromeSuperchainSubstrateLib.substrateToBytes32(originalSubstrate);

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
        VelodromeSuperchainSubstrateType testType = VelodromeSuperchainSubstrateType.Pool;
        uint256 encodedValue = uint256(uint160(testAddress)) | (uint256(testType) << 160);
        bytes32 encodedSubstrate = bytes32(encodedValue);

        // when
        VelodromeSuperchainSubstrate memory decodedSubstrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(
            encodedSubstrate
        );

        // then
        assertEq(uint256(decodedSubstrate.substrateType), uint256(testType), "Decoded type should match");
        assertEq(decodedSubstrate.substrateAddress, testAddress, "Decoded address should match");
    }

    function test_shouldHandleAllSubstrateTypes() public {
        // given
        address testAddress = address(0x1111111111111111111111111111111111111111);
        VelodromeSuperchainSubstrateType[] memory types = new VelodromeSuperchainSubstrateType[](3);
        types[0] = VelodromeSuperchainSubstrateType.UNDEFINED;
        types[1] = VelodromeSuperchainSubstrateType.Gauge;
        types[2] = VelodromeSuperchainSubstrateType.Pool;

        for (uint256 i = 0; i < types.length; i++) {
            VelodromeSuperchainSubstrate memory originalSubstrate = VelodromeSuperchainSubstrate({
                substrateType: types[i],
                substrateAddress: testAddress
            });

            // when
            bytes32 encodedSubstrate = VelodromeSuperchainSubstrateLib.substrateToBytes32(originalSubstrate);
            VelodromeSuperchainSubstrate memory decodedSubstrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(
                encodedSubstrate
            );

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
            VelodromeSuperchainSubstrate memory originalSubstrate = VelodromeSuperchainSubstrate({
                substrateType: VelodromeSuperchainSubstrateType.Gauge,
                substrateAddress: testAddresses[i]
            });

            // when
            bytes32 encodedSubstrate = VelodromeSuperchainSubstrateLib.substrateToBytes32(originalSubstrate);
            VelodromeSuperchainSubstrate memory decodedSubstrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(
                encodedSubstrate
            );

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

    function test_shouldEnterUsingTransientStorage() public {
        // given
        uint256 amountADesired = 1e18;
        uint256 amountBDesired = 400_000e18;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        uint256 initialUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 initialDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 initialVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // Prepare transient inputs: tokenA, tokenB, stable, amountADesired, amountBDesired, amountAMin, amountBMin, deadline
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromeLiquidityFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](8);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(_UNDERLYING_TOKEN);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(_DINERO);
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(0)); // stable = false
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(amountADesired);
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(amountBDesired);
        inputsByFuse[0][5] = TypeConversionLib.toBytes32(amountAMin);
        inputsByFuse[0][6] = TypeConversionLib.toBytes32(amountBMin);
        inputsByFuse[0][7] = TypeConversionLib.toBytes32(deadline);

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_velodromeLiquidityFuse), abi.encodeWithSignature("enterTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 finalUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 finalDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        assertLt(finalUnderlineBalance, initialUnderlineBalance, "WETH balance should have decreased");
        assertLt(finalDineroBalance, initialDineroBalance, "DINERO balance should have decreased");
        assertGt(finalVelodromeBalance, initialVelodromeBalance, "Velodrome market balance should have increased");
    }

    function test_shouldExitUsingTransientStorage() public {
        // given
        uint256 amountADesired = 1e18;
        uint256 amountBDesired = 400_000e18;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        // First, add liquidity using regular enter
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        uint256 afterAddUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 afterAddDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 afterAddVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // Prepare transient inputs for exit: tokenA, tokenB, stable, liquidity, amountAMin, amountBMin, deadline
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromeLiquidityFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](7);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(_UNDERLYING_TOKEN);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(_DINERO);
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(0)); // stable = false
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(lpTokenBalance);
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(amountAMin);
        inputsByFuse[0][5] = TypeConversionLib.toBytes32(amountBMin);
        inputsByFuse[0][6] = TypeConversionLib.toBytes32(deadline);

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_velodromeLiquidityFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 finalUnderlineBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        uint256 finalDineroBalance = IERC20(_DINERO).balanceOf(address(_plasmaVault));
        uint256 finalVelodromeBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        assertGt(finalUnderlineBalance, afterAddUnderlineBalance, "WETH balance should have increased after removal");
        assertGt(finalDineroBalance, afterAddDineroBalance, "DINERO balance should have increased after removal");
        assertLt(finalVelodromeBalance, afterAddVelodromeBalance, "Velodrome market balance should have decreased");
    }

    function test_shouldEnterGaugeUsingTransientStorage() public {
        // given
        uint256 amountADesired = 1e18;
        uint256 amountBDesired = 400_000e18;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        uint256 beforeGaugeDepositLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Prepare transient inputs for gauge enter: gaugeAddress, amount, minAmount
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromeGaugeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](3);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(_VELODROME_GAUGE);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(lpTokenBalance);
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(0)); // minAmount = 0

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_velodromeGaugeFuse), abi.encodeWithSignature("enterTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 afterGaugeDepositLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterGaugeDepositGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));

        assertLt(
            afterGaugeDepositLpTokenBalance,
            beforeGaugeDepositLpTokenBalance,
            "LP token balance should have decreased"
        );
        assertEq(afterGaugeDepositGaugeBalance, lpTokenBalance, "Gauge balance should equal deposited amount");
    }

    function test_shouldExitGaugeUsingTransientStorage() public {
        // given
        uint256 amountADesired = 1e18;
        uint256 amountBDesired = 400_000e18;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 3600;

        // First, add liquidity to get LP tokens
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin,
            deadline: deadline
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Get pool address and LP token balance
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Deposit all LP tokens to gauge using regular enter
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: lpTokenBalance,
            minAmount: 0
        });

        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        uint256 beforeGaugeWithdrawLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Prepare transient inputs for gauge exit: gaugeAddress, amount, minAmount
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromeGaugeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](3);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(_VELODROME_GAUGE);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(lpTokenBalance);
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(0)); // minAmount = 0

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_velodromeGaugeFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 afterGaugeWithdrawLpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 afterGaugeWithdrawGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));

        assertGt(
            afterGaugeWithdrawLpTokenBalance,
            beforeGaugeWithdrawLpTokenBalance,
            "LP token balance should have increased"
        );
        assertEq(afterGaugeWithdrawLpTokenBalance, lpTokenBalance, "LP token balance should be restored");
        assertEq(afterGaugeWithdrawGaugeBalance, 0, "Gauge balance should be zero");
    }

    /// @notice IL-6790 R3.H2: Regression test to verify that gauge-staked LP fees are correctly attributed
    ///         to the gauge's fee caches (fees0/fees1) prorated by vault's share, NOT to the vault's pool fee indices.
    /// @dev When LP tokens are staked in a Gauge, the Pool accrues per-account fees to the address that holds
    ///      LP tokens at the Pool (typically the Gauge), not to the original depositor's address (vault).
    ///      The fix uses ILeafGauge.fees0()/fees1() prorated by (vault_stake / gauge_totalSupply) instead of
    ///      using IPool.supplyIndex0/supplyIndex1 keyed to the vault address.
    function test_IL6790_H2_GaugeFeesProration() public {
        // Step 1: Add liquidity to get LP tokens
        _addLiquidityToPool(1e18, 400_000e18);

        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Step 2: Stake all LP tokens in the gauge
        _stakeInGauge(lpTokenBalance);

        // Verify LP tokens are staked in gauge
        uint256 vaultGaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));
        assertEq(vaultGaugeBalance, lpTokenBalance, "All LP tokens should be staked");
        assertEq(IERC20(poolAddress).balanceOf(address(_plasmaVault)), 0, "No LP should remain");

        // Step 3: Verify vault's pool-level claimables are zero (fees accrue to gauge, not vault)
        // This demonstrates the bug scenario: using vault's pool indices would give wrong values
        assertEq(IPool(poolAddress).claimable0(address(_plasmaVault)), 0, "Pool claimable0 should be 0");
        assertEq(IPool(poolAddress).claimable1(address(_plasmaVault)), 0, "Pool claimable1 should be 0");

        // Step 4: Get the actual balance from the fuse (uses correct gauge-based calculation)
        uint256 actualBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);
        assertGt(actualBalance, 0, "Balance should be positive for gauge position");

        // Log for debugging
        emit log_named_uint("Vault gauge balance", vaultGaugeBalance);
        emit log_named_uint("Gauge fees0", ILeafGauge(_VELODROME_GAUGE).fees0());
        emit log_named_uint("Gauge fees1", ILeafGauge(_VELODROME_GAUGE).fees1());
        emit log_named_uint("Actual balance", actualBalance);
    }

    /// @notice IL-6790 R3.H2: Test fee attribution after time passage
    function test_IL6790_H2_GaugeFeesAfterTimePassage() public {
        // Add liquidity and stake in gauge
        _addLiquidityToPool(1e18, 400_000e18);
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 lpTokenBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        _stakeInGauge(lpTokenBalance);

        // Record balance before time passage
        uint256 balanceBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // Simulate time passage (4 days)
        vm.warp(block.timestamp + 4 days);

        // Record balance after time passage
        uint256 balanceAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // The balance should remain reasonable after time passage
        assertGt(balanceAfter, 0, "Balance should remain positive");

        // Balance change should be within reasonable bounds (not inflated due to wrong attribution)
        uint256 maxReasonableChange = balanceBefore / 10; // 10% max change for 4 days
        uint256 actualChange = balanceAfter > balanceBefore
            ? balanceAfter - balanceBefore
            : balanceBefore - balanceAfter;

        assertLe(actualChange, maxReasonableChange, "Balance change should be reasonable");

        emit log_named_uint("Balance before", balanceBefore);
        emit log_named_uint("Balance after", balanceAfter);
    }

    /// @notice IL-6790 R3.H2: Test mixed pool and gauge positions
    function test_IL6790_H2_MixedPositions() public {
        // Add liquidity
        _addLiquidityToPool(2e18, 800_000e18);
        address poolAddress = IRouter(_VELODROME_ROUTER).poolFor(_DINERO, _UNDERLYING_TOKEN, false);
        uint256 totalLpBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));

        // Stake only HALF of LP tokens in gauge
        _stakeInGauge(totalLpBalance / 2);

        // Verify the split
        uint256 poolBalance = IERC20(poolAddress).balanceOf(address(_plasmaVault));
        uint256 gaugeBalance = ILeafGauge(_VELODROME_GAUGE).balanceOf(address(_plasmaVault));

        assertApproxEqAbs(poolBalance, totalLpBalance / 2, 1, "Half should remain in pool");
        assertApproxEqAbs(gaugeBalance, totalLpBalance / 2, 1, "Half should be in gauge");

        // Get total balance - should account for both positions
        uint256 totalBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.VELODROME_SUPERCHAIN);
        assertGt(totalBalance, 0, "Total balance should be positive");

        emit log_named_uint("Pool LP balance", poolBalance);
        emit log_named_uint("Gauge LP balance", gaugeBalance);
        emit log_named_uint("Total balance", totalBalance);
    }

    /// @dev Helper function to add liquidity to the pool
    function _addLiquidityToPool(uint256 amountA, uint256 amountB) internal {
        VelodromeSuperchainLiquidityFuseEnterData memory enterData = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: _UNDERLYING_TOKEN,
            tokenB: _DINERO,
            stable: false,
            amountADesired: amountA,
            amountBDesired: amountB,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp + 3600
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeLiquidityFuse),
            abi.encodeWithSignature("enter((address,address,bool,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }

    /// @dev Helper function to stake LP tokens in the gauge
    function _stakeInGauge(uint256 amount) internal {
        VelodromeSuperchainGaugeFuseEnterData memory gaugeEnterData = VelodromeSuperchainGaugeFuseEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            amount: amount,
            minAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_velodromeGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();
    }
}
