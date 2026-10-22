// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {
    AreodromeSlipstreamCollectFuse,
    AreodromeSlipstreamCollectFuseEnterData
} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamCollectFuse.sol";
import {
    AreodromeSlipstreamNewPositionFuse,
    AreodromeSlipstreamNewPositionFuseEnterData,
    AreodromeSlipstreamNewPositionFuseExitData
} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamNewPositionFuse.sol";
import {
    AreodromeSlipstreamModifyPositionFuse,
    AreodromeSlipstreamModifyPositionFuseEnterData,
    AreodromeSlipstreamModifyPositionFuseExitData
} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamModifyPositionFuse.sol";
import {
    AreodromeSlipstreamCLGaugeFuse,
    AreodromeSlipstreamCLGaugeFuseEnterData,
    AreodromeSlipstreamCLGaugeFuseExitData
} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamCLGaugeFuse.sol";
import {AreodromeSlipstreamBalanceFuse} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamBalanceFuse.sol";
import {
    AreodromeSlipstreamSubstrateLib,
    AreodromeSlipstreamSubstrateType,
    AreodromeSlipstreamSubstrate,
    PoolNotDeployed
} from "../../../contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamLib.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {ContextManager} from "../../../contracts/managers/context/ContextManager.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {INonfungiblePositionManager} from "../../../contracts/fuses/aerodrome_slipstream/ext/INonfungiblePositionManager.sol";
import {ICLGauge} from "../../../contracts/fuses/aerodrome_slipstream/ext/ICLGauge.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {AreodromeSlipstreamGaugeClaimFuse} from "../../../contracts/rewards_fuses/areodrome_slipstream/AreodromeSlipstreamGaugeClaimFuse.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {
    TransientStorageSetInputsFuse,
    TransientStorageSetInputsFuseEnterData
} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TickMath} from "../../../contracts/fuses/uniswap/ext/TickMath.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {ICLPool} from "../../../contracts/fuses/aerodrome_slipstream/ext/ICLPool.sol";
import {ISlipstreamSugar} from "../../../contracts/fuses/aerodrome_slipstream/ext/ISlipstreamSugar.sol";

/// @dev Minimal interface for the Slipstream CL pool's `swap`, used only by the IL-7959 regression
/// tests to manipulate the pool's spot price with a direct, single-transaction swap (the same
/// mechanism a flash-loan attacker would use). Not used by the fuse under test.
interface ICLPoolSwapLike {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

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
    TransientStorageSetInputsFuse private _transientStorageSetInputsFuse;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 33796435);

        FusionFactory fusionFactory = FusionFactory(_fusionFactory);

        // Upgrade factory to new implementation
        FusionFactory newImplementation = new FusionFactory();
        address admin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);
        vm.prank(admin);
        fusionFactory.upgradeToAndCall(address(newImplementation), "");

        address plasmaVaultBase = address(new PlasmaVaultBase());

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = fusionFactory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());

        address factoryAdmin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(factoryAdmin);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), factoryAdmin);
        fusionFactory.updateFactoryAddresses(1000, factoryAddresses);
        fusionFactory.updatePlasmaVaultBase(plasmaVaultBase);

        // Deploy all base addresses for cloning
        address plasmaVaultCoreBase = address(new PlasmaVault());
        address accessManagerBase = address(new IporFusionAccessManager(factoryAdmin, 0));
        address priceOracleMiddleware = fusionFactory.getPriceOracleMiddleware();
        address priceManagerBase = address(new PriceOracleMiddlewareManager(factoryAdmin, priceOracleMiddleware));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address rewardsManagerBase = address(new RewardsClaimManager(accessManagerBase, plasmaVaultCoreBase));
        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = plasmaVaultCoreBase;
        address contextManagerBase = address(new ContextManager(accessManagerBase, approvedTargets));
        fusionFactory.updateBaseAddresses(
            1001,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
        vm.stopPrank();

        // Setup fee packages before creating vault
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.clone(
            "AreodromeSlipstream",
            "VSS",
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
        _transientStorageSetInputsFuse = new TransientStorageSetInputsFuse();

        // Setup fuses
        address[] memory fuses = new address[](5);
        fuses[0] = address(_areodromeSlipstreamNewPositionFuse);
        fuses[1] = address(_areodromeSlipstreamModifyPositionFuse);
        fuses[2] = address(_areodromeSlipstreamCLGaugeFuse);
        fuses[3] = address(_areodromeSlipstreamCollectFuse);
        fuses[4] = address(_transientStorageSetInputsFuse);

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

    /// @notice Regression test for IL-7958: staking a position to the gauge must not change
    /// market/vault NAV. Before the fix, the Pool branch kept counting the staked NFT's
    /// principal (it never checks custody) while the Gauge branch independently added it again
    /// via stakedValues, roughly doubling the market balance.
    function test_shouldNotChangeMarketBalanceWhenStakingToGauge() public {
        test_shouldCollectFromNFTPosition();

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

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(stakeCalls);
        vm.stopPrank();

        // then
        uint256[] memory stakedValues = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));
        assertEq(stakedValues[0], tokenId, "stakedValues[0] should be equal to tokenId");

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();

        assertApproxEqRel(
            marketBalanceAfter,
            marketBalanceBefore,
            1e15, // 0.1% tolerance for residual tokensOwed no longer counted while staked
            "market balance must not roughly double when a position is staked to the gauge"
        );
        assertApproxEqRel(
            totalAssetsAfter,
            totalAssetsBefore,
            1e15,
            "vault totalAssets must not roughly double when a position is staked to the gauge"
        );
    }

    /// @notice Regression test for IL-7958: unstaking a position from the gauge must not change
    /// market/vault NAV either (position returns to being counted by the Pool branch alone).
    function test_shouldNotChangeMarketBalanceWhenUnstakingFromGauge() public {
        test_shouldNotChangeMarketBalanceWhenStakingToGauge();

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

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

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

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();

        assertApproxEqRel(
            marketBalanceAfter,
            marketBalanceBefore,
            1e15,
            "market balance must not roughly halve when a position is unstaked from the gauge"
        );
        assertApproxEqRel(
            totalAssetsAfter,
            totalAssetsBefore,
            1e15,
            "vault totalAssets must not roughly halve when a position is unstaked from the gauge"
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

    /// @notice Tests that deploying CollectFuse with zero address reverts
    /// @dev Verifies InvalidAddress error is thrown when nonfungiblePositionManager is zero address
    function testShouldRevertWhenDeployingCollectFuseWithZeroAddress() public {
        vm.expectRevert(AreodromeSlipstreamCollectFuse.InvalidAddress.selector);
        new AreodromeSlipstreamCollectFuse(IporFusionMarkets.AREODROME_SLIPSTREAM, address(0));
    }

    function testShouldRevertWhenEnteringNewPositionWithNonExistentPool() public {
        // given
        // Using fake token addresses that don't have a pool deployed
        address token0 = address(0x1);
        address token1 = address(0x2);
        int24 tickSpacing = 100;

        AreodromeSlipstreamNewPositionFuseEnterData memory mintParams = AreodromeSlipstreamNewPositionFuseEnterData({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
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

        // Expect PoolNotDeployed error since these fake tokens don't have a deployed pool
        bytes memory errorData = abi.encodeWithSelector(PoolNotDeployed.selector, token0, token1, tickSpacing);

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

    /// @notice Tests entering gauge using transient storage
    /// @dev Verifies that enterTransient() correctly reads inputs from transient storage and stakes NFT to gauge
    function testShouldEnterGaugeUsingTransientStorage() public {
        test_shouldCollectFromNFTPosition();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(_AREODROME_GAUGE);
        inputs[1] = TypeConversionLib.toBytes32(tokenId);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamCLGaugeFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Enter Transient
        calls[1] = FuseAction(address(_areodromeSlipstreamCLGaugeFuse), abi.encodeWithSignature("enterTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256[] memory stakedValues = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));
        assertEq(stakedValues[0], tokenId, "stakedValues[0] should be equal to tokenId");
    }

    /// @notice Tests exiting gauge using transient storage
    /// @dev Verifies that exitTransient() correctly reads inputs from transient storage and unstakes NFT from gauge
    function testShouldExitGaugeUsingTransientStorage() public {
        test_shouldStakeToGauge();

        // given
        uint256[] memory stakedValuesBefore = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));
        uint256 tokenId = stakedValuesBefore[0];

        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(_AREODROME_GAUGE);
        inputs[1] = TypeConversionLib.toBytes32(tokenId);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamCLGaugeFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Exit Transient
        calls[1] = FuseAction(address(_areodromeSlipstreamCLGaugeFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256[] memory stakedValuesAfter = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));
        assertEq(
            stakedValuesBefore.length - 1,
            stakedValuesAfter.length,
            "stakedValuesAfter should have one less element"
        );
    }

    /// @notice Tests collecting fees using transient storage
    /// @dev Verifies that enterTransient() correctly reads tokenIds from transient storage and collects fees
    function testShouldCollectFeesUsingTransientStorage() public {
        test_shouldDecreasePosition();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(uint256(1)); // length
        inputs[1] = TypeConversionLib.toBytes32(tokenId);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamCollectFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Enter Transient
        calls[1] = FuseAction(address(_areodromeSlipstreamCollectFuse), abi.encodeWithSignature("enterTransient()"));

        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 wethBalanceAfter = IERC20(_WETH).balanceOf(address(_plasmaVault));
        assertGe(
            wethBalanceAfter,
            wethBalanceBefore,
            "wethBalanceAfter should be greater than or equal to wethBalanceBefore"
        );
    }

    /// @notice Tests collecting fees with empty tokenIds array using transient storage
    /// @dev Verifies that enterTransient() handles empty array case correctly
    function testShouldReturnWhenCollectingWithEmptyTokenIdsUsingTransientStorage() public {
        // given
        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs (empty array - length = 0)
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(uint256(0)); // length = 0

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamCollectFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Enter Transient
        calls[1] = FuseAction(address(_areodromeSlipstreamCollectFuse), abi.encodeWithSignature("enterTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then - should not revert (empty array case)
    }

    /// @notice Tests increasing position liquidity using transient storage
    /// @dev Verifies that enterTransient() correctly reads all parameters from transient storage and increases liquidity
    function testShouldIncreasePositionUsingTransientStorage() public {
        test_shouldCollectFeesFromNFTPositions();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](8);
        inputs[0] = TypeConversionLib.toBytes32(_WETH);
        inputs[1] = TypeConversionLib.toBytes32(_USDC);
        inputs[2] = TypeConversionLib.toBytes32(tokenId);
        inputs[3] = TypeConversionLib.toBytes32(uint256(100e18));
        inputs[4] = TypeConversionLib.toBytes32(uint256(10_00e6));
        inputs[5] = TypeConversionLib.toBytes32(uint256(0));
        inputs[6] = TypeConversionLib.toBytes32(uint256(0));
        inputs[7] = TypeConversionLib.toBytes32(uint256(block.timestamp + 100));

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamModifyPositionFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Enter Transient
        calls[1] = FuseAction(
            address(_areodromeSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("enterTransient()")
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        assertGt(
            marketBalanceAfter,
            marketBalanceBefore,
            "marketBalanceAfter should be greater than marketBalanceBefore"
        );
    }

    /// @notice Tests decreasing position liquidity using transient storage
    /// @dev Verifies that exitTransient() correctly reads all parameters from transient storage and decreases liquidity
    function testShouldDecreasePositionUsingTransientStorage() public {
        test_shouldCreateSecondPosition();

        // given
        uint256 tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        uint128 liquidityBefore = _getLiquidity(tokenId);
        uint256 wethBalanceBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));

        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](5);
        inputs[0] = TypeConversionLib.toBytes32(tokenId);
        inputs[1] = TypeConversionLib.toBytes32(uint256(liquidityBefore / 4));
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        inputs[3] = TypeConversionLib.toBytes32(uint256(0));
        inputs[4] = TypeConversionLib.toBytes32(uint256(block.timestamp + 100));

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamModifyPositionFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Exit Transient
        calls[1] = FuseAction(
            address(_areodromeSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("exitTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint128 liquidityAfter = _getLiquidity(tokenId);
        uint256 wethBalanceAfter = IERC20(_WETH).balanceOf(address(_plasmaVault));

        assertLt(liquidityAfter, liquidityBefore, "liquidityAfter should be less than liquidityBefore");
        assertGe(
            wethBalanceAfter,
            wethBalanceBefore,
            "wethBalanceAfter should be greater than or equal to wethBalanceBefore"
        );
    }

    /// @notice Tests creating new NFT position using transient storage
    /// @dev Verifies that enterTransient() correctly reads all parameters from transient storage and mints new position
    function testShouldCreateNewPositionUsingTransientStorage() public {
        // given
        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](11);
        inputs[0] = TypeConversionLib.toBytes32(_WETH);
        inputs[1] = TypeConversionLib.toBytes32(_USDC);
        inputs[2] = TypeConversionLib.toBytes32(uint256(int256(int24(100))));
        inputs[3] = TypeConversionLib.toBytes32(uint256(int256(int24(100))));
        inputs[4] = TypeConversionLib.toBytes32(uint256(int256(int24(300))));
        inputs[5] = TypeConversionLib.toBytes32(uint256(10e18));
        inputs[6] = TypeConversionLib.toBytes32(uint256(1_000e6));
        inputs[7] = TypeConversionLib.toBytes32(uint256(0));
        inputs[8] = TypeConversionLib.toBytes32(uint256(0));
        inputs[9] = TypeConversionLib.toBytes32(uint256(block.timestamp + 100));
        inputs[10] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamNewPositionFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Enter Transient
        calls[1] = FuseAction(
            address(_areodromeSlipstreamNewPositionFuse),
            abi.encodeWithSignature("enterTransient()")
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        assertGt(
            marketBalanceAfter,
            marketBalanceBefore,
            "marketBalanceAfter should be greater than marketBalanceBefore"
        );

        uint256 nft = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );
        assertTrue(nft > 0, "nft should be greater than 0");
    }

    /// @notice Tests burning NFT position using transient storage
    /// @dev Verifies that exitTransient() correctly reads tokenIds from transient storage and burns positions
    function testShouldBurnPositionUsingTransientStorage() public {
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

        // 3. Burn position using transient storage
        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(uint256(1)); // length
        inputs[1] = TypeConversionLib.toBytes32(tokenId);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamNewPositionFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Exit Transient
        calls[1] = FuseAction(address(_areodromeSlipstreamNewPositionFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        // Check that token is burned (owner should be 0 or revert)
        vm.expectRevert("ERC721: owner query for nonexistent token");
        INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).ownerOf(tokenId);
    }

    /// @notice Tests burning positions with empty tokenIds array using transient storage
    /// @dev Verifies that exitTransient() handles empty array case correctly
    function testShouldReturnWhenBurningWithEmptyTokenIdsUsingTransientStorage() public {
        // given
        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs (empty array - length = 0)
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(uint256(0)); // length = 0

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_areodromeSlipstreamNewPositionFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Exit Transient
        calls[1] = FuseAction(address(_areodromeSlipstreamNewPositionFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then - should not revert (empty array case)
    }

    /// @notice Tests burning positions with empty tokenIds array
    /// @dev Verifies that exit() handles empty array case correctly
    function testShouldReturnWhenBurningWithEmptyTokenIds() public {
        // given
        AreodromeSlipstreamNewPositionFuseExitData memory burnParams = AreodromeSlipstreamNewPositionFuseExitData({
            tokenIds: new uint256[](0)
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

        // then - should not revert (empty array case)
    }

    // ---------------------------------------------------------------------------------------
    // IL-7959 regression tests: the balance fuse must derive the token0/token1 composition of a
    // position from oracle prices, not from the pool's manipulable slot0().sqrtPriceX96. Before the
    // fix, pushing the pool spot price past a position's range edge collapsed its computed
    // composition to a single token while the resulting leg was still priced at the (unmoved,
    // unmanipulated) oracle price, inflating the market's reported NAV.
    // ---------------------------------------------------------------------------------------

    /// @dev Mints a wide, genuinely in-range WETH/USDC position so that a subsequent swap can push
    /// the pool spot price fully past the position's upper range edge (fully out-of-range), which is
    /// the state the finding's PoC exploits. The pool's tick at the fork block is -194361 (tickSpacing
    /// 100); the range below is chosen to straddle it with a wide margin on both sides.
    function _mintWideInRangePosition() internal returns (uint256 tokenId) {
        AreodromeSlipstreamNewPositionFuseEnterData memory mintParams = AreodromeSlipstreamNewPositionFuseEnterData({
            token0: _WETH,
            token1: _USDC,
            tickSpacing: 100,
            tickLower: -201400,
            tickUpper: -187300,
            amount0Desired: 10e18,
            amount1Desired: 30_000e6,
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

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        tokenId = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );
    }

    /// @dev Pushes the Aerodrome pool's spot price with a direct, single-transaction swap against the
    /// live pool - the same mechanism a flash-loan attacker would use (only capital is required, no
    /// privileged role). `targetTick_` is where the swap's price limit is set; the swap consumes as
    /// much of the input token as needed (up to the huge `amountSpecified` below) until either that
    /// price limit is hit or the amount is exhausted.
    function _pushAerodromePoolSpotToTick(bool zeroForOne_, int24 targetTick_) internal {
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(targetTick_);

        if (zeroForOne_) {
            deal(_WETH, address(this), 1_000_000_000e18);
        } else {
            deal(_USDC, address(this), 1_000_000_000e6);
        }

        ICLPoolSwapLike(_AREODROME_POOL).swap(
            address(this),
            zeroForOne_,
            type(int256).max / 2,
            sqrtPriceLimitX96,
            abi.encode(_WETH, _USDC)
        );
    }

    /// @dev `totalAssetsInMarket`/`totalAssets` read the vault's cached per-market NAV, which is only
    /// refreshed by `_updateMarketsBalances` inside `execute()`/`withdraw()`/`redeem()` (see
    /// PlasmaVault.sol). A pool-spot manipulation is therefore only observable in NAV once some action
    /// touching the market runs; this issues a harmless no-op call (exit with an empty tokenIds array)
    /// through a fuse on the AREODROME_SLIPSTREAM market purely to trigger that refresh, mirroring the
    /// real attack path (an ordinary withdrawal, or the ALPHA's post-batch refresh, does the same).
    function _refreshAreodromeSlipstreamMarket() internal {
        AreodromeSlipstreamNewPositionFuseExitData memory noopExit = AreodromeSlipstreamNewPositionFuseExitData({
            tokenIds: new uint256[](0)
        });

        FuseAction[] memory refreshCalls = new FuseAction[](1);
        refreshCalls[0] = FuseAction(
            address(_areodromeSlipstreamNewPositionFuse),
            abi.encodeWithSignature("exit((uint256[]))", noopExit)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(refreshCalls);
        vm.stopPrank();
    }

    /// @dev Slipstream CL pools use the standard Uniswap V3 swap callback to pull payment for the
    /// swap. Only used by the manipulation helper above.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address token0_, address token1_) = abi.decode(data, (address, address));
        if (amount0Delta > 0) {
            IERC20(token0_).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(token1_).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    /// @notice Regression test for IL-7959 (Pool branch): pushing the pool's spot price past a
    /// position's upper range edge must not change the reported market/vault NAV. Before the fix,
    /// the Pool branch read `ICLPool.slot0().sqrtPriceX96` directly, so the manipulated spot collapsed
    /// the position's computed composition to 100% USDC while that leg was still priced at the
    /// unmoved oracle WETH/USDC price, inflating NAV.
    function test_shouldNotInflateMarketBalanceWhenPoolSpotPushedToRangeEdge() public {
        _mintWideInRangePosition();

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        // when: push the pool spot well past the position's upper range edge (-187300) with a
        // single-transaction swap
        _pushAerodromePoolSpotToTick(false, -186800);
        _refreshAreodromeSlipstreamMarket();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();

        assertApproxEqRel(
            marketBalanceAfter,
            marketBalanceBefore,
            1e15, // 0.1% tolerance
            "market balance must not change when the pool spot is pushed past the position's range edge"
        );
        assertApproxEqRel(
            totalAssetsAfter,
            totalAssetsBefore,
            1e15,
            "vault totalAssets must not change when the pool spot is pushed past the position's range edge"
        );
    }

    /// @notice Regression test for IL-7959 (Gauge branch): the Gauge branch reads
    /// `ICLGauge.pool().slot0().sqrtPriceX96`, which is equally manipulable. Staking the position
    /// into the gauge first moves valuation to the Gauge branch; the manipulated pool spot must still
    /// not change the reported market/vault NAV.
    function test_shouldNotInflateMarketBalanceWhenGaugePoolSpotManipulated() public {
        uint256 tokenId = _mintWideInRangePosition();

        AreodromeSlipstreamCLGaugeFuseEnterData memory stakeParams = AreodromeSlipstreamCLGaugeFuseEnterData({
            gaugeAddress: _AREODROME_GAUGE,
            tokenId: tokenId
        });

        FuseAction[] memory stakeCalls = new FuseAction[](1);
        stakeCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", stakeParams)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(stakeCalls);
        vm.stopPrank();

        uint256[] memory stakedValues = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));
        assertEq(stakedValues[0], tokenId, "stakedValues[0] should be equal to tokenId");

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        // when: push the pool spot well past the position's upper range edge with a single-transaction
        // swap; the gauge's `pool()` returns the same manipulated pool
        _pushAerodromePoolSpotToTick(false, -186800);
        _refreshAreodromeSlipstreamMarket();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AREODROME_SLIPSTREAM
        );
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();

        assertApproxEqRel(
            marketBalanceAfter,
            marketBalanceBefore,
            1e15, // 0.1% tolerance
            "market balance must not change when the staked position's pool spot is manipulated"
        );
        assertApproxEqRel(
            totalAssetsAfter,
            totalAssetsBefore,
            1e15,
            "vault totalAssets must not change when the staked position's pool spot is manipulated"
        );
    }

    /// @notice Sanity check for IL-7959: at the pool's true (unmanipulated) price, the oracle-implied
    /// valuation used post-fix must be close to what the old spot-derived valuation would have been.
    /// This proves the fix does not distort normal NAV reporting when nothing is being manipulated -
    /// only healthy inputs (an untouched pool, a freshly-minted in-range position) are exercised.
    function test_oracleImpliedValuationMatchesSpotValuationAtHealthyPrice() public {
        _mintWideInRangePosition();

        // The pool's spot price has not been touched; the fix's oracle-implied sqrtPriceX96 should
        // value the (unmanipulated) position within a small tolerance of the pre-fix spot-derived
        // valuation, since the fork's oracle price tracks the pool's real market price closely.
        // `totalAssetsInMarket` is denominated in the vault's underlying asset (USDC, 6 decimals), not
        // WAD; normalize to WAD before comparing against the WAD-normalized calc below.
        uint256 marketBalanceWad = IporMath.convertToWad(
            PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AREODROME_SLIPSTREAM),
            IERC20Metadata(_UNDERLYING_TOKEN).decimals()
        );

        assertGt(marketBalanceWad, 0, "market balance should be > 0 for a freshly minted in-range position");

        // Re-derive the composition using the pool's own (unmanipulated) live spot, mirroring the
        // pre-fix code path, and compare its USD value to the fix's oracle-implied valuation.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(
            address(_plasmaVault),
            0
        );

        uint160 spotSqrtPriceX96 = ICLPool(_AREODROME_POOL).slot0().sqrtPriceX96;
        (uint256 spotAmount0, uint256 spotAmount1) = ISlipstreamSugar(_SLIPSTREAM_SUPERCHAIN_VAULT).principal(
            INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER),
            tokenIds[0],
            spotSqrtPriceX96
        );

        (uint256 wethPrice, uint256 wethPriceDecimals) = _priceOracleMiddleware.getAssetPrice(_WETH);
        (uint256 usdcPrice, uint256 usdcPriceDecimals) = _priceOracleMiddleware.getAssetPrice(_USDC);

        uint256 spotValueUsd = IporMath.convertToWad(spotAmount0 * wethPrice, 18 + wethPriceDecimals) +
            IporMath.convertToWad(spotAmount1 * usdcPrice, 6 + usdcPriceDecimals);

        assertApproxEqRel(
            marketBalanceWad,
            spotValueUsd,
            1e14, // 0.01% tolerance - measured drift on this fork block is ~0.00015%, so this bound
            // keeps ~66x margin while still catching a several-hundred-bp mispricing regression
            "oracle-implied valuation should match the healthy spot-derived valuation closely"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // IL-8752 (#17) / IL-8747 (#12): action fuses must only touch NFTs from the vault's tracked list
    // ---------------------------------------------------------------------------------------------

    /// @dev Mints an Aerodrome WETH/USDC position straight on the real NPM (outside the vault's fuses) for the
    /// given recipient. ALPHA pays with its own tokens, so the NFT is not in the vault's tracked list.
    function _mintUntrackedNft(address recipient_) internal returns (uint256 tokenId) {
        deal(_WETH, _ALPHA, 1e18);
        deal(_USDC, _ALPHA, 3_000e6);

        vm.startPrank(_ALPHA);
        IERC20(_WETH).approve(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
        IERC20(_USDC).approve(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
        (tokenId, , , ) = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: _WETH,
                token1: _USDC,
                tickSpacing: 100,
                tickLower: -201400,
                tickUpper: -187300,
                amount0Desired: 0.1e18,
                amount1Desired: 300e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient_,
                deadline: block.timestamp + 100,
                sqrtPriceX96: 0
            })
        );
        vm.stopPrank();
    }

    /// @notice Port of PoC 4b72df7f: ALPHA mints its own NFT and tries to pour the vault's idle tokens into it
    function testShouldRevertWhenIncreasingLiquidityOfNonVaultNft() public {
        // given
        uint256 attackerTokenId = _mintUntrackedNft(_ALPHA);
        assertEq(
            INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).ownerOf(attackerTokenId),
            _ALPHA,
            "ALPHA owns the NFT"
        );

        uint256 vaultWethBefore = IERC20(_WETH).balanceOf(address(_plasmaVault));
        uint256 vaultUsdcBefore = IERC20(_USDC).balanceOf(address(_plasmaVault));

        AreodromeSlipstreamModifyPositionFuseEnterData
            memory modifyParams = AreodromeSlipstreamModifyPositionFuseEnterData({
                token0: _WETH,
                token1: _USDC,
                tokenId: attackerTokenId,
                amount0Desired: 10e18,
                amount1Desired: 30_000e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_areodromeSlipstreamModifyPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256))",
                modifyParams
            )
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                AreodromeSlipstreamModifyPositionFuse.AreodromeSlipstreamModifyPositionFuseTokenIdNotTracked.selector,
                attackerTokenId
            )
        );
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        assertEq(IERC20(_WETH).balanceOf(address(_plasmaVault)), vaultWethBefore, "vault WETH unchanged");
        assertEq(IERC20(_USDC).balanceOf(address(_plasmaVault)), vaultUsdcBefore, "vault USDC unchanged");
    }

    /// @notice An NFT donated to the vault is owned by it but not tracked, so liquidity cannot be decreased
    function testShouldRevertWhenDecreasingUntrackedNft() public {
        // given
        uint256 donatedTokenId = _mintUntrackedNft(address(_plasmaVault));
        uint128 liquidity = _getLiquidity(donatedTokenId);

        AreodromeSlipstreamModifyPositionFuseExitData
            memory modifyParams = AreodromeSlipstreamModifyPositionFuseExitData({
                tokenId: donatedTokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_areodromeSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", modifyParams)
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                AreodromeSlipstreamModifyPositionFuse.AreodromeSlipstreamModifyPositionFuseTokenIdNotTracked.selector,
                donatedTokenId
            )
        );
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        assertEq(_getLiquidity(donatedTokenId), liquidity, "liquidity untouched");
    }

    /// @notice Pins the NatSpec promise of the gauge fuse: an NFT staked by an older gauge fuse (so not in the
    /// tracked list) can always be unstaked, and Modify stays closed for it.
    function testShouldUnstakeUntrackedNftFromGaugeAndKeepModifyClosed() public {
        // given
        uint256 untrackedTokenId = _mintUntrackedNft(address(_plasmaVault));

        // simulates an older gauge fuse that staked without the tracked-list check
        vm.startPrank(address(_plasmaVault));
        INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).approve(_AREODROME_GAUGE, untrackedTokenId);
        ICLGauge(_AREODROME_GAUGE).deposit(untrackedTokenId);
        vm.stopPrank();

        uint256[] memory stakedBefore = ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault));
        assertEq(stakedBefore.length, 1, "NFT staked");
        assertEq(stakedBefore[0], untrackedTokenId, "staked NFT is the untracked one");

        AreodromeSlipstreamCLGaugeFuseExitData memory exitParams = AreodromeSlipstreamCLGaugeFuseExitData({
            gaugeAddress: _AREODROME_GAUGE,
            tokenId: untrackedTokenId
        });
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(_areodromeSlipstreamCLGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", exitParams)
        );

        // when
        vm.prank(_ALPHA);
        _plasmaVault.execute(exitCalls);

        // then
        assertEq(
            INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).ownerOf(untrackedTokenId),
            address(_plasmaVault),
            "NFT back in the vault"
        );
        assertEq(ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault)).length, 0, "nothing staked");

        // and the Modify fuse is still closed for it
        AreodromeSlipstreamModifyPositionFuseExitData
            memory decreaseParams = AreodromeSlipstreamModifyPositionFuseExitData({
                tokenId: untrackedTokenId,
                liquidity: 1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });
        FuseAction[] memory decreaseCalls = new FuseAction[](1);
        decreaseCalls[0] = FuseAction(
            address(_areodromeSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", decreaseParams)
        );
        vm.prank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                AreodromeSlipstreamModifyPositionFuse.AreodromeSlipstreamModifyPositionFuseTokenIdNotTracked.selector,
                untrackedTokenId
            )
        );
        _plasmaVault.execute(decreaseCalls);
    }

    /// @notice Port of PoC 10f74130 on the real gauge: a donated NFT must not be stakeable (NAV toggle)
    function testShouldRevertWhenStakingUntrackedNftToGauge() public {
        // given
        uint256 donatedTokenId = _mintUntrackedNft(address(_plasmaVault));
        uint256 marketBalanceBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AREODROME_SLIPSTREAM);

        AreodromeSlipstreamCLGaugeFuseEnterData memory stakeParams = AreodromeSlipstreamCLGaugeFuseEnterData({
            gaugeAddress: _AREODROME_GAUGE,
            tokenId: donatedTokenId
        });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_areodromeSlipstreamCLGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", stakeParams)
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                AreodromeSlipstreamCLGaugeFuse.AreodromeSlipstreamCLGaugeFuseTokenIdNotTracked.selector,
                donatedTokenId
            )
        );
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        assertEq(
            INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).ownerOf(donatedTokenId),
            address(_plasmaVault),
            "NFT stays in the vault"
        );
        assertEq(ICLGauge(_AREODROME_GAUGE).stakedValues(address(_plasmaVault)).length, 0, "nothing staked");
        assertEq(
            _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AREODROME_SLIPSTREAM),
            marketBalanceBefore,
            "market balance unchanged"
        );
    }

    /// @notice Regression test for IL-8789/IL-8795: a granted pool whose oracle-implied raw price
    /// P = token1/token0 is >= 2^64 (but < 2^128, still inside Q64.96) must not make the market balance
    /// refresh revert. Before the fix `_oracleSqrtPriceX96` overflowed in `mulDiv` for such a pool,
    /// which is evaluated for every Pool/Gauge substrate, blocking the whole market.
    function test_shouldNotRevertWhenOracleImpliedPriceAbove2Pow64() public {
        address oracle = _plasmaVaultGovernance.getPriceOracleMiddleware();
        address token0 = ICLPool(_AREODROME_POOL).token0();
        address token1 = ICLPool(_AREODROME_POOL).token1();

        // P = p0 * 10^t1 / (p1 * 10^t0) with p1 = 1, p0 = 10^(t0 + 25 - t1) and zero price decimals => P = 1e25
        // (2^64 ~ 1.8e19 < 1e25 < 2^128 ~ 3.4e38)
        uint256 token0Decimals = IERC20Metadata(token0).decimals();
        uint256 token1Decimals = IERC20Metadata(token1).decimals();
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("getAssetPrice(address)", token0),
            abi.encode(10 ** (token0Decimals + 25 - token1Decimals), uint256(0))
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("getAssetPrice(address)", token1),
            abi.encode(uint256(1), uint256(0))
        );

        // the vault holds no position in this pool: the refresh must pass and report an empty market
        _refreshAreodromeSlipstreamMarket();

        assertEq(
            _plasmaVault.totalAssetsInMarket(IporFusionMarkets.AREODROME_SLIPSTREAM),
            0,
            "market balance must be 0 for a granted pool without positions"
        );
    }
}
