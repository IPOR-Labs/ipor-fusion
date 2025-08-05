// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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
import {VelodromSuperchainSlipstreamCollectFuse, VelodromSuperchainSlipstreamCollectFuseEnterData} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromSuperchainSlipstreamCollectFuse.sol";
import {INonfungiblePositionManager} from "../../../contracts/fuses/velodrome_superchain_slipstream/ext/INonfungiblePositionManager.sol";
import {VelodromSuperchainSlipstreamNewPositionFuse, VelodromSuperchainSlipstreamNewPositionFuseEnterData} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromSuperchainSlipstreamNewPositionFuse.sol";
import {VelodromSuperchainSlipstreamModifyPositionFuse, VelodromSuperchainSlipstreamModifyPositionFuseEnterData, VelodromSuperchainSlipstreamModifyPositionFuseExitData} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromSuperchainSlipstreamModifyPositionFuse.sol";
import {VelodromSuperchainSlipstreamLeafCLGaugeFuse, VelodromSuperchainSlipstreamLeafCLGaugeFuseEnterData, VelodromSuperchainSlipstreamLeafCLGaugeFuseExitData} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromSuperchainSlipstreamLeafCLGaugeFuse.sol";
import {VelodromSuperchainSlipstreamCollectFuse} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromSuperchainSlipstreamCollectFuse.sol";
import {VelodromSuperchainSlipstreamBalance} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromSuperchainSlipstreamBalance.sol";
import {VelodromSuperchainSlipstreamSubstrateLib, VelodromSuperchainSlipstreamSubstrateType, VelodromSuperchainSlipstreamSubstrate} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromSuperchainSlipstreamLib.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {INonfungiblePositionManager} from "../../../contracts/fuses/velodrome_superchain_slipstream/ext/INonfungiblePositionManager.sol";
import {ILeafCLGauge} from "../../../contracts/fuses/velodrome_superchain_slipstream/ext/ILeafCLGauge.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {VelodromSuperchainSlipstreamGaugeClaimFuse} from "../../../contracts/rewards_fuses/velodrome_superchain/VelodromSuperchainSlipstreamGaugeClaimFuse.sol";
import {ILeafGauge} from "../../../contracts/fuses/velodrome_superchain/ext/ILeafGauge.sol";

/// @title VelodromSuperchainSlipstreamTest
/// @notice Test suite for Velodrom Superchain Slipstream Collect Fuse
/// @dev Tests the collection of fees from Velodrom Superchain Slipstream NFT positions
contract VelodromSuperchainSlipstreamTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    // Test constants
    address private constant _USDTO = 0x0200C29006150606B650577BBE7B6248F58470c1;
    address private constant _USDCE = 0xF1815bd50389c46847f0Bda824eC8da914045D14;
    address private constant _UNDERLYING_TOKEN = _USDCE;
    string private constant _UNDERLYING_TOKEN_NAME = "USDCE";
    address private constant _USER = TestAddresses.USER;
    address private constant _ATOMIST = TestAddresses.ATOMIST;
    address private constant _FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant _ALPHA = TestAddresses.ALPHA;

    address private constant _fusionFactory = 0xEC53f69Bd1D991a2F99e96DE66E81D0E42A61D8D;
    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0x991d5546C4B442B4c5fdc4c8B8b8d131DEB24702;
    address private constant _SLIPSTREAM_SUPERCHAIN_VAULT = 0x222ed297aF0560030136AE652d39fa40E1B72818;

    address private constant _VELODROME_POOL = 0x317728bcCE5d1C2895b71b01eEBbB6989ae504aE;
    address private constant _VELODROME_GAUGE = 0x2C568357E5e4BEee207Ab46b5bA5C1196D0D5Ecf;

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    PriceOracleMiddlewareManager private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    RewardsClaimManager private _rewardsClaimManager;

    VelodromSuperchainSlipstreamNewPositionFuse private _velodromSuperchainSlipstreamNewPositionFuse;
    VelodromSuperchainSlipstreamModifyPositionFuse private _velodromSuperchainSlipstreamModifyPositionFuse;
    VelodromSuperchainSlipstreamLeafCLGaugeFuse private _velodromSuperchainSlipstreamLeafCLGaugeFuse;
    VelodromSuperchainSlipstreamCollectFuse private _velodromSuperchainSlipstreamCollectFuse;
    VelodromSuperchainSlipstreamBalance private _velodromSuperchainSlipstreamBalance;
    VelodromSuperchainSlipstreamGaugeClaimFuse private _velodromeGaugeClaimFuse;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("INK_PROVIDER_URL"), 20419547);

        FusionFactory fusionFactory = FusionFactory(_fusionFactory);

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = fusionFactory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());

        address factoryAdmin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(factoryAdmin);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), factoryAdmin);
        fusionFactory.updateFactoryAddresses(1000, factoryAddresses);
        vm.stopPrank();

        FusionFactoryLib.FusionInstance memory fusionInstance = fusionFactory.create(
            "VelodromSuperchainSlipstream",
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
        deal(_USDTO, _USER, 1_000_000e6);
        deal(_USDCE, _USER, 1_000_000e6);

        // Deploy VelodromSuperchainSlipstreamCollectFuse
        _velodromSuperchainSlipstreamNewPositionFuse = new VelodromSuperchainSlipstreamNewPositionFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _velodromSuperchainSlipstreamModifyPositionFuse = new VelodromSuperchainSlipstreamModifyPositionFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _velodromSuperchainSlipstreamLeafCLGaugeFuse = new VelodromSuperchainSlipstreamLeafCLGaugeFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        _velodromSuperchainSlipstreamCollectFuse = new VelodromSuperchainSlipstreamCollectFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _velodromSuperchainSlipstreamBalance = new VelodromSuperchainSlipstreamBalance(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            _NONFUNGIBLE_POSITION_MANAGER,
            _SLIPSTREAM_SUPERCHAIN_VAULT
        );

        _velodromeGaugeClaimFuse = new VelodromSuperchainSlipstreamGaugeClaimFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        // Setup fuses
        address[] memory fuses = new address[](4);
        fuses[0] = address(_velodromSuperchainSlipstreamNewPositionFuse);
        fuses[1] = address(_velodromSuperchainSlipstreamModifyPositionFuse);
        fuses[2] = address(_velodromSuperchainSlipstreamLeafCLGaugeFuse);
        fuses[3] = address(_velodromSuperchainSlipstreamCollectFuse);

        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = address(_velodromeGaugeClaimFuse);

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.addFuses(fuses);
        _rewardsClaimManager.addRewardFuses(rewardFuses);

        _plasmaVaultGovernance.addBalanceFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN,
            address(_velodromSuperchainSlipstreamBalance)
        );

        _plasmaVaultGovernance.addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        vm.stopPrank();

        // Setup market substrates
        bytes32[] memory velodromSubstrates = new bytes32[](2);
        velodromSubstrates[0] = VelodromSuperchainSlipstreamSubstrateLib.substrateToBytes32(
            VelodromSuperchainSlipstreamSubstrate({
                substrateType: VelodromSuperchainSlipstreamSubstrateType.Pool,
                substrateAddress: _VELODROME_POOL
            })
        );
        velodromSubstrates[1] = VelodromSuperchainSlipstreamSubstrateLib.substrateToBytes32(
            VelodromSuperchainSlipstreamSubstrate({
                substrateType: VelodromSuperchainSlipstreamSubstrateType.Gauge,
                substrateAddress: _VELODROME_GAUGE
            })
        );

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.VELODROME_SUPERCHAIN, velodromSubstrates);
        vm.stopPrank();

        // Setup price feeds
        address[] memory assets = new address[](2);
        assets[0] = _USDCE;
        assets[1] = _USDTO;

        address oneUsd = address(new USDPriceFeed());
        address[] memory sources = new address[](2);
        sources[0] = oneUsd;
        sources[1] = oneUsd;

        vm.startPrank(_ATOMIST);
        _priceOracleMiddleware.setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        bytes32[] memory erc20VaultBalanceSubstrates = new bytes32[](2);
        erc20VaultBalanceSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(_USDCE);
        erc20VaultBalanceSubstrates[1] = PlasmaVaultConfigLib.addressToBytes32(_USDTO);

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
        IERC20(_USDCE).approve(address(_plasmaVault), 100_000e6);
        _plasmaVault.deposit(100_000e6, _USER);
        IERC20(_USDTO).transfer(address(_plasmaVault), 100_000e6);
        vm.stopPrank();
    }

    // TODO: Add test functions here
    // Example test structure:
    function test_shouldCollectFeesFromNFTPositions() public {
        // given
        VelodromSuperchainSlipstreamNewPositionFuseEnterData
            memory mintParams = VelodromSuperchainSlipstreamNewPositionFuseEnterData({
                token0: _USDTO,
                token1: _USDCE,
                tickSpacing: 1,
                tickLower: 0,
                tickUpper: 101,
                amount0Desired: 1_000e6,
                amount1Desired: 1_000e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100,
                sqrtPriceX96: 0
            });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamNewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint160))",
                mintParams
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdceBalanceBefore = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceBefore = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdceBalanceAfter = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceAfter = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        uint256[] memory nfts = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
        assertTrue(nfts.length > 0, "nfts.length > 0");
    }

    function test_shouldCreateSecondPosition() public {
        test_shouldCollectFeesFromNFTPositions();

        // given
        VelodromSuperchainSlipstreamNewPositionFuseEnterData
            memory mintParams = VelodromSuperchainSlipstreamNewPositionFuseEnterData({
                token0: _USDTO,
                token1: _USDCE,
                tickSpacing: 1,
                tickLower: 100,
                tickUpper: 201,
                amount0Desired: 1_000e6,
                amount1Desired: 1_000e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100,
                sqrtPriceX96: 0
            });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamNewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint160))",
                mintParams
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdceBalanceBefore = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceBefore = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdceBalanceAfter = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceAfter = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        uint256[] memory nfts = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
        assertTrue(nfts.length > 1, "nfts.length > 1");
    }

    function test_shouldIncreasePosition() public {
        test_shouldCollectFeesFromNFTPositions();

        // given
        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        VelodromSuperchainSlipstreamModifyPositionFuseEnterData
            memory modifyParams = VelodromSuperchainSlipstreamModifyPositionFuseEnterData({
                token0: _USDTO,
                token1: _USDCE,
                tokenId: tokenIds[0],
                amount0Desired: 2_000e6,
                amount1Desired: 2_000e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });

        FuseAction[] memory modifyCalls = new FuseAction[](1);
        modifyCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamModifyPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256))",
                modifyParams
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdceBalanceBefore = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceBefore = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );
        uint256 usdceBalanceAfter = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceAfter = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
    }

    function test_shouldDecreasePosition() public {
        test_shouldCreateSecondPosition();

        // given
        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        (, , , , , , , uint128 liquidityBefore, , , , ) = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER)
            .positions(tokenIds[0]);

        VelodromSuperchainSlipstreamModifyPositionFuseExitData
            memory modifyParams = VelodromSuperchainSlipstreamModifyPositionFuseExitData({
                tokenId: tokenIds[0],
                liquidity: liquidityBefore / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });

        FuseAction[] memory modifyCalls = new FuseAction[](1);
        modifyCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamModifyPositionFuse),
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
            .positions(tokenIds[0]);

        assertGt(marketBalanceBefore, marketBalanceAfter, "marketBalanceBefore > marketBalanceAfter");
        assertGt(liquidityBefore, liquidityAfter, "liquidityBefore > liquidityAfter");
    }

    function test_shouldCollectFromNFTPosition() public {
        test_shouldDecreasePosition();

        // given
        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        VelodromSuperchainSlipstreamCollectFuseEnterData
            memory collectParams = VelodromSuperchainSlipstreamCollectFuseEnterData({tokenIds: tokenIds});

        FuseAction[] memory collectCalls = new FuseAction[](1);
        collectCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamCollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectParams)
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        uint256 usdceBalanceBefore = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceBefore = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(collectCalls);

        uint256 usdceBalanceAfter = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceAfter = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN
        );

        assertGt(usdceBalanceAfter, usdceBalanceBefore, "usdceBalanceAfter should be greater than usdceBalanceBefore");
        assertGt(usdtoBalanceAfter, usdtoBalanceBefore, "usdtoBalanceAfter should be greater than usdtoBalanceBefore");

        assertGt(
            marketBalanceBefore,
            marketBalanceAfter,
            "marketBalanceBefore should be greater than marketBalanceAfter"
        );
    }

    function test_shouldStakeToGauge() public {
        test_shouldCollectFromNFTPosition();

        // given
        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        VelodromSuperchainSlipstreamLeafCLGaugeFuseEnterData
            memory stakeParams = VelodromSuperchainSlipstreamLeafCLGaugeFuseEnterData({
                gaugeAddress: _VELODROME_GAUGE,
                tokenId: tokenIds[0]
            });

        FuseAction[] memory stakeCalls = new FuseAction[](1);
        stakeCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamLeafCLGaugeFuse),
            abi.encodeWithSignature("enter((address,uint256))", stakeParams)
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(stakeCalls);
        vm.stopPrank();

        uint256[] memory stakedValues = ILeafCLGauge(_VELODROME_GAUGE).stakedValues(address(_plasmaVault));

        assertEq(stakedValues[0], tokenIds[0], "stakedValues[0] should be equal to tokenIds[0]");
    }

    function test_shouldUnstakeFromGauge() public {
        test_shouldStakeToGauge();

        uint256[] memory stakedValues = ILeafCLGauge(_VELODROME_GAUGE).stakedValues(address(_plasmaVault));

        VelodromSuperchainSlipstreamLeafCLGaugeFuseExitData
            memory unstakeParams = VelodromSuperchainSlipstreamLeafCLGaugeFuseExitData({
                gaugeAddress: _VELODROME_GAUGE,
                tokenId: stakedValues[0]
            });

        FuseAction[] memory unstakeCalls = new FuseAction[](1);
        unstakeCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamLeafCLGaugeFuse),
            abi.encodeWithSignature("exit((address,uint256))", unstakeParams)
        );

        uint256[] memory tokenIdsBefore = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(unstakeCalls);
        vm.stopPrank();

        // then
        uint256[] memory stakedValuesAfter = ILeafCLGauge(_VELODROME_GAUGE).stakedValues(address(_plasmaVault));

        uint256[] memory tokenIdsAfter = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        assertEq(tokenIdsBefore.length + 1, tokenIdsAfter.length, "tokenIdsBefore should be equal to tokenIdsAfter");
    }

    function test_shouldClaimRewardsFromGauge() public {
        test_shouldStakeToGauge();

        vm.warp(block.timestamp + 3 days);

        address[] memory gauges = new address[](1);
        gauges[0] = _VELODROME_GAUGE;

        FuseAction[] memory claimCalls = new FuseAction[](1);
        claimCalls[0] = FuseAction(
            address(_velodromeGaugeClaimFuse),
            abi.encodeWithSignature("claim(address[])", gauges)
        );
        address rewardToken = ILeafGauge(_VELODROME_GAUGE).rewardToken();
        uint256 balanceBefore = IERC20(rewardToken).balanceOf(address(_rewardsClaimManager));

        // when
        vm.startPrank(_ALPHA);
        _rewardsClaimManager.claimRewards(claimCalls);
        vm.stopPrank();

        // then
        uint256 balanceAfter = IERC20(rewardToken).balanceOf(address(_rewardsClaimManager));

        assertGt(balanceAfter, balanceBefore, "balanceAfter should be greater than balanceBefore");
    }

    function test_test() public {
        address token0 = 0x73E0C0d45E048D25Fc26Fa3159b0aA04BfA4Db98;
        address token1 = 0xaE4EFbc7736f963982aACb17EFA37fCBAb924cB3;
        int24 tickSpacing = 1;

        address pool = VelodromSuperchainSlipstreamSubstrateLib.getPoolAddress(
            0x04625B046C69577EfC40e6c0Bb83CDBAfab5a55F,
            token0,
            token1,
            tickSpacing
        );

        console2.log("pool :", pool);
        console2.log("pool :", 0x3170b9355F1057F457FEdF4c8074946659Dc92D2);
    }
}
