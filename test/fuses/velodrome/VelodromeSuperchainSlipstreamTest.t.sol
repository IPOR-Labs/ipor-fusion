// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {VelodromeSuperchainSlipstreamBalanceFuse} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamBalanceFuse.sol";
import {VelodromeSuperchainSlipstreamCollectFuse, VelodromeSuperchainSlipstreamCollectFuseEnterData} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamCollectFuse.sol";
import {VelodromeSuperchainSlipstreamLeafCLGaugeFuse, VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData, VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamLeafCLGaugeFuse.sol";
import {VelodromeSuperchainSlipstreamModifyPositionFuse, VelodromeSuperchainSlipstreamModifyPositionFuseEnterData, VelodromeSuperchainSlipstreamModifyPositionFuseExitData} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamModifyPositionFuse.sol";
import {VelodromeSuperchainSlipstreamNewPositionFuse, VelodromeSuperchainSlipstreamNewPositionFuseEnterData} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamNewPositionFuse.sol";
import {VelodromeSuperchainSlipstreamSubstrateLib, VelodromeSuperchainSlipstreamSubstrateType, VelodromeSuperchainSlipstreamSubstrate} from "../../../contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamSubstrateLib.sol";
import {ILeafGauge} from "../../../contracts/fuses/velodrome_superchain/ext/ILeafGauge.sol";
import {ILeafCLGauge} from "../../../contracts/fuses/velodrome_superchain_slipstream/ext/ILeafCLGauge.sol";
import {INonfungiblePositionManager} from "../../../contracts/fuses/velodrome_superchain_slipstream/ext/INonfungiblePositionManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {VelodromeSuperchainSlipstreamGaugeClaimFuse} from "../../../contracts/rewards_fuses/velodrome_superchain/VelodromeSuperchainSlipstreamGaugeClaimFuse.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @title VelodromeSuperchainSlipstreamTest
/// @notice Test suite for Velodrom Superchain Slipstream Collect Fuse
/// @dev Tests the collection of fees from Velodrom Superchain Slipstream NFT positions
contract VelodromeSuperchainSlipstreamTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;
    using Address for address;

    error InvalidReturnData();

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
    address private constant _SLIPSTREAM_SUPERCHAIN_SUGAR = 0x222ed297aF0560030136AE652d39fa40E1B72818;

    address private constant _VELODROME_POOL = 0x317728bcCE5d1C2895b71b01eEBbB6989ae504aE;
    address private constant _VELODROME_GAUGE = 0x2C568357E5e4BEee207Ab46b5bA5C1196D0D5Ecf;

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    PriceOracleMiddlewareManager private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    RewardsClaimManager private _rewardsClaimManager;

    VelodromeSuperchainSlipstreamNewPositionFuse private _velodromSuperchainSlipstreamNewPositionFuse;
    VelodromeSuperchainSlipstreamModifyPositionFuse private _velodromSuperchainSlipstreamModifyPositionFuse;
    VelodromeSuperchainSlipstreamLeafCLGaugeFuse private _velodromSuperchainSlipstreamLeafCLGaugeFuse;
    VelodromeSuperchainSlipstreamCollectFuse private _velodromSuperchainSlipstreamCollectFuse;
    VelodromeSuperchainSlipstreamBalanceFuse private _velodromSuperchainSlipstreamBalanceFuse;
    VelodromeSuperchainSlipstreamGaugeClaimFuse private _velodromeGaugeClaimFuse;
    TransientStorageSetInputsFuse private _transientStorageSetInputsFuse;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("INK_PROVIDER_URL"), 20419547);

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

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.create(
            "VelodromeSuperchainSlipstream",
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

        // Deploy VelodromeSuperchainSlipstreamCollectFuse
        _velodromSuperchainSlipstreamNewPositionFuse = new VelodromeSuperchainSlipstreamNewPositionFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _velodromSuperchainSlipstreamModifyPositionFuse = new VelodromeSuperchainSlipstreamModifyPositionFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _velodromSuperchainSlipstreamLeafCLGaugeFuse = new VelodromeSuperchainSlipstreamLeafCLGaugeFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );
        _velodromSuperchainSlipstreamCollectFuse = new VelodromeSuperchainSlipstreamCollectFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _velodromSuperchainSlipstreamBalanceFuse = new VelodromeSuperchainSlipstreamBalanceFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM,
            _NONFUNGIBLE_POSITION_MANAGER,
            _SLIPSTREAM_SUPERCHAIN_SUGAR
        );

        _velodromeGaugeClaimFuse = new VelodromeSuperchainSlipstreamGaugeClaimFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        _transientStorageSetInputsFuse = new TransientStorageSetInputsFuse();

        // Setup fuses
        address[] memory fuses = new address[](5);
        fuses[0] = address(_velodromSuperchainSlipstreamNewPositionFuse);
        fuses[1] = address(_velodromSuperchainSlipstreamModifyPositionFuse);
        fuses[2] = address(_velodromSuperchainSlipstreamLeafCLGaugeFuse);
        fuses[3] = address(_velodromSuperchainSlipstreamCollectFuse);
        fuses[4] = address(_transientStorageSetInputsFuse);

        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = address(_velodromeGaugeClaimFuse);

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.addFuses(fuses);
        _rewardsClaimManager.addRewardFuses(rewardFuses);

        _plasmaVaultGovernance.addBalanceFuse(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM,
            address(_velodromSuperchainSlipstreamBalanceFuse)
        );

        _plasmaVaultGovernance.addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        vm.stopPrank();

        // Setup market substrates
        bytes32[] memory velodromSubstrates = new bytes32[](2);
        velodromSubstrates[0] = VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
            VelodromeSuperchainSlipstreamSubstrate({
                substrateType: VelodromeSuperchainSlipstreamSubstrateType.Pool,
                substrateAddress: _VELODROME_POOL
            })
        );
        velodromSubstrates[1] = VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
            VelodromeSuperchainSlipstreamSubstrate({
                substrateType: VelodromeSuperchainSlipstreamSubstrateType.Gauge,
                substrateAddress: _VELODROME_GAUGE
            })
        );

        vm.startPrank(_FUSE_MANAGER);
        _plasmaVaultGovernance.grantMarketSubstrates(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM,
            velodromSubstrates
        );
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
        marketIds[0] = IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM;
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
        VelodromeSuperchainSlipstreamNewPositionFuseEnterData
            memory mintParams = VelodromeSuperchainSlipstreamNewPositionFuseEnterData({
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
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

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
        VelodromeSuperchainSlipstreamNewPositionFuseEnterData
            memory mintParams = VelodromeSuperchainSlipstreamNewPositionFuseEnterData({
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
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

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

        VelodromeSuperchainSlipstreamModifyPositionFuseEnterData
            memory modifyParams = VelodromeSuperchainSlipstreamModifyPositionFuseEnterData({
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
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
    }

    function test_shouldDecreasePosition() public {
        test_shouldCreateSecondPosition();

        // given
        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        uint128 liquidityBefore = _getLiquidity(tokenIds[0]);

        VelodromeSuperchainSlipstreamModifyPositionFuseExitData
            memory modifyParams = VelodromeSuperchainSlipstreamModifyPositionFuseExitData({
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
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(modifyCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        uint128 liquidityAfter = _getLiquidity(tokenIds[0]);

        assertGt(marketBalanceBefore, marketBalanceAfter, "marketBalanceBefore > marketBalanceAfter");
        assertGt(liquidityBefore, liquidityAfter, "liquidityBefore > liquidityAfter");
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

    function test_shouldCollectFromNFTPosition() public {
        test_shouldDecreasePosition();

        // given
        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        VelodromeSuperchainSlipstreamCollectFuseEnterData
            memory collectParams = VelodromeSuperchainSlipstreamCollectFuseEnterData({tokenIds: tokenIds});

        FuseAction[] memory collectCalls = new FuseAction[](1);
        collectCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamCollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectParams)
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
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
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
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

        VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData
            memory stakeParams = VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData({
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

        VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData
            memory unstakeParams = VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData({
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

    /// @notice Test that enterTransient() correctly reads inputs from transient storage and creates a new position
    function test_shouldEnterUsingTransientStorage() public {
        // given
        uint256 amount0Desired = 1_000e6;
        uint256 amount1Desired = 1_000e6;
        uint256 amount0Min = 0;
        uint256 amount1Min = 0;
        uint256 deadline = block.timestamp + 100;
        uint160 sqrtPriceX96 = 0;
        int24 tickSpacing = 1;
        int24 tickLower = 0;
        int24 tickUpper = 101;

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );
        uint256 usdceBalanceBefore = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceBefore = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        // Prepare transient inputs: token0, token1, tickSpacing, tickLower, tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min, deadline, sqrtPriceX96
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromSuperchainSlipstreamNewPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](11);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(_USDTO); // token0
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(_USDCE); // token1
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(int256(tickSpacing))); // tickSpacing
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(uint256(int256(tickLower))); // tickLower
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(uint256(int256(tickUpper))); // tickUpper
        inputsByFuse[0][5] = TypeConversionLib.toBytes32(amount0Desired);
        inputsByFuse[0][6] = TypeConversionLib.toBytes32(amount1Desired);
        inputsByFuse[0][7] = TypeConversionLib.toBytes32(amount0Min);
        inputsByFuse[0][8] = TypeConversionLib.toBytes32(amount1Min);
        inputsByFuse[0][9] = TypeConversionLib.toBytes32(deadline);
        inputsByFuse[0][10] = TypeConversionLib.toBytes32(uint256(sqrtPriceX96)); // sqrtPriceX96

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamNewPositionFuse),
            abi.encodeWithSignature("enterTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );
        uint256 usdceBalanceAfter = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceAfter = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        uint256[] memory nfts = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
        assertTrue(nfts.length > 0, "nfts.length > 0");
        assertLt(usdceBalanceAfter, usdceBalanceBefore, "usdceBalanceAfter < usdceBalanceBefore");
        assertLt(usdtoBalanceAfter, usdtoBalanceBefore, "usdtoBalanceAfter < usdtoBalanceBefore");
    }

    /// @notice Test that exitTransient() correctly reads inputs from transient storage and closes positions
    function test_shouldExitUsingTransientStorage() public {
        // given - first create a position using regular enter
        test_shouldCollectFeesFromNFTPositions();

        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        // Decrease liquidity and collect fees to allow burning
        uint128 liquidity = _getLiquidity(tokenIds[0]);

        VelodromeSuperchainSlipstreamModifyPositionFuseExitData
            memory modifyParams = VelodromeSuperchainSlipstreamModifyPositionFuseExitData({
                tokenId: tokenIds[0],
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });

        VelodromeSuperchainSlipstreamCollectFuseEnterData
            memory collectParams = VelodromeSuperchainSlipstreamCollectFuseEnterData({tokenIds: tokenIds});

        FuseAction[] memory prepareCalls = new FuseAction[](2);
        prepareCalls[0] = FuseAction(
            address(_velodromSuperchainSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", modifyParams)
        );
        prepareCalls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamCollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectParams)
        );

        vm.startPrank(_ALPHA);
        _plasmaVault.execute(prepareCalls);
        vm.stopPrank();

        // Prepare transient inputs for exit: length + tokenIds
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromSuperchainSlipstreamNewPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](1 + tokenIds.length); // length + tokenIds
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(uint256(tokenIds.length)); // length
        for (uint256 i; i < tokenIds.length; ++i) {
            inputsByFuse[0][1 + i] = TypeConversionLib.toBytes32(tokenIds[i]); // tokenId
        }

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamNewPositionFuse),
            abi.encodeWithSignature("exitTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        uint256[] memory nftsAfter = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        assertLt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter < marketBalanceBefore");
        assertEq(nftsAfter.length, 0, "nftsAfter.length == 0");
    }

    /// @notice Test that exitTransient() handles empty array case correctly
    function test_shouldExitUsingTransientStorageWithEmptyArray() public {
        // given - no positions exist
        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        // Prepare transient inputs for exit: length = 0
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromSuperchainSlipstreamNewPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(uint256(0)); // length = 0

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamNewPositionFuse),
            abi.encodeWithSignature("exitTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        assertEq(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter == marketBalanceBefore");
    }

    /// @notice Test that enterTransient() correctly reads inputs from transient storage and increases liquidity
    function test_shouldIncreasePositionUsingTransientStorage() public {
        // given - first create a position using regular enter
        test_shouldCollectFeesFromNFTPositions();

        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        // Prepare transient inputs: token0, token1, tokenId, amount0Desired, amount1Desired, amount0Min, amount1Min, deadline
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromSuperchainSlipstreamModifyPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](8);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(_USDTO); // token0
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(_USDCE); // token1
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(tokenIds[0]); // tokenId
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(uint256(2_000e6)); // amount0Desired
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(uint256(2_000e6)); // amount1Desired
        inputsByFuse[0][5] = TypeConversionLib.toBytes32(uint256(0)); // amount0Min
        inputsByFuse[0][6] = TypeConversionLib.toBytes32(uint256(0)); // amount1Min
        inputsByFuse[0][7] = TypeConversionLib.toBytes32(uint256(block.timestamp + 100)); // deadline

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("enterTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
    }

    /// @notice Test that exitTransient() correctly reads inputs from transient storage and decreases liquidity
    function test_shouldDecreasePositionUsingTransientStorage() public {
        // given - first create a position and increase it
        test_shouldIncreasePosition();

        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        uint128 liquidityBefore = _getLiquidity(tokenIds[0]);
        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );

        // Prepare transient inputs: tokenId, liquidity, amount0Min, amount1Min, deadline
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromSuperchainSlipstreamModifyPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](5);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(tokenIds[0]); // tokenId
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(uint256(liquidityBefore / 2)); // liquidity
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(0)); // amount0Min
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(uint256(0)); // amount1Min
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(uint256(block.timestamp + 100)); // deadline

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamModifyPositionFuse),
            abi.encodeWithSignature("exitTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );
        uint128 liquidityAfter = _getLiquidity(tokenIds[0]);

        assertGt(marketBalanceBefore, marketBalanceAfter, "marketBalanceBefore > marketBalanceAfter");
        assertGt(liquidityBefore, liquidityAfter, "liquidityBefore > liquidityAfter");
    }

    /// @notice Test that enterTransient() correctly reads inputs from transient storage and stakes to gauge
    function test_shouldStakeToGaugeUsingTransientStorage() public {
        // given - first create a position
        test_shouldCollectFromNFTPosition();

        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        // Prepare transient inputs: gaugeAddress, tokenId
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromSuperchainSlipstreamLeafCLGaugeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(_VELODROME_GAUGE); // gaugeAddress
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(tokenIds[0]); // tokenId

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamLeafCLGaugeFuse),
            abi.encodeWithSignature("enterTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256[] memory stakedValues = ILeafCLGauge(_VELODROME_GAUGE).stakedValues(address(_plasmaVault));

        assertEq(stakedValues[0], tokenIds[0], "stakedValues[0] should be equal to tokenIds[0]");
    }

    /// @notice Test that exitTransient() correctly reads inputs from transient storage and unstakes from gauge
    function test_shouldUnstakeFromGaugeUsingTransientStorage() public {
        // given - first stake to gauge
        test_shouldStakeToGauge();

        uint256[] memory stakedValues = ILeafCLGauge(_VELODROME_GAUGE).stakedValues(address(_plasmaVault));

        uint256[] memory tokenIdsBefore = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        // Prepare transient inputs: gaugeAddress, tokenId
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromSuperchainSlipstreamLeafCLGaugeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(_VELODROME_GAUGE); // gaugeAddress
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(stakedValues[0]); // tokenId

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamLeafCLGaugeFuse),
            abi.encodeWithSignature("exitTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256[] memory tokenIdsAfter = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        assertEq(tokenIdsBefore.length + 1, tokenIdsAfter.length, "tokenIdsBefore should be equal to tokenIdsAfter");
    }

    /// @notice Test that enterTransient() correctly reads inputs from transient storage and collects fees
    function test_shouldCollectFromNFTPositionUsingTransientStorage() public {
        test_shouldDecreasePosition();

        // given
        uint256[] memory tokenIds = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).userPositions(
            address(_plasmaVault),
            _VELODROME_POOL
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );
        uint256 usdceBalanceBefore = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceBefore = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        // Prepare transient inputs: length, tokenIds
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_velodromSuperchainSlipstreamCollectFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](1 + tokenIds.length);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            inputsByFuse[0][i + 1] = TypeConversionLib.toBytes32(tokenIds[i]);
        }

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(
            address(_velodromSuperchainSlipstreamCollectFuse),
            abi.encodeWithSignature("enterTransient()")
        );

        // when
        vm.startPrank(_ALPHA);
        _plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM
        );
        uint256 usdceBalanceAfter = IERC20(_USDCE).balanceOf(address(_plasmaVault));
        uint256 usdtoBalanceAfter = IERC20(_USDTO).balanceOf(address(_plasmaVault));

        assertGt(usdceBalanceAfter, usdceBalanceBefore, "usdceBalanceAfter should be greater than usdceBalanceBefore");
        assertGt(usdtoBalanceAfter, usdtoBalanceBefore, "usdtoBalanceAfter should be greater than usdtoBalanceBefore");
        assertGt(
            marketBalanceBefore,
            marketBalanceAfter,
            "marketBalanceBefore should be greater than marketBalanceAfter"
        );
    }
}
