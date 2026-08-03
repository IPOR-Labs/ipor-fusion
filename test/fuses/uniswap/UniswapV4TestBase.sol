// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {TransientStorageSetInputsFuse} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";

import {
    UniswapV4NewPositionFuse,
    UniswapV4NewPositionFuseEnterData,
    UniswapV4NewPositionFuseExitData
} from "../../../contracts/fuses/uniswap/UniswapV4NewPositionFuse.sol";
import {
    UniswapV4ModifyPositionFuse,
    UniswapV4ModifyPositionFuseEnterData,
    UniswapV4ModifyPositionFuseExitData
} from "../../../contracts/fuses/uniswap/UniswapV4ModifyPositionFuse.sol";
import {
    UniswapV4CollectFuse,
    UniswapV4CollectFuseEnterData
} from "../../../contracts/fuses/uniswap/UniswapV4CollectFuse.sol";
import {UniswapV4Balance} from "../../../contracts/fuses/uniswap/UniswapV4Balance.sol";
import {UniswapV4SubstrateLib} from "../../../contracts/fuses/uniswap/UniswapV4SubstrateLib.sol";
import {IPositionManagerV4} from "../../../contracts/fuses/uniswap/ext/v4/IPositionManagerV4.sol";
import {ActionsV4} from "../../../contracts/fuses/uniswap/ext/v4/ActionsV4.sol";
import {IPermit2} from "../../../contracts/fuses/balancer/ext/IPermit2.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Permit2 allowance view, not part of the vendored IPermit2 (approve-only)
interface IPermit2View {
    function allowance(
        address user,
        address token,
        address spender
    ) external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @dev Shared fork-test harness for the Uniswap V4 liquidity fuses (Base fork). The PlasmaVault is
/// created through the on-chain FusionFactory (clone), matching production deployment, rather than
/// being wired up manually.
abstract contract UniswapV4TestBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 internal constant FORK_BLOCK = 32_889_330;

    address internal constant USDC = TestAddresses.BASE_USDC;
    address internal constant WETH = TestAddresses.BASE_WETH;
    address internal constant CBBTC = TestAddresses.BASE_CBBTC;
    address internal constant CBETH = TestAddresses.BASE_CBETH;

    /// @dev Uniswap V4 Base deployment (verified on-chain)
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev FusionFactory deployed on Base
    address internal constant FUSION_FACTORY = 0x1455717668fA96534f675856347A973fA907e922;

    address internal _plasmaVault;
    address internal _priceOracle;
    address internal _accessManager;
    address internal _withdrawManager;

    UniswapV4NewPositionFuse internal _newPositionFuse;
    UniswapV4ModifyPositionFuse internal _modifyPositionFuse;
    UniswapV4CollectFuse internal _collectFuse;
    UniswapV4Balance internal _balanceFuse;
    address internal _transientStorageSetInputsFuse;

    PoolSwapTest internal _poolSwapTest;

    /// @dev an address above USDC in currency ordering that is never granted as an asset substrate
    address internal constant UNGRANTED_TOKEN = address(uint160(0xF000000000000000000000000000000000000001));

    /// @dev primary workhorse pool (WETH/USDC): currency0 = WETH (18d), currency1 = USDC (6d)
    PoolKey internal _wethUsdcKey;
    /// @dev second pool (USDC/cbBTC): currency0 = USDC (6d), currency1 = cbBTC (8d)
    PoolKey internal _usdcCbbtcKey;
    /// @dev granted as a pool substrate but currency0 (cbETH) is NOT granted as an asset — exercises the
    /// token0 gating branch (substrate check runs before any pool interaction, so no liquidity needed)
    PoolKey internal _cbethWethKey;
    /// @dev pool substrate granted but currency1 NOT granted as asset — exercises the token1 gating branch
    PoolKey internal _usdcUngrantedToken1Key;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK);

        _wethUsdcKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        _usdcCbbtcKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(CBBTC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        _cbethWethKey = PoolKey({
            currency0: Currency.wrap(CBETH),
            currency1: Currency.wrap(WETH),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        _usdcUngrantedToken1Key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(UNGRANTED_TOKEN),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        _createVaultFromFactory();
        _setupFuses();
        _setupBalanceFuses();
        _setupMarketConfigs();
        _setupDependenceBalance();

        _poolSwapTest = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        // fund the vault: USDC via a regular deposit, WETH/cbBTC directly (test-only shortcut)
        address userOne = address(0x1222);
        deal(USDC, userOne, 300_000e6);
        vm.startPrank(userOne);
        ERC20(USDC).approve(_plasmaVault, 300_000e6);
        PlasmaVault(_plasmaVault).deposit(300_000e6, userOne);
        vm.stopPrank();

        deal(WETH, _plasmaVault, 100e18);
        deal(CBBTC, _plasmaVault, 50e8);
    }

    // ---------------------------------------------------------------------
    // setup helpers
    // ---------------------------------------------------------------------

    /// @dev Creates the PlasmaVault (and its managers) via the on-chain FusionFactory, then grants the
    /// test contract the operational roles so it can configure the vault and call `execute` directly.
    function _createVaultFromFactory() private {
        FusionFactory fusionFactory = FusionFactory(FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "TEST V4 PLASMA VAULT",
            "pvUSDC",
            USDC,
            0,
            address(this),
            0
        );

        _plasmaVault = instance.plasmaVault;
        _priceOracle = instance.priceManager;
        _accessManager = instance.accessManager;
        _withdrawManager = instance.withdrawManager;

        // address(this) is the vault owner; grant it the roles the test bodies rely on
        IporFusionAccessManager accessManager = IporFusionAccessManager(_accessManager);
        accessManager.grantRole(Roles.ATOMIST_ROLE, address(this), 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, address(this), 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, address(this), 0);

        PlasmaVaultGovernance(_plasmaVault).convertToPublicVault();
        PlasmaVaultGovernance(_plasmaVault).enableTransferShares();
    }

    function _setupMarketConfigs() private {
        // Uniswap V4 positions market: pool ids + tokens (cbETH/WETH pool granted WITHOUT cbETH asset,
        // USDC/UNGRANTED_TOKEN pool granted WITHOUT its token1 asset)
        bytes32[] memory v4Substrates = new bytes32[](7);
        v4Substrates[0] = UniswapV4SubstrateLib.poolKeyToId(_wethUsdcKey);
        v4Substrates[1] = UniswapV4SubstrateLib.poolKeyToId(_usdcCbbtcKey);
        v4Substrates[2] = UniswapV4SubstrateLib.poolKeyToId(_cbethWethKey);
        v4Substrates[3] = UniswapV4SubstrateLib.poolKeyToId(_usdcUngrantedToken1Key);
        v4Substrates[4] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        v4Substrates[5] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        v4Substrates[6] = PlasmaVaultConfigLib.addressToBytes32(CBBTC);

        bytes32[] memory erc20Substrates = new bytes32[](3);
        erc20Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        erc20Substrates[1] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        erc20Substrates[2] = PlasmaVaultConfigLib.addressToBytes32(CBBTC);

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.UNISWAP_V4,
            v4Substrates
        );
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            erc20Substrates
        );
    }

    function _setupFuses() private {
        _newPositionFuse = new UniswapV4NewPositionFuse(
            IporFusionMarkets.UNISWAP_V4,
            POSITION_MANAGER,
            POOL_MANAGER,
            PERMIT2
        );
        _modifyPositionFuse = new UniswapV4ModifyPositionFuse(
            IporFusionMarkets.UNISWAP_V4,
            POSITION_MANAGER,
            POOL_MANAGER,
            PERMIT2
        );
        _collectFuse = new UniswapV4CollectFuse(IporFusionMarkets.UNISWAP_V4, POSITION_MANAGER);
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());

        address[] memory fuses = new address[](4);
        fuses[0] = address(_newPositionFuse);
        fuses[1] = address(_modifyPositionFuse);
        fuses[2] = address(_collectFuse);
        fuses[3] = _transientStorageSetInputsFuse;

        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
    }

    function _setupBalanceFuses() private {
        _balanceFuse = new UniswapV4Balance(IporFusionMarkets.UNISWAP_V4, POSITION_MANAGER, POOL_MANAGER);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(
            IporFusionMarkets.UNISWAP_V4,
            address(_balanceFuse)
        );
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(erc20Balance)
        );
    }

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.UNISWAP_V4;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
    }

    // ---------------------------------------------------------------------
    // action helpers
    // ---------------------------------------------------------------------

    function _executeEnterNewPosition(UniswapV4NewPositionFuseEnterData memory data_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(UniswapV4NewPositionFuse.enter.selector, data_)
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function _executeExitNewPosition(UniswapV4NewPositionFuseExitData memory data_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(UniswapV4NewPositionFuse.exit.selector, data_)
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    /// @dev Opens an in-range position around the current tick and returns the minted tokenId.
    function _openPosition(
        PoolKey memory poolKey_,
        int24 tickRange_,
        uint256 amount0Desired_,
        uint256 amount1Desired_
    ) internal returns (uint256 tokenId) {
        tokenId = IPositionManagerV4(POSITION_MANAGER).nextTokenId();

        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(poolKey_.toId());

        _executeEnterNewPosition(
            UniswapV4NewPositionFuseEnterData({
                poolKey: poolKey_,
                tickLower: _alignTick(currentTick - tickRange_, poolKey_.tickSpacing),
                tickUpper: _alignTick(currentTick + tickRange_, poolKey_.tickSpacing),
                amount0Desired: amount0Desired_,
                amount1Desired: amount1Desired_,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                hookData: bytes(""),
                deadline: block.timestamp + 100
            })
        );
    }

    function _closePosition(uint256 tokenId_) internal {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId_;
        _closePositions(tokenIds);
    }

    function _closePositions(uint256[] memory tokenIds_) internal {
        _executeExitNewPosition(
            UniswapV4NewPositionFuseExitData({
                tokenIds: tokenIds_,
                amount0Min: new uint256[](tokenIds_.length),
                amount1Min: new uint256[](tokenIds_.length),
                hookData: bytes(""),
                deadline: block.timestamp + 100
            })
        );
    }

    /// @dev Executes a zero-liquidity collect on an empty tokenId set — a no-op fuse action whose only
    /// effect is that PlasmaVault.execute recalculates the V4 market balance.
    function _refreshMarketBalance() internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(new uint256[](0)))
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    /// @dev Swaps through a V4 pool from the test contract to move price / accrue LP fees.
    function _swapV4(PoolKey memory poolKey_, bool zeroForOne_, uint256 amountIn_) internal {
        address tokenIn = zeroForOne_ ? Currency.unwrap(poolKey_.currency0) : Currency.unwrap(poolKey_.currency1);

        deal(tokenIn, address(this), amountIn_);
        // reset allowance to zero first for tokens that require it; forge deal + approve pattern
        ERC20(tokenIn).approve(address(_poolSwapTest), 0);
        ERC20(tokenIn).approve(address(_poolSwapTest), amountIn_);

        _poolSwapTest.swap(
            poolKey_,
            SwapParams({
                zeroForOne: zeroForOne_,
                amountSpecified: -int256(amountIn_),
                sqrtPriceLimitX96: zeroForOne_ ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    /// @dev Mints a WETH/USDC position owned by the TEST CONTRACT (not the vault) directly through the
    /// PositionManager — used to prove fuses reject positions the vault does not track.
    function _mintForeignPosition() internal returns (uint256 tokenId) {
        tokenId = IPositionManagerV4(POSITION_MANAGER).nextTokenId();

        deal(WETH, address(this), 5e18);
        deal(USDC, address(this), 20_000e6);

        IERC20(WETH).forceApprove(PERMIT2, type(uint256).max);
        IERC20(USDC).forceApprove(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(WETH, POSITION_MANAGER, type(uint160).max, uint48(block.timestamp + 100));
        IPermit2(PERMIT2).approve(USDC, POSITION_MANAGER, type(uint160).max, uint48(block.timestamp + 100));

        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            _wethUsdcKey,
            _alignTick(currentTick - 1000, 10),
            _alignTick(currentTick + 1000, 10),
            uint256(1e15),
            uint128(5e18),
            uint128(20_000e6),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(_wethUsdcKey.currency0, _wethUsdcKey.currency1);

        IPositionManagerV4(POSITION_MANAGER).modifyLiquidities(
            abi.encode(abi.encodePacked(ActionsV4.MINT_POSITION, ActionsV4.SETTLE_PAIR), params),
            block.timestamp + 100
        );
    }

    // ---------------------------------------------------------------------
    // misc helpers
    // ---------------------------------------------------------------------

    function _alignTick(int24 tick_, int24 spacing_) internal pure returns (int24) {
        return (tick_ / spacing_) * spacing_;
    }

    function _positionLiquidity(uint256 tokenId_) internal view returns (uint128) {
        return IPositionManagerV4(POSITION_MANAGER).getPositionLiquidity(tokenId_);
    }

    function _v4MarketBalance() internal view returns (uint256) {
        return PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.UNISWAP_V4);
    }

    /// @dev USD value (WAD) of a token amount using the same oracle the vault uses.
    function _usdValue(address token_, uint256 amount_) internal view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(_priceOracle).getAssetPrice(token_);
        return (amount_ * price * 1e18) / (10 ** (ERC20(token_).decimals() + priceDecimals));
    }

    /// @dev Converts a USD (WAD) value into vault-underlying (USDC, 6 decimals) terms — the unit
    /// returned by PlasmaVault.totalAssetsInMarket.
    function _usdToUnderlying(uint256 usdWad_) internal view returns (uint256) {
        return (usdWad_ * 1e6) / _usdValue(USDC, 1e6);
    }

    /// @dev Oracle value of token amounts expressed directly in vault-underlying terms.
    function _valueInUnderlying(address token_, uint256 amount_) internal view returns (uint256) {
        return _usdToUnderlying(_usdValue(token_, amount_));
    }

    function _extractNewPositionEnterEvent(
        Vm.Log[] memory entries_
    ) internal pure returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        for (uint256 i; i < entries_.length; i++) {
            if (
                entries_[i].topics[0] ==
                keccak256("UniswapV4NewPositionFuseEnter(address,uint256,uint128,uint256,uint256,bytes32,int24,int24)")
            ) {
                (, tokenId, liquidity, amount0, amount1, , , ) = abi.decode(
                    entries_[i].data,
                    (address, uint256, uint128, uint256, uint256, bytes32, int24, int24)
                );
                break;
            }
        }
    }

    function _extractExitEvent(
        Vm.Log[] memory entries_
    ) internal pure returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        for (uint256 i; i < entries_.length; i++) {
            if (entries_[i].topics[0] == keccak256("UniswapV4NewPositionFuseExit(address,uint256,uint256,uint256)")) {
                (, tokenId, amount0, amount1) = abi.decode(entries_[i].data, (address, uint256, uint256, uint256));
                break;
            }
        }
    }

    function _extractCollectEvent(
        Vm.Log[] memory entries_
    ) internal pure returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        for (uint256 i; i < entries_.length; i++) {
            if (entries_[i].topics[0] == keccak256("UniswapV4CollectFuseEnter(address,uint256,uint256,uint256)")) {
                (, tokenId, amount0, amount1) = abi.decode(entries_[i].data, (address, uint256, uint256, uint256));
                break;
            }
        }
    }
}
