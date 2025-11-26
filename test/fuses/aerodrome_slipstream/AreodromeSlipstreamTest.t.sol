// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
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
import {AreodromeSlipstreamNewPositionFuse, AreodromeSlipstreamNewPositionFuseEnterData, AreodromeSlipstreamNewPositionFuseExitData} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamNewPositionFuse.sol";
import {AreodromeSlipstreamModifyPositionFuse, AreodromeSlipstreamModifyPositionFuseEnterData, AreodromeSlipstreamModifyPositionFuseExitData} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamModifyPositionFuse.sol";
import {AreodromeSlipstreamCLGaugeFuse, AreodromeSlipstreamCLGaugeFuseEnterData, AreodromeSlipstreamCLGaugeFuseExitData} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamCLGaugeFuse.sol";
import {AreodromeSlipstreamBalanceFuse} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamBalanceFuse.sol";
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
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";

/// @title AreodromeSlipstreamTest
/// @notice Test suite for Velodrom Superchain Slipstream Collect Fuse
/// @dev Tests the collection of fees from Velodrom Superchain Slipstream NFT positions
contract AreodromeSlipstreamTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;
    using Address for address;

    error InvalidReturnData();

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

    address private constant _AREODROME_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address private constant _AREODROME_GAUGE = 0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8;

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    PriceOracleMiddlewareManager private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    RewardsClaimManager private _rewardsClaimManager;

    AreodromeSlipstreamNewPositionFuse private _areodromeSlipstreamNewPositionFuse;
    AreodromeSlipstreamModifyPositionFuse private _areodromeSlipstreamModifyPositionFuse;
    AreodromeSlipstreamCLGaugeFuse private _areodromeSlipstreamCLGaugeFuse;
    AreodromeSlipstreamCollectFuse private _areodromeSlipstreamCollectFuse;
    AreodromeSlipstreamBalanceFuse private _areodromeSlipstreamBalance;
    AreodromeSlipstreamGaugeClaimFuse private _velodromeGaugeClaimFuse;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 33796435);

        FusionFactory fusionFactory = FusionFactory(_fusionFactory);

        address plasmaVaultBase = address(new PlasmaVaultBase());

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = fusionFactory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());

        address factoryAdmin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(factoryAdmin);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), factoryAdmin);
        fusionFactory.updateFactoryAddresses(1000, factoryAddresses);
        fusionFactory.updatePlasmaVaultBase(plasmaVaultBase);
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
            IporFusionMarkets.AREODROME_SLIPSTREAM,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _areodromeSlipstreamModifyPositionFuse = new AreodromeSlipstreamModifyPositionFuse(
            IporFusionMarkets.AREODROME_SLIPSTREAM,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _areodromeSlipstreamCLGaugeFuse = new AreodromeSlipstreamCLGaugeFuse(IporFusionMarkets.AREODROME_SLIPSTREAM);
        _areodromeSlipstreamCollectFuse = new AreodromeSlipstreamCollectFuse(
            IporFusionMarkets.AREODROME_SLIPSTREAM,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _areodromeSlipstreamBalance = new AreodromeSlipstreamBalanceFuse(
            IporFusionMarkets.AREODROME_SLIPSTREAM,
            _NONFUNGIBLE_POSITION_MANAGER,
            _SLIPSTREAM_SUPERCHAIN_VAULT
        );

        _velodromeGaugeClaimFuse = new AreodromeSlipstreamGaugeClaimFuse(IporFusionMarkets.AREODROME_SLIPSTREAM);

        // Setup fuses
        address[] memory fuses = new address[](4);
        fuses[0] = address(_areodromeSlipstreamNewPositionFuse);
        fuses[1] = address(_areodromeSlipstreamModifyPositionFuse);
        fuses[2] = address(_areodromeSlipstreamCLGaugeFuse);
        fuses[3] = address(_areodromeSlipstreamCollectFuse);

        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = address(_velodromeGaugeClaimFuse);

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.addFuses(fuses);
        _rewardsClaimManager.addRewardFuses(rewardFuses);

        _plasmaVaultGovernance.addBalanceFuse(
            IporFusionMarkets.AREODROME_SLIPSTREAM,
            address(_areodromeSlipstreamBalance)
        );

        _plasmaVaultGovernance.addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        vm.stopPrank();

        // Setup market substrates
        bytes32[] memory areodromSubstrates = new bytes32[](2);
        areodromSubstrates[0] = AreodromeSlipstreamSubstrateLib.substrateToBytes32(
            AreodromeSlipstreamSubstrate({
                substrateType: AreodromeSlipstreamSubstrateType.Pool,
                substrateAddress: _AREODROME_POOL
            })
        );
        areodromSubstrates[1] = AreodromeSlipstreamSubstrateLib.substrateToBytes32(
            AreodromeSlipstreamSubstrate({
                substrateType: AreodromeSlipstreamSubstrateType.Gauge,
                substrateAddress: _AREODROME_GAUGE
            })
        );

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.AREODROME_SLIPSTREAM, areodromSubstrates);
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
        marketIds[0] = IporFusionMarkets.AREODROME_SLIPSTREAM;
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
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 usdcBalanceBefore = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
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
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 usdcBalanceBefore = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
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
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 usdcBalanceBefore = IERC20(_USDC).balanceOf(address(_plasmaVault));
        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
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

        uint128 liquidityBefore = _getLiquidity(tokenId);

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
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );

        uint128 liquidityAfter = _getLiquidity(tokenId);
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
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );

        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(collectCalls);

        uint256 wethBalanceAfter = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
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

        AreodromeSlipstreamCLGaugeFuseEnterData memory stakeParams = AreodromeSlipstreamCLGaugeFuseEnterData({
            gaugeAddress: _AREODROME_GAUGE,
            tokenId: tokenId
        });

        FuseAction[] memory stakeCalls = new FuseAction[](1);
        stakeCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", stakeParams)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(stakeCalls);
        vm.stopPrank();

        uint256[] memory stakedValues = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));

        assertEq(stakedValues[0], tokenId, "stakedValues[0] should be equal to tokenId");
    }

    function test_shouldUnstakeFromGauge() public {
        test_shouldStakeToGauge();

        uint256[] memory stakedValuesBefore = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));

        AreodromeSlipstreamCLGaugeFuseExitData memory unstakeParams = AreodromeSlipstreamCLGaugeFuseExitData({
            gaugeAddress: _AREODROME_GAUGE,
            tokenId: stakedValuesBefore[0]
        });

        FuseAction[] memory unstakeCalls = new FuseAction[](1);
        unstakeCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", unstakeParams)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(unstakeCalls);
        vm.stopPrank();

        // then
        uint256[] memory stakedValuesAfter = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));

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
        gauges[0] = _AREODROME_GAUGE;

        FuseAction[] memory claimCalls = new FuseAction[](1);
        claimCalls[0] = FuseAction(
            address(_velodromeGaugeClaimFuse),
            abi.encodeWithSignature("claim(address[])", gauges)
        );
        address rewardToken = ICLGauge(_AREODROME_GAUGE).rewardToken();
        uint256 balanceBefore = IERC20(rewardToken).balanceOf(address(_rewardsClaimManager));

        // when
        vm.startPrank(_ALPHA);
        _rewardsClaimManager.claimRewards(claimCalls);
        vm.stopPrank();

        // then
        uint256 balanceAfter = IERC20(rewardToken).balanceOf(address(_rewardsClaimManager));

        assertGe(balanceAfter, balanceBefore, "balanceAfter should be greater than or equal to balanceBefore");
    }

    /// @notice Helper function to get liquidity from a position token
    /// @param tokenId_ The token ID of the position
    /// @return liquidity The liquidity of the position
    function _getLiquidity(uint256 tokenId_) private view returns (uint128 liquidity) {
        // INonfungiblePositionManager.positions(tokenId) selector: 0x99fbab88
        // 0x99fbab88 = bytes4(keccak256("positions(uint256)"))
        bytes memory returnData = _NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_)
        );

        // positions returns (
        //    uint96 nonce,                    // offset 0
        //    address operator,                // offset 1
        //    address token0,                  // offset 2
        //    address token1,                  // offset 3
        //    int24 tickSpacing,               // offset 4
        //    int24 tickLower,                 // offset 5
        //    int24 tickUpper,                 // offset 6
        //    uint128 liquidity,               // offset 7
        //    ... )
        // All types are padded to 32 bytes in ABI encoding.

        if (returnData.length < 256) revert InvalidReturnData();

        assembly {
            // returnData is a pointer to bytes array in memory.
            // First 32 bytes at returnData is the length of the array.
            // The actual data starts at returnData + 32.

            // liquidity is at index 7: 32 (length) + 32 * 7 = 256
            // liquidity is uint128, so we need to mask the upper bits
            // mload loads 32 bytes, but liquidity is only 128 bits (16 bytes)
            // We need to mask to get only the lower 128 bits: 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
            let liquidityValue := mload(add(returnData, 256))
            liquidity := and(liquidityValue, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    function testShouldReturnWhenEnteringWithZeroTokenId() public {
        // given
        AreodromeSlipstreamCLGaugeFuseEnterData memory stakeParams = AreodromeSlipstreamCLGaugeFuseEnterData({
            gaugeAddress: _AREODROME_GAUGE,
            tokenId: 0
        });

        FuseAction[] memory stakeCalls = new FuseAction[](1);
        stakeCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", stakeParams)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(stakeCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenEnteringWithUnsupportedGauge() public {
        // given
        address unsupportedGauge = address(0x1234567890123456789012345678901234567890);
        AreodromeSlipstreamCLGaugeFuseEnterData memory stakeParams = AreodromeSlipstreamCLGaugeFuseEnterData({
            gaugeAddress: unsupportedGauge,
            tokenId: 123
        });

        FuseAction[] memory stakeCalls = new FuseAction[](1);
        stakeCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", stakeParams)
        );

        bytes memory errorData = abi.encodeWithSelector(
            AreodromeSlipstreamCLGaugeFuse.AreodromeSlipstreamCLGaugeFuseUnsupportedGauge.selector,
            unsupportedGauge
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(errorData);
        _plasmaVault.execute(stakeCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingWithUnsupportedGauge() public {
        // given
        address unsupportedGauge = address(0x1234567890123456789012345678901234567890);
        AreodromeSlipstreamCLGaugeFuseExitData memory unstakeParams = AreodromeSlipstreamCLGaugeFuseExitData({
            gaugeAddress: unsupportedGauge,
            tokenId: 123
        });

        FuseAction[] memory unstakeCalls = new FuseAction[](1);
        unstakeCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", unstakeParams)
        );

        bytes memory errorData = abi.encodeWithSelector(
            AreodromeSlipstreamCLGaugeFuse.AreodromeSlipstreamCLGaugeFuseUnsupportedGauge.selector,
            unsupportedGauge
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(errorData);
        _plasmaVault.execute(unstakeCalls);
        vm.stopPrank();
    }

    function testShouldReturnWhenCollectingWithEmptyTokenIds() public {
        // given
        uint256[] memory tokenIds = new uint256[](0);
        AreodromeSlipstreamCollectFuseEnterData memory collectParams = AreodromeSlipstreamCollectFuseEnterData({
            tokenIds: tokenIds
        });

        FuseAction[] memory collectCalls = new FuseAction[](1);
        collectCalls[0] = FuseAction(
            address(_areodromeSlipstreamCollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectParams)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(collectCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenDeployingModifyPositionFuseWithZeroAddress() public {
        vm.expectRevert(AreodromeSlipstreamModifyPositionFuse.InvalidAddress.selector);
        new AreodromeSlipstreamModifyPositionFuse(IporFusionMarkets.AREODROME_SLIPSTREAM, address(0));
    }

    function testShouldRevertWhenDeployingNewPositionFuseWithZeroAddress() public {
        vm.expectRevert(AreodromeSlipstreamNewPositionFuse.InvalidAddress.selector);
        new AreodromeSlipstreamNewPositionFuse(IporFusionMarkets.AREODROME_SLIPSTREAM, address(0));
    }

    function testShouldRevertWhenEnteringNewPositionWithUnsupportedPool() public {
        // given
        AreodromeSlipstreamNewPositionFuseEnterData memory mintParams = AreodromeSlipstreamNewPositionFuseEnterData({
            token0: address(0x1),
            token1: address(0x2),
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

        address expectedPool = AreodromeSlipstreamSubstrateLib.getPoolAddress(
            INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).factory(),
            address(0x1),
            address(0x2),
            100
        );

        bytes memory errorData = abi.encodeWithSelector(
            AreodromeSlipstreamNewPositionFuse.AreodromeSlipstreamNewPositionFuseUnsupportedPool.selector,
            expectedPool
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(errorData);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldBurnPosition() public {
        test_shouldCollectFromNFTPosition();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        uint128 liquidity = _getLiquidity(tokenId);

        // 1. Decrease remaining liquidity to 0
        AreodromeSlipstreamModifyPositionFuseExitData
            memory modifyParams = AreodromeSlipstreamModifyPositionFuseExitData({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });

        FuseAction[] memory modifyCalls = new FuseAction[](1);
        modifyCalls[0] = FuseAction(
            address(_areodromeSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", modifyParams)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();

        // 2. Collect remaining fees (if any generated during decrease)
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

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(collectCalls);
        vm.stopPrank();

        // 3. Burn position
        AreodromeSlipstreamNewPositionFuseExitData memory burnParams = AreodromeSlipstreamNewPositionFuseExitData({
            tokenIds: tokenIds
        });

        FuseAction[] memory burnCalls = new FuseAction[](1);
        burnCalls[0] = FuseAction(
            address(_areodromeSlipstreamNewPositionFuse),
            abi.encodeWithSignature("exit((uint256[]))", burnParams)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(burnCalls);
        vm.stopPrank();

        // then
        // Check that token is burned (owner should be 0 or revert)
        vm.expectRevert("ERC721: owner query for nonexistent token");
        INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).ownerOf(tokenId);
    }

    function testShouldRevertWhenEnteringModifyPositionWithUnsupportedPool() public {
        test_shouldCollectFeesFromNFTPositions(); // This sets up a position

        // Grant new substrates without the pool (this revokes old ones and grants new)
        bytes32[] memory newSubstrates = new bytes32[](1);
        newSubstrates[0] = AreodromeSlipstreamSubstrateLib.substrateToBytes32(
            AreodromeSlipstreamSubstrate({
                substrateType: AreodromeSlipstreamSubstrateType.Gauge,
                substrateAddress: _AREODROME_GAUGE
            })
        );

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.AREODROME_SLIPSTREAM, newSubstrates);
        vm.stopPrank();

        // Try to modify existing position (which uses the pool that's no longer granted)
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

        bytes memory errorData = abi.encodeWithSelector(
            AreodromeSlipstreamModifyPositionFuse.AreodromeSlipstreamModifyPositionFuseUnsupportedPool.selector,
            _AREODROME_POOL
        );

        vm.startPrank(_ALPHA);
        vm.expectRevert(errorData);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();
    }
}
