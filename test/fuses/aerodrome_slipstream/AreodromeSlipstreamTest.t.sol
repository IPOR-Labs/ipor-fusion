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
import {AreodromeSlipstreamCollectFuse, AreodromeSlipstreamCollectFuseEnterData} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamCollectFuse.sol";
import {AreodromeSlipstreamNewPositionFuse, AreodromeSlipstreamNewPositionFuseEnterData} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamNewPositionFuse.sol";
import {AreodromeSlipstreamModifyPositionFuse, AreodromeSlipstreamModifyPositionFuseEnterData, AreodromeSlipstreamModifyPositionFuseExitData} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamModifyPositionFuse.sol";
import {AreodromeSlipstreamCLGauge, AreodromeSlipstreamCLGaugeEnterData, AreodromeSlipstreamCLGaugeExitData} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamCLGauge.sol";
import {AreodromeSlipstreamCollectFuse} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamCollectFuse.sol";
import {AreodromeSlipstreamBalance} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamBalance.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamLib.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {INonfungiblePositionManager} from "../../../contracts/fuses/aerodrome_slipstream/ext/INonfungiblePositionManager.sol";
import {ICLGauge} from "../../../contracts/fuses/aerodrome_slipstream/ext/ICLGauge.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {AreodromeSlipstreamGaugeClaimFuse} from "../../../contracts/rewards_fuses/areodrome_slipstream/AreodromeSlipstreamGaugeClaimFuse.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title AreodromeSlipstreamTest
/// @notice Test suite for Velodrom Superchain Slipstream Collect Fuse
/// @dev Tests the collection of fees from Velodrom Superchain Slipstream NFT positions
contract AreodromeSlipstreamTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    // Test constants
    address private constant _WETH = 0x4200000000000000000000000000000000000006;
    address private constant _USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant _UNDERLYING_TOKEN = _USDC;
    string private constant _UNDERLYING_TOKEN_NAME = "USDC";
    address private constant _USER = TestAddresses.USER;
    address private constant _ATOMIST = TestAddresses.ATOMIST;
    address private constant _FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant _ALPHA = TestAddresses.ALPHA;

    address private constant _fusionFactory = 0x1455717668fA96534f675856347A973fA907e922;
    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    address private constant _SLIPSTREAM_SUPERCHAIN_VAULT = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;

    address private constant _VELODROME_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address private constant _VELODROME_GAUGE = 0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8;

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    PriceOracleMiddlewareManager private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    RewardsClaimManager private _rewardsClaimManager;

    AreodromeSlipstreamNewPositionFuse private _areodromeSlipstreamNewPositionFuse;
    AreodromeSlipstreamModifyPositionFuse private _areodromeSlipstreamModifyPositionFuse;
    AreodromeSlipstreamCLGauge private _areodromeSlipstreamCLGauge;
    AreodromeSlipstreamCollectFuse private _areodromeSlipstreamCollectFuse;
    AreodromeSlipstreamBalance private _areodromeSlipstreamBalance;
    AreodromeSlipstreamGaugeClaimFuse private _velodromeGaugeClaimFuse;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 33796435);

        FusionFactory fusionFactory = FusionFactory(_fusionFactory);

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = fusionFactory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());

        address factoryAdmin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(factoryAdmin);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), factoryAdmin);
        fusionFactory.updateFactoryAddresses(1000, factoryAddresses);
        vm.stopPrank();

        FusionFactoryLib.FusionInstance memory fusionInstance = fusionFactory.create(
            "AreodromeSlipstream",
            "VSS",
            _UNDERLYING_TOKEN,
            0,
            _ATOMIST
        );

        _plasmaVault = PlasmaVault(fusionInstance.plasmaVault);
        _priceOracleMiddleware = PriceOracleMiddlewareManager(fusionInstance.priceManager);
        _accessManager = IporFusionAccessManager(fusionInstance.accessManager);
        _plasmaVaultGovernance = PlasmaVaultGovernance(fusionInstance.plasmaVault);
        _rewardsClaimManager = RewardsClaimManager(fusionInstance.rewardsManager);

        vm.startPrank(_ATOMIST);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, _ATOMIST, 0);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, _FUSE_MANAGER, 0);
        _accessManager.grantRole(Roles.ALPHA_ROLE, _ALPHA, 0);
        _accessManager.grantRole(Roles.CLAIM_REWARDS_ROLE, _ALPHA, 0);
        _accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, _ATOMIST, 0);
        _plasmaVaultGovernance.convertToPublicVault();
        _plasmaVaultGovernance.enableTransferShares();
        vm.stopPrank();

        // Provide initial liquidity to user
        deal(_USDC, _USER, 1_000_000e6);
        deal(_WETH, _USER, 1_000_000e18);

        // Deploy AreodromeSlipstreamCollectFuse
        _areodromeSlipstreamNewPositionFuse = new AreodromeSlipstreamNewPositionFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _areodromeSlipstreamModifyPositionFuse = new AreodromeSlipstreamModifyPositionFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _areodromeSlipstreamCLGauge = new AreodromeSlipstreamCLGauge(IporFusionMarkets.VELODROME_SUPERCHAIN);
        _areodromeSlipstreamCollectFuse = new AreodromeSlipstreamCollectFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _areodromeSlipstreamBalance = new AreodromeSlipstreamBalance(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _NONFUNGIBLE_POSITION_MANAGER,
            _SLIPSTREAM_SUPERCHAIN_VAULT
        );

        _velodromeGaugeClaimFuse = new AreodromeSlipstreamGaugeClaimFuse(IporFusionMarkets.VELODROME_SUPERCHAIN);

        // Setup fuses
        address[] memory fuses = new address[](4);
        fuses[0] = address(_areodromeSlipstreamNewPositionFuse);
        fuses[1] = address(_areodromeSlipstreamModifyPositionFuse);
        fuses[2] = address(_areodromeSlipstreamCLGauge);
        fuses[3] = address(_areodromeSlipstreamCollectFuse);

        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = address(_velodromeGaugeClaimFuse);

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.addFuses(fuses);
        _rewardsClaimManager.addRewardFuses(rewardFuses);

        _plasmaVaultGovernance.addBalanceFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            address(_areodromeSlipstreamBalance)
        );

        _plasmaVaultGovernance.addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        vm.stopPrank();

        // Setup market substrates
        bytes32[] memory velodromSubstrates = new bytes32[](2);
        velodromSubstrates[0] = AreodromeSlipstreamSubstrateLib.substrateToBytes32(
            AreodromeSlipstreamSubstrate({
                substrateType: AreodromeSlipstreamSubstrateType.Pool,
                substrateAddress: _VELODROME_POOL
            })
        );
        velodromSubstrates[1] = AreodromeSlipstreamSubstrateLib.substrateToBytes32(
            AreodromeSlipstreamSubstrate({
                substrateType: AreodromeSlipstreamSubstrateType.Gauge,
                substrateAddress: _VELODROME_GAUGE
            })
        );

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.VELODROME_SUPERCHAIN, velodromSubstrates);
        vm.stopPrank();

        // Setup price feeds
        address[] memory assets = new address[](2);
        assets[0] = _USDC;
        assets[1] = _WETH;

        address oneUsd = address(new USDPriceFeed());
        address[] memory sources = new address[](2);
        sources[0] = oneUsd;
        sources[1] = address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);

        vm.startPrank(_ATOMIST);
        _priceOracleMiddleware.setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        bytes32[] memory erc20VaultBalanceSubstrates = new bytes32[](2);
        erc20VaultBalanceSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        erc20VaultBalanceSubstrates[1] = PlasmaVaultConfigLib.addressToBytes32(_WETH);

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            erc20VaultBalanceSubstrates
        );
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.VELODROME_SUPERCHAIN;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.updateDependencyBalanceGraphs(marketIds, dependencies);
        vm.stopPrank();

        vm.startPrank(_USER);
        IERC20(_USDC).approve(address(_plasmaVault), 100_000e6);
        _plasmaVault.deposit(100_000e6, _USER);
        IERC20(_WETH).transfer(address(_plasmaVault), 1_000e18);
        vm.stopPrank();
    }

    function test_shouldCollectFeesFromNFTPositions() public {
        // given
        AreodromeSlipstreamNewPositionFuseEnterData memory mintParams = AreodromeSlipstreamNewPositionFuseEnterData({
            token0: _WETH,
            token1: _USDC,
            tickSpacing: 100,
            tickLower: 100,
            tickUpper: 300,
            amount0Desired: 10e18,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            sqrtPriceX96: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_areodromeSlipstreamNewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint160))",
                mintParams
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdcBalanceBefore = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdcBalanceAfter = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceAfter = IERC20(_WETH).balanceOf(address(_plasmaVault));

        uint256 nft = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
        assertTrue(nft > 0, "nft > 0");
    }

    function test_shouldCreateSecondPosition() public {
        test_shouldCollectFeesFromNFTPositions();

        // given
        AreodromeSlipstreamNewPositionFuseEnterData memory mintParams = AreodromeSlipstreamNewPositionFuseEnterData({
            token0: _WETH,
            token1: _USDC,
            tickSpacing: 100,
            tickLower: 0,
            tickUpper: 300,
            amount0Desired: 10e18,
            amount1Desired: 100e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            sqrtPriceX96: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_areodromeSlipstreamNewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint160))",
                mintParams
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdcBalanceBefore = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdcBalanceAfter = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceAfter = IERC20(_WETH).balanceOf(address(_plasmaVault));

        uint256 nft = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            1
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
        assertTrue(nft > 0, "nft > 0");
    }

    function test_shouldIncreasePosition() public {
        test_shouldCollectFeesFromNFTPositions();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        AreodromeSlipstreamModifyPositionFuseEnterData
            memory modifyParams = AreodromeSlipstreamModifyPositionFuseEnterData({
                token0: _WETH,
                token1: _USDC,
                tokenId: tokenId,
                amount0Desired: 100e18,
                amount1Desired: 10_00e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });

        FuseAction[] memory modifyCalls = new FuseAction[](1);
        modifyCalls[0] = FuseAction(
            address(_areodromeSlipstreamModifyPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256))",
                modifyParams
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdcBalanceBefore = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdcBalanceAfter = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceAfter = IERC20(_WETH).balanceOf(address(_plasmaVault));

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
    }

    function test_shouldDecreasePosition() public {
        test_shouldCreateSecondPosition();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        (, , , , , , , uint128 liquidityBefore, , , , ) = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER)
            .positions(tokenId);

        AreodromeSlipstreamModifyPositionFuseExitData
            memory modifyParams = AreodromeSlipstreamModifyPositionFuseExitData({
                tokenId: tokenId,
                liquidity: liquidityBefore / 4,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });

        FuseAction[] memory modifyCalls = new FuseAction[](1);
        modifyCalls[0] = FuseAction(
            address(_areodromeSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", modifyParams)
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        (, , , , , , , uint128 liquidityAfter, , , , ) = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER)
            .positions(tokenId);

        // assertGt(marketBalanceBefore, marketBalanceAfter, "marketBalanceBefore > marketBalanceAfter");
        // assertGt(liquidityBefore, liquidityAfter, "liquidityBefore > liquidityAfter");
    }

    function test_shouldCollectFromNFTPosition() public {
        test_shouldDecreasePosition();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        AreodromeSlipstreamCollectFuseEnterData memory collectParams = AreodromeSlipstreamCollectFuseEnterData({
            tokenIds: tokenIds
        });

        FuseAction[] memory collectCalls = new FuseAction[](1);
        collectCalls[0] = FuseAction(
            address(_areodromeSlipstreamCollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectParams)
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(collectCalls);

        uint256 wethBalanceAfter = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        assertGt(wethBalanceAfter, wethBalanceBefore, "wethBalanceAfter should be greater than wethBalanceBefore");

        assertGt(
            marketBalanceBefore,
            marketBalanceAfter,
            "marketBalanceBefore should be greater than marketBalanceAfter"
        );
    }

    function test_shouldStakeToGauge() public {
        test_shouldCollectFromNFTPosition();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        AreodromeSlipstreamCLGaugeEnterData memory stakeParams = AreodromeSlipstreamCLGaugeEnterData({
            gaugeAddress: _VELODROME_GAUGE,
            tokenId: tokenId
        });

        FuseAction[] memory stakeCalls = new FuseAction[](1);
        stakeCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGauge),
            abi.encodeWithSignature("enter((address,uint256))", stakeParams)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(stakeCalls);
        vm.stopPrank();

        uint256[] memory stakedValues = ICLGauge(_VELODROME_GAUGE).stakedValues(address(_plasmaVault));

        assertEq(stakedValues[0], tokenId, "stakedValues[0] should be equal to tokenId");
    }

    function test_shouldUnstakeFromGauge() public {
        test_shouldStakeToGauge();

        uint256[] memory stakedValuesBefore = ICLGauge(_VELODROME_GAUGE).stakedValues(address(_plasmaVault));

        AreodromeSlipstreamCLGaugeExitData memory unstakeParams = AreodromeSlipstreamCLGaugeExitData({
            gaugeAddress: _VELODROME_GAUGE,
            tokenId: stakedValuesBefore[0]
        });

        FuseAction[] memory unstakeCalls = new FuseAction[](1);
        unstakeCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGauge),
            abi.encodeWithSignature("exit((address,uint256))", unstakeParams)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(unstakeCalls);
        vm.stopPrank();

        // then
        uint256[] memory stakedValuesAfter = ICLGauge(_VELODROME_GAUGE).stakedValues(address(_plasmaVault));

        assertEq(
            stakedValuesBefore.length - 1,
            stakedValuesAfter.length,
            "stakedValuesBefore should be equal to stakedValuesAfter"
        );
    }

    function test_shouldClaimRewardsFromGauge() public {
        test_shouldStakeToGauge();

        vm.warp(block.timestamp + 7 days);

        address[] memory gauges = new address[](1);
        gauges[0] = _VELODROME_GAUGE;

        FuseAction[] memory claimCalls = new FuseAction[](1);
        claimCalls[0] = FuseAction(
            address(_velodromeGaugeClaimFuse),
            abi.encodeWithSignature("claim(address[])", gauges)
        );
        address rewardToken = ICLGauge(_VELODROME_GAUGE).rewardToken();
        uint256 balanceBefore = IERC20(rewardToken).balanceOf(address(_rewardsClaimManager));

        // when
        vm.startPrank(_ALPHA);
        _rewardsClaimManager.claimRewards(claimCalls);
        vm.stopPrank();

        // then
        uint256 balanceAfter = IERC20(rewardToken).balanceOf(address(_rewardsClaimManager));

        assertGe(balanceAfter, balanceBefore, "balanceAfter should be greater than or equal to balanceBefore");
    }
}
