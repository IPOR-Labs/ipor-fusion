// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {
    FuseAction,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVault,
    PlasmaVaultInitData
} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {FuseStorageLib} from "../../../contracts/libraries/FuseStorageLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {OracleSqrtPriceX96Lib} from "../../../contracts/libraries/math/OracleSqrtPriceX96Lib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {RamsesV2Balance} from "../../../contracts/fuses/ramses/RamsesV2Balance.sol";
import {RamsesV2OracleBalance} from "../../../contracts/fuses/ramses/RamsesV2OracleBalance.sol";
import {
    RamsesV2NewPositionFuse,
    RamsesV2NewPositionFuseEnterData
} from "../../../contracts/fuses/ramses/RamsesV2NewPositionFuse.sol";
import {
    INonfungiblePositionManagerRamses,
    IRamsesV2Factory,
    IRamsesV2Pool
} from "../../../contracts/fuses/ramses/ext/INonfungiblePositionManagerRamses.sol";
import {PositionKey} from "../../../contracts/fuses/ramses/ext/PositionKey.sol";
import {RamsesV2PositionFees} from "../../../contracts/fuses/ramses/ext/RamsesV2PositionFees.sol";
import {TickMath} from "../../../contracts/fuses/ramses/ext/TickMath.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

/// @dev Holds the two pieces of vault storage a Ramses V2 balance fuse reads (the tracked token ID list and the
///      price oracle middleware) and runs a fuse's `balanceOf` by delegatecall, the way a PlasmaVault does. Lets the
///      test value the same positions with `RamsesV2Balance` and `RamsesV2OracleBalance` in the same state.
contract RamsesV2OracleBalanceForkTestVaultStorage {
    using Address for address;

    constructor(address priceOracleMiddleware_) {
        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    function setTokenIds(uint256[] calldata tokenIds_) external {
        FuseStorageLib.getRamsesV2TokenIds().tokenIds = tokenIds_;
    }

    function balanceOfFuse(address fuse_) external returns (uint256) {
        return abi.decode(fuse_.functionDelegateCall(abi.encodeWithSignature("balanceOf()")), (uint256));
    }
}

/// @title RamsesV2OracleBalanceForkTest
/// @notice IL-9605 (M15): `RamsesV2OracleBalance` values Ramses V2 positions at an oracle-implied composition, so a
///         swap in the pool cannot move the principal part of the market value, while `RamsesV2Balance` (slot0) can.
/// @dev Arbitrum fork at its own block (254261636). Every manipulation test asserts in the same state that the slot0
///      fuse moves (control that the scenario reaches the valuation) and that the oracle fuse moves at most by fees.
///      Ramses V2 pools are a Uniswap V3 fork: `slot0`, `token0`, `token1`, `fee` and `swap` share the Uniswap V3
///      pool ABI, so the test drives them through `IUniswapV3Pool`; only the swap callback is renamed
///      (`ramsesV2SwapCallback`).
///      Fees (D-A3, D-050): both fuses read fees with `RamsesV2PositionFees`, from the pool's current fee growth. The
///      fee tests compare the fees each fuse values before `collect` with the amounts `collect` returns (within 2 wei
///      of each token): fees checkpointed in the position manager, fees earned after the last update of the position,
///      positions whose range the spot left, and a live position whose fee growth checkpoint wrapped modulo 2^256.
contract RamsesV2OracleBalanceForkTest is Test {
    using SafeERC20 for IERC20;

    struct Values {
        uint256 spot;
        uint256 oracle;
    }

    /// @dev Liquidity and fee growth checkpoint stored by a Ramses V2 pool for one position key
    struct Checkpoint {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    struct Swap {
        address tokenIn;
        uint256 amountIn;
        uint24 fee;
    }

    uint256 private constant _FORK_BLOCK = 254261636;

    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant _DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address private constant _FRAX = 0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F;

    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0xAA277CB7914b7e5514946Da92cb9De332Ce610EF;
    address private constant _RAMSES_FACTORY = 0xAA2cd7477c451E703f3B9Ba5663334914763edF8;

    address private constant _CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address private constant _CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address private constant _CHAINLINK_DAI_USD = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;
    address private constant _CHAINLINK_FRAX_USD = 0x0809E3d38d1B4214958faf06D8b1B1a2b73f2ab8;

    /// @dev A live FRAX/USDC (fee 100) position at the fork block whose position manager fee growth checkpoints are
    ///      wrapped values (token0 checkpoint = 2^256 - 2.25e39) and whose pool fee growth inside wraps below zero
    uint256 private constant _WRAPPED_CHECKPOINT_TOKEN_ID = 190206;
    uint24 private constant _FRAX_USDC_FEE = 100;

    /// @dev WETH (18 decimals) is token0, USDC (6 decimals) token1
    uint24 private constant _WETH_USDC_FEE = 500;
    int24 private constant _WETH_USDC_TICK_SPACING = 10;
    /// @dev USDC (6 decimals) is token0, DAI (18 decimals) token1
    uint24 private constant _USDC_DAI_FEE = 100;
    int24 private constant _USDC_DAI_TICK_SPACING = 1;

    /// @dev Input budget dealt before every manipulation swap; far above what any swap in these tests consumes
    uint256 private constant _SWAP_BUDGET = 1e30;
    /// @dev Per-step round-up of pool fee amounts, added to the swap fee upper bound
    uint256 private constant _SWAP_FEE_ROUNDING = 1_000;
    /// @dev Slack for the floor rounding of two independently converted token legs
    uint256 private constant _LEG_ROUNDING = 2;
    /// @dev Per-token slack (wei) between the fees valued before `collect` and the amounts `collect` transfers
    uint256 private constant _COLLECT_ROUNDING = 2;

    PriceOracleMiddleware private _priceOracle;
    RamsesV2Balance private _spotFuse;
    RamsesV2OracleBalance private _oracleFuse;
    RamsesV2OracleBalanceForkTestVaultStorage private _vaultStorage;
    address private _wethUsdcPool;
    address private _usdcDaiPool;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), _FORK_BLOCK);

        _priceOracle = _createPriceOracle(true);

        _spotFuse = new RamsesV2Balance(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER,
            _RAMSES_FACTORY
        );
        _oracleFuse = new RamsesV2OracleBalance(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER,
            _RAMSES_FACTORY
        );
        _vaultStorage = new RamsesV2OracleBalanceForkTestVaultStorage(address(_priceOracle));

        _wethUsdcPool = IRamsesV2Factory(_RAMSES_FACTORY).getPool(_WETH, _USDC, _WETH_USDC_FEE);
        _usdcDaiPool = IRamsesV2Factory(_RAMSES_FACTORY).getPool(_USDC, _DAI, _USDC_DAI_FEE);
        assertTrue(_wethUsdcPool != address(0) && _usdcDaiPool != address(0), "pools exist");
        assertEq(IUniswapV3Pool(_wethUsdcPool).token0(), _WETH, "WETH is token0 of WETH/USDC");
        assertEq(IUniswapV3Pool(_usdcDaiPool).token0(), _USDC, "USDC is token0 of USDC/DAI");

        deal(_USDC, address(this), 10_000_000e6);
        deal(_WETH, address(this), 10_000e18);
        deal(_DAI, address(this), 10_000_000e18);
        IERC20(_USDC).forceApprove(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
        IERC20(_WETH).forceApprove(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
        IERC20(_DAI).forceApprove(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    function testShouldSetMarketIdVersionAndAddresses() external view {
        assertEq(_oracleFuse.MARKET_ID(), IporFusionMarkets.RAMSES_V2_POSITIONS, "MARKET_ID");
        assertEq(_oracleFuse.MARKET_ID(), _spotFuse.MARKET_ID(), "same market as the slot0 fuse");
        assertEq(_oracleFuse.VERSION(), address(_oracleFuse), "VERSION");
        assertEq(_oracleFuse.NONFUNGIBLE_POSITION_MANAGER(), _NONFUNGIBLE_POSITION_MANAGER, "position manager");
        assertEq(_oracleFuse.RAMSES_FACTORY(), _RAMSES_FACTORY, "factory");
    }

    function testShouldRevertWhenPositionManagerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(RamsesV2OracleBalance.RamsesV2OracleBalanceZeroAddress.selector));
        new RamsesV2OracleBalance(IporFusionMarkets.RAMSES_V2_POSITIONS, address(0), _RAMSES_FACTORY);
    }

    function testShouldRevertWhenFactoryIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(RamsesV2OracleBalance.RamsesV2OracleBalanceZeroAddress.selector));
        new RamsesV2OracleBalance(IporFusionMarkets.RAMSES_V2_POSITIONS, _NONFUNGIBLE_POSITION_MANAGER, address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // (1) Parity with the slot0 fuse
    // ---------------------------------------------------------------------------------------------

    /// @notice With the pool moved exactly to the oracle-implied price, both fuses compute the same composition and
    ///         the same fees, so they report the same value.
    function testShouldMatchSlot0FuseWhenPoolTradesAtOraclePrice() external {
        // given
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_wethUsdcPool, _WETH_USDC_TICK_SPACING, 1_000);
        uint256 tokenId = _mint(_WETH, _USDC, _WETH_USDC_FEE, tickLower, tickUpper, 10e18, 25_000e6);

        // when
        _moveToOraclePrice(_wethUsdcPool);
        Values memory values = _values(tokenId);

        // then
        (uint160 poolSqrtPriceX96, int24 poolTick, , , , , ) = IUniswapV3Pool(_wethUsdcPool).slot0();
        assertEq(poolSqrtPriceX96, _oracleSqrtPriceX96(_WETH, _USDC), "pool trades at the oracle-implied price");
        assertTrue(poolTick >= tickLower && poolTick < tickUpper, "position in range");
        assertGt(values.oracle, 0, "position has value");
        assertEq(values.oracle, values.spot, "oracle fuse = slot0 fuse at the oracle price");
    }

    /// @notice On the untouched fork pool the oracle fuse stays within 0.01% of the slot0 fuse and never above it
    ///         (at fixed leg prices the value of a position's composition is lowest at the leg price ratio).
    function testShouldStayCloseToSlot0FuseAtForkPoolPrice() external {
        // given
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_wethUsdcPool, _WETH_USDC_TICK_SPACING, 1_000);
        uint256 tokenId = _mint(_WETH, _USDC, _WETH_USDC_FEE, tickLower, tickUpper, 10e18, 25_000e6);

        // when
        Values memory values = _values(tokenId);

        // then
        assertGt(values.oracle, 0, "position has value");
        assertLe(values.oracle, values.spot, "oracle fuse not above the slot0 fuse");
        assertApproxEqRel(values.oracle, values.spot, 1e14, "oracle fuse within 0.01% of the slot0 fuse");
    }

    // ---------------------------------------------------------------------------------------------
    // (2) Same-transaction pool swap: principal unchanged, total moves at most by fees
    // ---------------------------------------------------------------------------------------------

    function testShouldNotMoveOracleFusePrincipalWhenSpotIsPushedAboveRange() external {
        _assertSpotPushMovesOracleFuseAtMostByFees(true);
    }

    function testShouldNotMoveOracleFusePrincipalWhenSpotIsPushedBelowRange() external {
        _assertSpotPushMovesOracleFuseAtMostByFees(false);
    }

    // ---------------------------------------------------------------------------------------------
    // (2b) Fees: compared with the amounts `collect` returns (D-A3)
    // ---------------------------------------------------------------------------------------------

    /// @notice Fees checkpointed in the position manager (`tokensOwed`, written when the position is updated) are
    ///         valued before `collect` exactly as `collect` returns them, and the same as by the slot0 fuse.
    function testShouldValueCheckpointedFeesAsCollectedAndAsSlot0Fuse() external {
        // given: an in-range position, a round trip of swaps inside its range so both tokens earn fees and the pool
        // ends at its starting price, then a small liquidity increase that checkpoints the earned fees in the
        // position manager
        uint256 tokenId = _mintWethUsdcInRange();
        _roundTripSwaps(_wethUsdcPool, 300);
        _increaseLiquidity(tokenId, 1e15, 3e6);

        (uint128 tokensOwed0, uint128 tokensOwed1) = _tokensOwed(tokenId);
        Values memory withFees = _values(tokenId);

        // when
        (uint256 collected0, uint256 collected1) = _collect(tokenId);
        Values memory withoutFees = _values(tokenId);

        // then
        assertGt(collected0, 0, "token0 fees earned");
        assertGt(collected1, 0, "token1 fees earned");
        assertEq(tokensOwed0, collected0, "token0 fees checkpointed before collect = collected");
        assertEq(tokensOwed1, collected1, "token1 fees checkpointed before collect = collected");
        assertApproxEqAbs(
            withFees.oracle - withoutFees.oracle,
            _usd(_WETH, collected0) + _usd(_USDC, collected1),
            _LEG_ROUNDING,
            "oracle fuse fee part = USD value of collected fees"
        );
        assertApproxEqAbs(
            withFees.oracle - withoutFees.oracle,
            withFees.spot - withoutFees.spot,
            _LEG_ROUNDING,
            "oracle fuse fee part = slot0 fuse fee part"
        );
    }

    /// @notice Fees earned after the last update of a position (not checkpointed in the position manager) are valued
    ///         by both fuses before `collect` as `collect` returns them (D-050). Before D-050 both fuses valued them
    ///         at 0: the fee read keyed `pool.positions` by the vault and returned an empty position.
    function testShouldValueFeesEarnedAfterLastPositionUpdateAsCollected() external {
        // given: an in-range position and a round trip of swaps inside its range, no update of the position after it
        uint256 tokenId = _mintWethUsdcInRange();
        _roundTripSwaps(_wethUsdcPool, 300);

        (uint128 tokensOwed0, uint128 tokensOwed1) = _tokensOwed(tokenId);
        Values memory beforeCollect = _values(tokenId);

        // when
        (uint256 collected0, uint256 collected1) = _collect(tokenId);
        Values memory afterCollect = _values(tokenId);

        // then: nothing was checkpointed in the position manager, yet both fuses valued the fees `collect` returned
        assertEq(tokensOwed0, 0, "no token0 fees checkpointed in the position manager");
        assertEq(tokensOwed1, 0, "no token1 fees checkpointed in the position manager");
        assertGt(collected0, 0, "token0 fees earned and collected");
        assertGt(collected1, 0, "token1 fees earned and collected");
        _assertValuedFeesEqualCollected(beforeCollect, afterCollect, _WETH, _USDC, collected0, collected1);
    }

    /// @notice The fee read computes the fee growth inside the position's range from the pool's current tick, the
    ///         ticks' fee growth outside values and the global accumulators. It equals the checkpoint the pool writes
    ///         for the position under the position manager's key when `collect` pokes it, and the fees it implies are
    ///         the amounts `collect` returns. The pool stores no position under the vault's key (the key of the fee
    ///         read before D-050).
    function testShouldComputeFeeGrowthInsideAsThePoolDoesAtThePositionManagerKey() external {
        // given
        uint256 tokenId = _mintWethUsdcInRange();
        _roundTripSwaps(_wethUsdcPool, 300);
        INonfungiblePositionManagerRamses.Position memory position = _position(tokenId);

        // when: fee growth inside and fees computed from the pool state before the position is poked, then `collect`
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = RamsesV2PositionFees.getFeeGrowthInside(
            IRamsesV2Pool(_wethUsdcPool),
            position.tickLower,
            position.tickUpper
        );
        (uint256 fee0, uint256 fee1) = RamsesV2PositionFees.uncollectedFees(
            IRamsesV2Pool(_wethUsdcPool),
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0Last,
            position.feeGrowthInside1Last
        );
        (uint256 collected0, uint256 collected1) = _collect(tokenId);

        // then
        Checkpoint memory managerKey = _poolCheckpoint(_NONFUNGIBLE_POSITION_MANAGER, tokenId, position);
        Checkpoint memory vaultKey = _poolCheckpoint(address(_vaultStorage), tokenId, position);
        INonfungiblePositionManagerRamses.Position memory positionAfter = _position(tokenId);
        assertEq(managerKey.liquidity, position.liquidity, "the pool keys the position by the position manager");
        assertEq(vaultKey.liquidity, 0, "no position under the vault's key");
        assertTrue(feeGrowthInside0X128 != position.feeGrowthInside0Last, "token0 fee growth since the checkpoint");
        assertTrue(feeGrowthInside1X128 != position.feeGrowthInside1Last, "token1 fee growth since the checkpoint");
        assertEq(managerKey.feeGrowthInside0LastX128, feeGrowthInside0X128, "pool token0 checkpoint after the poke");
        assertEq(managerKey.feeGrowthInside1LastX128, feeGrowthInside1X128, "pool token1 checkpoint after the poke");
        assertEq(positionAfter.feeGrowthInside0Last, feeGrowthInside0X128, "manager token0 checkpoint after collect");
        assertEq(positionAfter.feeGrowthInside1Last, feeGrowthInside1X128, "manager token1 checkpoint after collect");
        assertGt(fee0, 0, "token0 fees computed");
        assertGt(fee1, 0, "token1 fees computed");
        assertApproxEqAbs(fee0, collected0, _COLLECT_ROUNDING, "token0 fees computed = collected");
        assertApproxEqAbs(fee1, collected1, _COLLECT_ROUNDING, "token1 fees computed = collected");
    }

    /// @notice A live position whose fee growth checkpoints are wrapped values and whose pool fee growth inside wraps
    ///         below zero (the pool's global accumulator is lower than the sum of the two ticks' outside values) is
    ///         valued by both fuses without an arithmetic panic, and its fees as `collect` returns them.
    function testShouldValueFeesOfPositionWithWrappedFeeGrowthCheckpointAsCollected() external {
        // given
        uint256 tokenId = _WRAPPED_CHECKPOINT_TOKEN_ID;
        INonfungiblePositionManagerRamses.Position memory position = _position(tokenId);
        IRamsesV2Pool pool = IRamsesV2Pool(IRamsesV2Factory(_RAMSES_FACTORY).getPool(_FRAX, _USDC, _FRAX_USDC_FEE));
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = RamsesV2PositionFees.getFeeGrowthInside(
            pool,
            position.tickLower,
            position.tickUpper
        );
        (, int24 tick, , , , , ) = pool.slot0();

        assertEq(position.token0, _FRAX, "FRAX is token0");
        assertEq(position.token1, _USDC, "USDC is token1");
        assertGt(position.liquidity, 0, "position has liquidity");
        assertTrue(tick >= position.tickLower && tick < position.tickUpper, "position in range");
        assertGt(position.feeGrowthInside0Last, type(uint256).max / 2, "token0 checkpoint is a wrapped value");
        assertGt(position.feeGrowthInside1Last, type(uint256).max / 2, "token1 checkpoint is a wrapped value");
        assertGt(feeGrowthInside0X128, pool.feeGrowthGlobal0X128(), "token0 fee growth inside wraps below zero");
        assertGt(feeGrowthInside1X128, pool.feeGrowthGlobal1X128(), "token1 fee growth inside wraps below zero");

        Values memory beforeCollect = _values(tokenId);

        // when
        vm.prank(IERC721Enumerable(_NONFUNGIBLE_POSITION_MANAGER).ownerOf(tokenId));
        (uint256 collected0, uint256 collected1) = _collect(tokenId);
        Values memory afterCollect = _values(tokenId);

        // then
        assertGt(collected0, 0, "token0 fees collected");
        assertGt(collected1, 0, "token1 fees collected");
        _assertValuedFeesEqualCollected(beforeCollect, afterCollect, _FRAX, _USDC, collected0, collected1);
    }

    // ---------------------------------------------------------------------------------------------
    // (3) Out-of-range positions on both sides, full range, both decimal orders
    // ---------------------------------------------------------------------------------------------

    /// @notice WETH (18) / USDC (6) and USDC (6) / DAI (18) pools, each with an in-range, a below-range, an
    ///         above-range and a full-range position: at the oracle price every position matches the slot0 fuse;
    ///         after the spot is pushed through several ranges the oracle fuse principal of every position is
    ///         unchanged while the slot0 fuse total moves.
    function testShouldHandleOutOfRangeFullRangeAndMixedDecimalPositions() external {
        // given
        _moveToOraclePrice(_wethUsdcPool);
        _moveToOraclePrice(_usdcDaiPool);
        uint256[] memory tokenIds = new uint256[](8);
        _mintRangeSet(tokenIds, 0, _wethUsdcPool, _WETH_USDC_TICK_SPACING, 500, 10e18, 25_000e6);
        _mintRangeSet(tokenIds, 4, _usdcDaiPool, _USDC_DAI_TICK_SPACING, 20, 25_000e6, 25_000e18);

        // then: parity at the oracle price, position by position and for the whole list
        uint256[] memory oracleValues = new uint256[](8);
        uint256 sumOfPositions;
        for (uint256 i; i < tokenIds.length; ++i) {
            Values memory single = _values(tokenIds[i]);
            assertGt(single.oracle, 0, "position has value");
            assertEq(single.oracle, single.spot, "oracle fuse = slot0 fuse at the oracle price");
            oracleValues[i] = single.oracle;
            sumOfPositions += single.oracle;
        }
        Values memory total = _valuesOf(tokenIds);
        assertEq(total.oracle, sumOfPositions, "oracle fuse sums all tracked positions");
        assertEq(total.spot, sumOfPositions, "slot0 fuse sums all tracked positions");

        // when: the WETH/USDC spot is pushed up through the in-range and above-range positions, the USDC/DAI spot down
        // through the in-range and below-range positions
        _swapToSqrtPrice(_wethUsdcPool, TickMath.getSqrtRatioAtTick(_currentTick(_wethUsdcPool) + 1_700));
        _swapToSqrtPrice(_usdcDaiPool, TickMath.getSqrtRatioAtTick(_currentTick(_usdcDaiPool) - 80));
        for (uint256 i; i < tokenIds.length; ++i) {
            _collect(tokenIds[i]);
        }

        // then: principal of every position unchanged for the oracle fuse; the slot0 fuse total moved
        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(_values(tokenIds[i]).oracle, oracleValues[i], "oracle fuse principal unchanged");
        }
        assertGt(_valuesOf(tokenIds).spot, sumOfPositions + sumOfPositions / 1_000, "control: slot0 fuse total moved");
    }

    // ---------------------------------------------------------------------------------------------
    // (4) Balance fuse switch on a vault with an open position
    // ---------------------------------------------------------------------------------------------

    /// @notice A vault on the slot0 fuse holds an open position; the pool spot is pushed above the range and a
    ///         refresh books the inflated value. `addBalanceFuse(18, oracleFuse)` replaces the fuse without any
    ///         storage migration and the next refresh books the oracle valuation of the same tracked position.
    function testShouldRevalueOpenVaultPositionAfterSwitchingToOracleFuse() external {
        // given
        PlasmaVault plasmaVault = _createVaultOnSlot0Fuse();
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_wethUsdcPool, _WETH_USDC_TICK_SPACING, 1_000);
        uint256 tokenId = _openVaultPosition(plasmaVault, tickLower, tickUpper);
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.RAMSES_V2_POSITIONS;

        uint256[] memory trackedTokenIds = new uint256[](1);
        trackedTokenIds[0] = tokenId;
        _vaultStorage.setTokenIds(trackedTokenIds);
        uint256 oracleValueBefore = _vaultStorage.balanceOfFuse(address(_oracleFuse));

        plasmaVault.updateMarketsBalances(marketIds);
        uint256 marketOnSlot0Fuse = plasmaVault.totalAssetsInMarket(IporFusionMarkets.RAMSES_V2_POSITIONS);
        assertEq(
            marketOnSlot0Fuse,
            _toUsdcUnderlying(_vaultStorage.balanceOfFuse(address(_spotFuse))),
            "vault books the slot0 fuse value"
        );

        // when: spot pushed above the range and refreshed on the slot0 fuse
        Swap memory swap = _swapToSqrtPrice(_wethUsdcPool, TickMath.getSqrtRatioAtTick(tickUpper + 200));
        plasmaVault.updateMarketsBalances(marketIds);
        assertGt(
            plasmaVault.totalAssetsInMarket(IporFusionMarkets.RAMSES_V2_POSITIONS),
            marketOnSlot0Fuse + marketOnSlot0Fuse / 100,
            "control: the slot0 fuse books an inflated market value"
        );

        // when: the atomist switches the market to the oracle fuse and the market is refreshed
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            address(_oracleFuse)
        );
        plasmaVault.updateMarketsBalances(marketIds);

        // then
        assertTrue(
            PlasmaVaultGovernance(address(plasmaVault)).isBalanceFuseSupported(
                IporFusionMarkets.RAMSES_V2_POSITIONS,
                address(_oracleFuse)
            ),
            "oracle fuse installed"
        );
        assertFalse(
            PlasmaVaultGovernance(address(plasmaVault)).isBalanceFuseSupported(
                IporFusionMarkets.RAMSES_V2_POSITIONS,
                address(_spotFuse)
            ),
            "slot0 fuse replaced"
        );
        uint256 oracleValueAfter = _vaultStorage.balanceOfFuse(address(_oracleFuse));
        assertEq(
            plasmaVault.totalAssetsInMarket(IporFusionMarkets.RAMSES_V2_POSITIONS),
            _toUsdcUnderlying(oracleValueAfter),
            "vault books the oracle fuse value of the tracked position"
        );
        assertGe(oracleValueAfter, oracleValueBefore, "oracle value can only grow by fees");
        assertLe(oracleValueAfter - oracleValueBefore, _swapFeeUsd(swap), "oracle value moved at most by fees");
    }

    // ---------------------------------------------------------------------------------------------
    // (5) Reverts: no fallback to slot0
    // ---------------------------------------------------------------------------------------------

    /// @notice A middleware without a WETH price reverts the oracle fuse for a WETH/USDC position; the same
    ///         middleware values a USDC/DAI position (control that the revert comes from the missing feed).
    function testShouldRevertWhenTokenHasNoPriceFeed() external {
        // given
        RamsesV2OracleBalanceForkTestVaultStorage vaultStorage = new RamsesV2OracleBalanceForkTestVaultStorage(
            address(_createPriceOracle(false))
        );
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcDaiPool, _USDC_DAI_TICK_SPACING, 20);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _mint(_USDC, _DAI, _USDC_DAI_FEE, tickLower, tickUpper, 25_000e6, 25_000e18);
        vaultStorage.setTokenIds(tokenIds);
        assertGt(vaultStorage.balanceOfFuse(address(_oracleFuse)), 0, "control: priced pair is valued");

        (tickLower, tickUpper) = _rangeAroundCurrentTick(_wethUsdcPool, _WETH_USDC_TICK_SPACING, 1_000);
        tokenIds[0] = _mint(_WETH, _USDC, _WETH_USDC_FEE, tickLower, tickUpper, 10e18, 25_000e6);
        vaultStorage.setTokenIds(tokenIds);

        // then
        vm.expectRevert(abi.encodeWithSelector(IPriceOracleMiddleware.UnsupportedAsset.selector));
        vaultStorage.balanceOfFuse(address(_oracleFuse));
    }

    /// @notice An oracle-implied raw price `token1 / token0 >= 2^128` reverts the oracle fuse; the slot0 fuse still
    ///         returns a value in the same state, so the oracle fuse does not fall back to the pool price.
    function testShouldRevertWhenOracleImpliedPriceIsOutOfQ64x96Range() external {
        // given
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcDaiPool, _USDC_DAI_TICK_SPACING, 20);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _mint(_USDC, _DAI, _USDC_DAI_FEE, tickLower, tickUpper, 25_000e6, 25_000e18);
        _vaultStorage.setTokenIds(tokenIds);
        vm.mockCall(
            address(_priceOracle),
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, _USDC),
            abi.encode(uint256(1e45), uint256(18))
        );

        // then
        assertGt(_vaultStorage.balanceOfFuse(address(_spotFuse)), 0, "control: slot0 fuse still values the position");
        vm.expectRevert(abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector));
        _vaultStorage.balanceOfFuse(address(_oracleFuse));
    }

    function testShouldRevertWhenPriceOracleMiddlewareIsNotSet() external {
        // given
        RamsesV2OracleBalanceForkTestVaultStorage vaultStorage = new RamsesV2OracleBalanceForkTestVaultStorage(
            address(0)
        );
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_wethUsdcPool, _WETH_USDC_TICK_SPACING, 1_000);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _mint(_WETH, _USDC, _WETH_USDC_FEE, tickLower, tickUpper, 10e18, 25_000e6);
        vaultStorage.setTokenIds(tokenIds);

        // then
        vm.expectRevert(
            abi.encodeWithSelector(RamsesV2OracleBalance.RamsesV2OracleBalancePriceOracleMiddlewareNotSet.selector)
        );
        vaultStorage.balanceOfFuse(address(_oracleFuse));
    }

    function testShouldReturnZeroWithoutTrackedPositions() external {
        // given: no middleware either, so a read of it would revert
        RamsesV2OracleBalanceForkTestVaultStorage vaultStorage = new RamsesV2OracleBalanceForkTestVaultStorage(
            address(0)
        );

        // then
        assertEq(vaultStorage.balanceOfFuse(address(_oracleFuse)), 0, "no tracked positions");
    }

    // ---------------------------------------------------------------------------------------------
    // Ramses V2 pool swap callback
    // ---------------------------------------------------------------------------------------------

    /// @dev Pays the pool for the manipulation swaps of this test
    function ramsesV2SwapCallback(int256 amount0Delta_, int256 amount1Delta_, bytes calldata data_) external {
        (address token0, address token1) = abi.decode(data_, (address, address));
        if (amount0Delta_ > 0) {
            IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta_));
        }
        if (amount1Delta_ > 0) {
            IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta_));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _assertSpotPushMovesOracleFuseAtMostByFees(bool pushAboveRange_) private {
        // given: an in-range WETH/USDC position with no fees earned yet
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_wethUsdcPool, _WETH_USDC_TICK_SPACING, 1_000);
        uint256 tokenId = _mint(_WETH, _USDC, _WETH_USDC_FEE, tickLower, tickUpper, 10e18, 25_000e6);
        Values memory before = _values(tokenId);
        uint160 oracleSqrtPriceBefore = _oracleSqrtPriceX96(_WETH, _USDC);

        // when: one swap pushes the pool spot past the range edge
        Swap memory swap = _swapToSqrtPrice(
            _wethUsdcPool,
            TickMath.getSqrtRatioAtTick(pushAboveRange_ ? tickUpper + 200 : tickLower - 200)
        );
        Values memory afterSwap = _values(tokenId);

        // then: the scenario reached the valuation and the oracle inputs are unchanged
        if (pushAboveRange_) {
            assertGe(_currentTick(_wethUsdcPool), tickUpper, "spot pushed above the range");
        } else {
            assertLt(_currentTick(_wethUsdcPool), tickLower, "spot pushed below the range");
        }
        assertEq(_oracleSqrtPriceX96(_WETH, _USDC), oracleSqrtPriceBefore, "oracle inputs unchanged by the swap");
        assertGt(afterSwap.spot, before.spot + before.spot / 100, "control: slot0 fuse value moved by more than 1%");

        // then: the oracle fuse moved only up, and at most by the fee the swap paid
        assertGe(afterSwap.oracle, before.oracle, "oracle fuse can only grow by fees");
        assertLe(afterSwap.oracle - before.oracle, _swapFeeUsd(swap), "oracle fuse moved at most by the swap fee");

        // when: the fees are collected
        (uint256 collected0, uint256 collected1) = _collect(tokenId);
        Values memory afterCollect = _values(tokenId);

        // then: the fees valued with the spot outside the range are what `collect` returned
        assertGt(collected0 + collected1, 0, "the swap credited fees to the position");
        _assertValuedFeesEqualCollected(afterSwap, afterCollect, _WETH, _USDC, collected0, collected1);

        // then: principal alone is unchanged for the oracle fuse, still moved for the slot0 fuse
        assertEq(afterCollect.oracle, before.oracle, "oracle fuse principal unchanged by the spot swap");
        assertGt(afterCollect.spot, before.spot + before.spot / 100, "control: slot0 fuse principal moved");
    }

    /// @dev Mints four positions of one pool into `tokenIds_` from `offset_`: in range, below range, above range and
    ///      full range. `width_` is the half-width of the in-range position in ticks; out-of-range positions sit
    ///      between 2 and 3 widths from the current tick.
    function _mintRangeSet(
        uint256[] memory tokenIds_,
        uint256 offset_,
        address pool_,
        int24 tickSpacing_,
        int24 width_,
        uint256 amount0_,
        uint256 amount1_
    ) private {
        address token0 = IUniswapV3Pool(pool_).token0();
        address token1 = IUniswapV3Pool(pool_).token1();
        uint24 fee = IUniswapV3Pool(pool_).fee();
        int24 tick = _currentTick(pool_);
        int24 maxTick = _alignDown(TickMath.MAX_TICK, tickSpacing_);

        tokenIds_[offset_] = _mint(
            token0,
            token1,
            fee,
            _alignDown(tick - width_, tickSpacing_),
            _alignDown(tick + width_, tickSpacing_),
            amount0_,
            amount1_
        );
        tokenIds_[offset_ + 1] = _mint(
            token0,
            token1,
            fee,
            _alignDown(tick - 3 * width_, tickSpacing_),
            _alignDown(tick - 2 * width_, tickSpacing_),
            amount0_,
            amount1_
        );
        tokenIds_[offset_ + 2] = _mint(
            token0,
            token1,
            fee,
            _alignDown(tick + 2 * width_, tickSpacing_),
            _alignDown(tick + 3 * width_, tickSpacing_),
            amount0_,
            amount1_
        );
        tokenIds_[offset_ + 3] = _mint(token0, token1, fee, -maxTick, maxTick, amount0_, amount1_);

        // the below-range position holds only token1 and the above-range position only token0
        assertGt(_position(tokenIds_[offset_ + 1]).liquidity, 0, "below-range position minted");
        assertGt(_position(tokenIds_[offset_ + 2]).liquidity, 0, "above-range position minted");
    }

    function _createVaultOnSlot0Fuse() private returns (PlasmaVault plasmaVault) {
        address accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(accessManager));

        plasmaVault = PlasmaVault(PlasmaVaultCloneLib.newPlasmaVault());
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvUSDC",
                _USDC,
                address(_priceOracle),
                FeeConfigHelper.createZeroFeeConfig(),
                accessManager,
                address(new PlasmaVaultBase()),
                withdrawManager,
                address(0)
            )
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(
            new RamsesV2NewPositionFuse(IporFusionMarkets.RAMSES_V2_POSITIONS, _NONFUNGIBLE_POSITION_MANAGER)
        );

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.RAMSES_V2_POSITIONS, address(_spotFuse));
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        bytes32[] memory tokens = new bytes32[](2);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        tokens[1] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.RAMSES_V2_POSITIONS, tokens);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(plasmaVault),
            fuses,
            balanceFuses,
            marketConfigs
        );

        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            address(plasmaVault),
            IporFusionAccessManager(accessManager),
            withdrawManager
        );

        uint256[] memory dependentMarkets = new uint256[](1);
        dependentMarkets[0] = IporFusionMarkets.RAMSES_V2_POSITIONS;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(dependentMarkets, dependencies);

        address depositor = makeAddr("depositor");
        deal(_USDC, depositor, 100_000e6);
        vm.startPrank(depositor);
        IERC20(_USDC).forceApprove(address(plasmaVault), 100_000e6);
        plasmaVault.deposit(100_000e6, depositor);
        vm.stopPrank();
        deal(_WETH, address(plasmaVault), 50e18);
    }

    function _createAccessManager() private returns (address) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        return address(RoleLib.createAccessManager(usersToRoles, 0, vm));
    }

    function _openVaultPosition(
        PlasmaVault plasmaVault_,
        int24 tickLower_,
        int24 tickUpper_
    ) private returns (uint256 tokenId) {
        address newPositionFuse = PlasmaVaultGovernance(address(plasmaVault_)).getFuses()[0];
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            newPositionFuse,
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
                RamsesV2NewPositionFuseEnterData({
                    token0: _WETH,
                    token1: _USDC,
                    fee: _WETH_USDC_FEE,
                    tickLower: tickLower_,
                    tickUpper: tickUpper_,
                    amount0Desired: 10e18,
                    amount1Desired: 25_000e6,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp,
                    veRamTokenId: 0
                })
            )
        );
        plasmaVault_.execute(calls);

        assertEq(IERC721Enumerable(_NONFUNGIBLE_POSITION_MANAGER).balanceOf(address(plasmaVault_)), 1, "one NFT");
        tokenId = IERC721Enumerable(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(address(plasmaVault_), 0);
    }

    /// @dev Middleware with explicit Chainlink feeds (Arbitrum has no feed registry): USDC, DAI and FRAX always, WETH
    ///      when `withWeth_` is true
    function _createPriceOracle(bool withWeth_) private returns (PriceOracleMiddleware priceOracle) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        address[] memory assets = new address[](withWeth_ ? 4 : 3);
        address[] memory sources = new address[](assets.length);
        assets[0] = _USDC;
        sources[0] = _CHAINLINK_USDC_USD;
        assets[1] = _DAI;
        sources[1] = _CHAINLINK_DAI_USD;
        assets[2] = _FRAX;
        sources[2] = _CHAINLINK_FRAX_USD;
        if (withWeth_) {
            assets[3] = _WETH;
            sources[3] = _CHAINLINK_ETH_USD;
        }
        priceOracle.setAssetsPricesSources(assets, sources);
    }

    /// @dev Mints a WETH/USDC position spanning 1000 ticks on each side of the current tick
    function _mintWethUsdcInRange() private returns (uint256 tokenId) {
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_wethUsdcPool, _WETH_USDC_TICK_SPACING, 1_000);
        tokenId = _mint(_WETH, _USDC, _WETH_USDC_FEE, tickLower, tickUpper, 10e18, 25_000e6);
    }

    function _mint(
        address token0_,
        address token1_,
        uint24 fee_,
        int24 tickLower_,
        int24 tickUpper_,
        uint256 amount0_,
        uint256 amount1_
    ) private returns (uint256 tokenId) {
        (tokenId, , , ) = INonfungiblePositionManagerRamses(_NONFUNGIBLE_POSITION_MANAGER).mint(
            INonfungiblePositionManagerRamses.MintParams({
                token0: token0_,
                token1: token1_,
                fee: fee_,
                tickLower: tickLower_,
                tickUpper: tickUpper_,
                amount0Desired: amount0_,
                amount1Desired: amount1_,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp,
                veRamTokenId: 0
            })
        );
    }

    /// @dev Adds a little liquidity; the position manager checkpoints the fees earned so far into `tokensOwed`
    function _increaseLiquidity(uint256 tokenId_, uint256 amount0_, uint256 amount1_) private {
        INonfungiblePositionManagerRamses(_NONFUNGIBLE_POSITION_MANAGER).increaseLiquidity(
            INonfungiblePositionManagerRamses.IncreaseLiquidityParams({
                tokenId: tokenId_,
                amount0Desired: amount0_,
                amount1Desired: amount1_,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _tokensOwed(uint256 tokenId_) private view returns (uint128 tokensOwed0, uint128 tokensOwed1) {
        INonfungiblePositionManagerRamses.Position memory position = _position(tokenId_);
        return (position.tokensOwed0, position.tokensOwed1);
    }

    function _position(
        uint256 tokenId_
    ) private view returns (INonfungiblePositionManagerRamses.Position memory position) {
        (bool success, bytes memory data) = _NONFUNGIBLE_POSITION_MANAGER.staticcall(
            abi.encodeWithSelector(INonfungiblePositionManagerRamses.positions.selector, tokenId_)
        );
        assertTrue(success, "positions read");
        position = abi.decode(data, (INonfungiblePositionManagerRamses.Position));
    }

    /// @dev The checkpoint the WETH/USDC pool stores for `PositionKey.compute(owner_, tokenId_, ticks of position_)`
    function _poolCheckpoint(
        address owner_,
        uint256 tokenId_,
        INonfungiblePositionManagerRamses.Position memory position_
    ) private view returns (Checkpoint memory checkpoint) {
        (
            checkpoint.liquidity,
            checkpoint.feeGrowthInside0LastX128,
            checkpoint.feeGrowthInside1LastX128,
            ,
            ,

        ) = IRamsesV2Pool(_wethUsdcPool).positions(
            PositionKey.compute(owner_, tokenId_, position_.tickLower, position_.tickUpper)
        );
    }

    function _collect(uint256 tokenId_) private returns (uint256 amount0, uint256 amount1) {
        return
            INonfungiblePositionManagerRamses(_NONFUNGIBLE_POSITION_MANAGER).collect(
                INonfungiblePositionManagerRamses.CollectParams({
                    tokenId: tokenId_,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
    }

    /// @dev Swaps the pool `ticks_` ticks up and back to its exact starting price, so in-range positions earn fees in
    ///      both tokens and the pool ends where it started
    function _roundTripSwaps(address pool_, int24 ticks_) private {
        (uint160 startSqrtPriceX96, int24 startTick, , , , , ) = IUniswapV3Pool(pool_).slot0();
        _swapToSqrtPrice(pool_, TickMath.getSqrtRatioAtTick(startTick + ticks_));
        _swapToSqrtPrice(pool_, startSqrtPriceX96);
    }

    /// @dev One direct swap against the live pool to an exact target price, the mechanism a flash-loan attacker
    ///      uses (only capital, no role). Asserts that the pool reached the target.
    function _swapToSqrtPrice(address pool_, uint160 targetSqrtPriceX96_) private returns (Swap memory swap) {
        IUniswapV3Pool pool = IUniswapV3Pool(pool_);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        swap.fee = pool.fee();
        if (sqrtPriceX96 == targetSqrtPriceX96_) {
            return swap;
        }

        bool zeroForOne = targetSqrtPriceX96_ < sqrtPriceX96;
        address token0 = pool.token0();
        address token1 = pool.token1();
        swap.tokenIn = zeroForOne ? token0 : token1;
        deal(swap.tokenIn, address(this), IERC20(swap.tokenIn).balanceOf(address(this)) + _SWAP_BUDGET);

        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            type(int128).max,
            targetSqrtPriceX96_,
            abi.encode(token0, token1)
        );
        swap.amountIn = uint256(zeroForOne ? amount0 : amount1);

        (sqrtPriceX96, , , , , , ) = pool.slot0();
        assertEq(sqrtPriceX96, targetSqrtPriceX96_, "swap reached the target price");
    }

    function _moveToOraclePrice(address pool_) private {
        _swapToSqrtPrice(pool_, _oracleSqrtPriceX96(IUniswapV3Pool(pool_).token0(), IUniswapV3Pool(pool_).token1()));
    }

    function _values(uint256 tokenId_) private returns (Values memory) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId_;
        return _valuesOf(tokenIds);
    }

    function _valuesOf(uint256[] memory tokenIds_) private returns (Values memory values) {
        _vaultStorage.setTokenIds(tokenIds_);
        values.spot = _vaultStorage.balanceOfFuse(address(_spotFuse));
        values.oracle = _vaultStorage.balanceOfFuse(address(_oracleFuse));
    }

    function _oracleSqrtPriceX96(address token0_, address token1_) private view returns (uint160) {
        return OracleSqrtPriceX96Lib.fromOracle(token0_, token1_, address(_priceOracle));
    }

    /// @dev Asserts that each fuse's value dropped by `collect` by the USD value of the collected amounts: the fees
    ///      valued before `collect` are what `collect` returned, within `_COLLECT_ROUNDING` wei of each token plus the
    ///      floor rounding of the two legs. `collect` changes neither the liquidity nor the pool price, so the
    ///      principal is the same in both states.
    function _assertValuedFeesEqualCollected(
        Values memory beforeCollect_,
        Values memory afterCollect_,
        address token0_,
        address token1_,
        uint256 collected0_,
        uint256 collected1_
    ) private view {
        uint256 collectedUsd = _usd(token0_, collected0_) + _usd(token1_, collected1_);
        uint256 tolerance = _usd(token0_, _COLLECT_ROUNDING) + _usd(token1_, _COLLECT_ROUNDING) + _LEG_ROUNDING;

        assertGt(collectedUsd, tolerance, "control: collected fees above the rounding tolerance");
        assertGe(beforeCollect_.spot, afterCollect_.spot, "slot0 fuse: collect does not raise the value");
        assertGe(beforeCollect_.oracle, afterCollect_.oracle, "oracle fuse: collect does not raise the value");
        assertApproxEqAbs(
            beforeCollect_.spot - afterCollect_.spot,
            collectedUsd,
            tolerance,
            "slot0 fuse: fees valued before collect = collected fees"
        );
        assertApproxEqAbs(
            beforeCollect_.oracle - afterCollect_.oracle,
            collectedUsd,
            tolerance,
            "oracle fuse: fees valued before collect = collected fees"
        );
    }

    /// @dev USD (WAD) value of a token amount at the test middleware price, as the fuses compute it
    function _usd(address token_, uint256 amount_) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = _priceOracle.getAssetPrice(token_);
        return IporMath.convertToWad(amount_ * price, IERC20Metadata(token_).decimals() + priceDecimals);
    }

    /// @dev Upper bound of the fee a swap paid into the pool, in USD (WAD); the position's share cannot exceed it
    function _swapFeeUsd(Swap memory swap_) private view returns (uint256) {
        return _usd(swap_.tokenIn, (swap_.amountIn * swap_.fee) / 1e6 + _SWAP_FEE_ROUNDING) + _LEG_ROUNDING;
    }

    /// @dev USD (WAD) to USDC units, as `PlasmaVaultMarketsLib.updateMarketsBalances` converts a market balance
    function _toUsdcUnderlying(uint256 wadUsd_) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = _priceOracle.getAssetPrice(_USDC);
        return
            IporMath.convertWadToAssetDecimals(
                IporMath.division(wadUsd_ * IporMath.BASIS_OF_POWER ** priceDecimals, price),
                6
            );
    }

    function _rangeAroundCurrentTick(
        address pool_,
        int24 tickSpacing_,
        int24 halfWidth_
    ) private view returns (int24 tickLower, int24 tickUpper) {
        int24 tick = _currentTick(pool_);
        tickLower = _alignDown(tick - halfWidth_, tickSpacing_);
        tickUpper = _alignDown(tick + halfWidth_, tickSpacing_);
    }

    function _currentTick(address pool_) private view returns (int24 tick) {
        (, tick, , , , , ) = IUniswapV3Pool(pool_).slot0();
    }

    function _alignDown(int24 tick_, int24 tickSpacing_) private pure returns (int24) {
        int24 compressed = tick_ / tickSpacing_;
        if (tick_ < 0 && tick_ % tickSpacing_ != 0) {
            --compressed;
        }
        return compressed * tickSpacing_;
    }
}
