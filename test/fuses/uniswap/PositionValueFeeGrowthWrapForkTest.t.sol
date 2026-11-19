// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IUniswapV3Pool as IUniswapV3PoolCore} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {FuseStorageLib} from "../../../contracts/libraries/FuseStorageLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {UniswapV3Balance} from "../../../contracts/fuses/uniswap/UniswapV3Balance.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3Factory
} from "../../../contracts/fuses/uniswap/ext/INonfungiblePositionManager.sol";
import {PositionValue} from "../../../contracts/fuses/uniswap/ext/PositionValue.sol";
import {TickMath} from "../../../contracts/fuses/uniswap/ext/TickMath.sol";

/// @dev Holds the two pieces of vault storage a Uniswap V3 balance fuse reads (the tracked token ID list and the
///      price oracle middleware) and runs a fuse's `balanceOf` by delegatecall, the way a PlasmaVault does.
contract PositionValueFeeGrowthWrapForkTestVaultStorage {
    using Address for address;

    constructor(address priceOracleMiddleware_) {
        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    function setTokenIds(uint256[] calldata tokenIds_) external {
        FuseStorageLib.getUniswapV3TokenIds().tokenIds = tokenIds_;
    }

    function balanceOfFuse(address fuse_) external returns (uint256) {
        return abi.decode(fuse_.functionDelegateCall(abi.encodeWithSignature("balanceOf()")), (uint256));
    }
}

/// @title PositionValueFeeGrowthWrapForkTest
/// @notice IL-9590 D-048: `PositionValue` computes the fee growth inside a Uniswap V3 range modulo 2^256, as Uniswap
///         does. On the USDC/WETH 0.05% pool at the fork block the ticks 197020 and 199020 are initialized and their
///         fee growth outside values sum above the pool's global fee growth, so the true fee growth inside wraps
///         below zero. Before the fix the library clamped it to zero and `0 - feeGrowthInsideLast` reverted with an
///         arithmetic panic, which made `UniswapV3Balance` and `UniswapV3OracleBalance` revert for such a position.
/// @dev Ethereum fork at its own block (20639327). Every scenario asserts in the same state that the range's fee
///      growth inside wraps (or, for the control range, does not), so the tests reach the modular arithmetic.
///      `UniswapV3OracleBalance` is deployed from its artifact (`deployCode`) because it does not exist on the audited
///      base commit; tests that use it carry `OracleFuse` in their name.
contract PositionValueFeeGrowthWrapForkTest is Test {
    using SafeERC20 for IERC20;

    uint256 private constant _FORK_BLOCK = 20639327;

    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _USDC_WETH_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address private constant _UNISWAP_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address private constant _CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    string private constant _ORACLE_FUSE_ARTIFACT = "UniswapV3OracleBalance.sol:UniswapV3OracleBalance";

    uint24 private constant _POOL_FEE = 500;
    int24 private constant _TICK_SPACING = 10;

    /// @dev Range whose fee growth inside wraps below zero at the fork block, for token0 and token1
    int24 private constant _WRAP_TICK_LOWER = 197020;
    int24 private constant _WRAP_TICK_UPPER = 199020;
    /// @dev Half-width in ticks of the control range on uninitialized ticks around the current tick
    int24 private constant _FRESH_HALF_WIDTH = 1_000;
    /// @dev Ticks the round-trip swap moves the price up before moving it back; stays inside both ranges
    int24 private constant _ROUND_TRIP_TICKS = 300;
    /// @dev Ticks the spot is pushed past a range edge when leaving the range
    int24 private constant _OUT_OF_RANGE_TICKS = 200;

    uint256 private constant _AMOUNT0 = 25_000e6;
    uint256 private constant _AMOUNT1 = 10e18;

    /// @dev Input budget dealt before every swap; far above what any swap in these tests consumes
    uint256 private constant _SWAP_BUDGET = 1e30;
    /// @dev Maximum difference in wei between the fees `PositionValue` values and the fees `collect` pays
    uint256 private constant _FEE_TOLERANCE = 2;
    /// @dev Slack for the floor rounding of two independently converted token legs (USD, WAD)
    uint256 private constant _LEG_ROUNDING = 2;
    /// @dev Maximum relative difference between the oracle fuse and the slot0 fuse on the untouched fork pool (1%)
    uint256 private constant _ORACLE_VS_SLOT0_TOLERANCE = 1e16;
    /// @dev Maximum number of tick-spacing steps searched for an uninitialized tick
    uint256 private constant _FRESH_TICK_SEARCH_STEPS = 50;

    INonfungiblePositionManager private constant _POSITION_MANAGER =
        INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER);
    IUniswapV3PoolCore private constant _POOL = IUniswapV3PoolCore(_USDC_WETH_POOL);

    PriceOracleMiddleware private _priceOracle;
    UniswapV3Balance private _slot0Fuse;
    PositionValueFeeGrowthWrapForkTestVaultStorage private _vaultStorage;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        _priceOracle = _createPriceOracle();
        _slot0Fuse = new UniswapV3Balance(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER,
            _UNISWAP_FACTORY
        );
        _vaultStorage = new PositionValueFeeGrowthWrapForkTestVaultStorage(address(_priceOracle));

        assertEq(
            IUniswapV3Factory(_UNISWAP_FACTORY).getPool(_USDC, _WETH, _POOL_FEE),
            _USDC_WETH_POOL,
            "USDC/WETH 0.05% pool"
        );
        assertEq(_POOL.token0(), _USDC, "USDC is token0");

        deal(_USDC, address(this), 10_000_000e6);
        deal(_WETH, address(this), 10_000e18);
        IERC20(_USDC).forceApprove(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
        IERC20(_WETH).forceApprove(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // (1) A range whose fee growth inside wraps is valued, not reverted
    // ---------------------------------------------------------------------------------------------

    /// @notice The repro position (ticks 197020/199020, 25k USDC + 10 WETH): `UniswapV3Balance` values it at its
    ///         principal (a freshly minted position owes no fees) instead of reverting with an arithmetic panic.
    function testShouldValueWrappedFeeGrowthPositionWithSlot0Fuse() external {
        // given
        uint256 tokenId = _mint(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);
        int24 tick = _currentTick();
        assertTrue(tick >= _WRAP_TICK_LOWER && tick < _WRAP_TICK_UPPER, "position in range");
        _assertFeeGrowthInsideWraps(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);

        // when
        uint256 value = _valueOf(tokenId, address(_slot0Fuse));

        // then
        (uint256 fees0, uint256 fees1) = PositionValue.fees(_POSITION_MANAGER, tokenId);
        assertEq(fees0, 0, "fresh position owes no token0 fees");
        assertEq(fees1, 0, "fresh position owes no token1 fees");

        (uint160 sqrtPriceX96, , , , , , ) = _POOL.slot0();
        (uint256 principal0, uint256 principal1) = PositionValue.principal(_POSITION_MANAGER, tokenId, sqrtPriceX96);
        assertGt(principal0, 0, "token0 principal");
        assertGt(principal1, 0, "token1 principal");
        assertEq(value, _usd(_USDC, principal0) + _usd(_WETH, principal1), "slot0 fuse value = principal at slot0");
    }

    /// @notice The same repro position is valued by `UniswapV3OracleBalance` (which reads fees through the same
    ///         library), close to the slot0 fuse on the untouched fork pool.
    function testShouldValueWrappedFeeGrowthPositionWithOracleFuse() external {
        // given
        address oracleFuse = _deployOracleFuse();
        uint256 tokenId = _mint(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);
        _assertFeeGrowthInsideWraps(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);

        // when
        uint256 oracleValue = _valueOf(tokenId, oracleFuse);

        // then
        assertGt(oracleValue, 0, "position has value");
        assertApproxEqRel(
            oracleValue,
            _valueOf(tokenId, address(_slot0Fuse)),
            _ORACLE_VS_SLOT0_TOLERANCE,
            "oracle fuse close to the slot0 fuse"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // (2) Valued fees equal collected fees, for a wrapped and a normal range
    // ---------------------------------------------------------------------------------------------

    /// @notice After a round trip of swaps inside both ranges, the fees `PositionValue` values and the fee part of
    ///         the slot0 fuse equal what `collect` pays, for the wrapped range and for a range on fresh ticks.
    function testShouldValueFeesAsCollectedInRangeForWrappedAndFreshRanges() external {
        // given
        (uint256 wrappedTokenId, uint256 freshTokenId, int24 freshLower, int24 freshUpper) = _mintWrappedAndFresh();

        // when
        _roundTripSwap();

        // then
        _assertFeeGrowthInsideWraps(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);
        _assertFeeGrowthInsideDoesNotWrap(freshLower, freshUpper);
        _assertFeesValuedAsCollected(wrappedTokenId, address(_slot0Fuse), true, true);
        _assertFeesValuedAsCollected(freshTokenId, address(_slot0Fuse), true, true);
    }

    /// @notice The same parity for the oracle fuse.
    function testShouldValueFeesAsCollectedInRangeForWrappedAndFreshRangesWithOracleFuse() external {
        // given
        address oracleFuse = _deployOracleFuse();
        (uint256 wrappedTokenId, uint256 freshTokenId, int24 freshLower, int24 freshUpper) = _mintWrappedAndFresh();

        // when
        _roundTripSwap();

        // then
        _assertFeeGrowthInsideWraps(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);
        _assertFeeGrowthInsideDoesNotWrap(freshLower, freshUpper);
        _assertFeesValuedAsCollected(wrappedTokenId, oracleFuse, true, true);
        _assertFeesValuedAsCollected(freshTokenId, oracleFuse, true, true);
    }

    /// @notice The spot leaves both ranges upwards (fees accrue in token1), then downwards (fees accrue in token0):
    ///         in the above-range and below-range cases the wrapped range is still valued and its fees still equal
    ///         what `collect` pays; the fresh range is the control.
    function testShouldValueFeesAsCollectedAboveAndBelowRangeForWrappedAndFreshRanges() external {
        // given
        (uint256 wrappedTokenId, uint256 freshTokenId, int24 freshLower, int24 freshUpper) = _mintWrappedAndFresh();

        // when: spot pushed above both ranges
        _swapToSqrtPrice(TickMath.getSqrtRatioAtTick(_max(_WRAP_TICK_UPPER, freshUpper) + _OUT_OF_RANGE_TICKS));

        // then
        assertGe(_currentTick(), _max(_WRAP_TICK_UPPER, freshUpper), "spot above both ranges");
        _assertFeeGrowthInsideWraps(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);
        _assertFeeGrowthInsideDoesNotWrap(freshLower, freshUpper);
        _assertFeesValuedAsCollected(wrappedTokenId, address(_slot0Fuse), false, true);
        _assertFeesValuedAsCollected(freshTokenId, address(_slot0Fuse), false, true);

        // when: spot pushed below both ranges
        _swapToSqrtPrice(TickMath.getSqrtRatioAtTick(_min(_WRAP_TICK_LOWER, freshLower) - _OUT_OF_RANGE_TICKS));

        // then
        assertLt(_currentTick(), _min(_WRAP_TICK_LOWER, freshLower), "spot below both ranges");
        _assertFeeGrowthInsideWraps(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);
        _assertFeeGrowthInsideDoesNotWrap(freshLower, freshUpper);
        _assertFeesValuedAsCollected(wrappedTokenId, address(_slot0Fuse), true, false);
        _assertFeesValuedAsCollected(freshTokenId, address(_slot0Fuse), true, false);
    }

    // ---------------------------------------------------------------------------------------------
    // Uniswap V3 pool swap callback
    // ---------------------------------------------------------------------------------------------

    /// @dev Pays the pool for the swaps of this test
    function uniswapV3SwapCallback(int256 amount0Delta_, int256 amount1Delta_, bytes calldata) external {
        if (amount0Delta_ > 0) {
            IERC20(_USDC).safeTransfer(msg.sender, uint256(amount0Delta_));
        }
        if (amount1Delta_ > 0) {
            IERC20(_WETH).safeTransfer(msg.sender, uint256(amount1Delta_));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Values the fees of a position with `PositionValue.fees` and with `fuse_` (value before collect minus
    ///      value after collect; collect changes neither the price nor the liquidity, so only the fee part moves),
    ///      collects them and checks both against the collected amounts. `expectFees0_`/`expectFees1_` require that
    ///      the scenario accrued fees in that token, so the parity is not checked on zero amounts only.
    function _assertFeesValuedAsCollected(
        uint256 tokenId_,
        address fuse_,
        bool expectFees0_,
        bool expectFees1_
    ) private {
        (uint256 fees0, uint256 fees1) = PositionValue.fees(_POSITION_MANAGER, tokenId_);
        uint256 valueWithFees = _valueOf(tokenId_, fuse_);

        (uint256 collected0, uint256 collected1) = _collect(tokenId_);
        uint256 valueWithoutFees = _valueOf(tokenId_, fuse_);

        if (expectFees0_) {
            assertGt(collected0, 0, "token0 fees accrued");
        }
        if (expectFees1_) {
            assertGt(collected1, 0, "token1 fees accrued");
        }
        assertApproxEqAbs(fees0, collected0, _FEE_TOLERANCE, "token0 fees valued = collected");
        assertApproxEqAbs(fees1, collected1, _FEE_TOLERANCE, "token1 fees valued = collected");

        assertGe(valueWithFees, valueWithoutFees, "collect does not raise the value");
        assertApproxEqAbs(
            valueWithFees - valueWithoutFees,
            _usd(_USDC, collected0) + _usd(_WETH, collected1),
            _LEG_ROUNDING,
            "fuse fee part = USD value of the collected fees"
        );

        (fees0, fees1) = PositionValue.fees(_POSITION_MANAGER, tokenId_);
        assertEq(fees0, 0, "no token0 fees left after collect");
        assertEq(fees1, 0, "no token1 fees left after collect");
    }

    function _assertFeeGrowthInsideWraps(int24 tickLower_, int24 tickUpper_) private view {
        (bool wraps0, bool wraps1) = _feeGrowthInsideWraps(tickLower_, tickUpper_);
        assertTrue(wraps0, "token0 fee growth inside wraps below zero");
        assertTrue(wraps1, "token1 fee growth inside wraps below zero");
    }

    function _assertFeeGrowthInsideDoesNotWrap(int24 tickLower_, int24 tickUpper_) private view {
        (bool wraps0, bool wraps1) = _feeGrowthInsideWraps(tickLower_, tickUpper_);
        assertFalse(wraps0, "control: token0 fee growth inside does not wrap");
        assertFalse(wraps1, "control: token1 fee growth inside does not wrap");
    }

    /// @dev Whether the true (integer) fee growth inside the range is below zero in the current pool state, i.e.
    ///      whether Uniswap's formula for the current tick (below, inside or above the range) underflows
    function _feeGrowthInsideWraps(int24 tickLower_, int24 tickUpper_) private view returns (bool, bool) {
        int24 tick = _currentTick();
        (, , uint256 lower0, uint256 lower1, , , , ) = _POOL.ticks(tickLower_);
        (, , uint256 upper0, uint256 upper1, , , , ) = _POOL.ticks(tickUpper_);
        if (tick < tickLower_) {
            return (lower0 < upper0, lower1 < upper1);
        }
        if (tick >= tickUpper_) {
            return (upper0 < lower0, upper1 < lower1);
        }
        return (
            _sumAbove(lower0, upper0, _POOL.feeGrowthGlobal0X128()),
            _sumAbove(lower1, upper1, _POOL.feeGrowthGlobal1X128())
        );
    }

    /// @dev `a_ + b_ > c_` without overflowing
    function _sumAbove(uint256 a_, uint256 b_, uint256 c_) private pure returns (bool) {
        return a_ > c_ || b_ > c_ - a_;
    }

    /// @dev Mints the wrapped range and a range on uninitialized ticks around the current tick (fee growth inside
    ///      starts at zero there and never wraps)
    function _mintWrappedAndFresh()
        private
        returns (uint256 wrappedTokenId, uint256 freshTokenId, int24 freshLower, int24 freshUpper)
    {
        wrappedTokenId = _mint(_WRAP_TICK_LOWER, _WRAP_TICK_UPPER);
        int24 tick = _currentTick();
        freshLower = _freshTick(tick - _FRESH_HALF_WIDTH, false);
        freshUpper = _freshTick(tick + _FRESH_HALF_WIDTH, true);
        freshTokenId = _mint(freshLower, freshUpper);
        assertTrue(tick >= _WRAP_TICK_LOWER && tick < _WRAP_TICK_UPPER, "wrapped range in range");
        assertTrue(tick >= freshLower && tick < freshUpper, "fresh range in range");
    }

    /// @dev Swaps the price up by `_ROUND_TRIP_TICKS` and back to the exact starting price; both legs stay inside
    ///      both ranges, so both tokens accrue fees and the principal is unchanged
    function _roundTripSwap() private {
        (uint160 startSqrtPriceX96, int24 startTick, , , , , ) = _POOL.slot0();
        _swapToSqrtPrice(TickMath.getSqrtRatioAtTick(startTick + _ROUND_TRIP_TICKS));
        _swapToSqrtPrice(startSqrtPriceX96);
        assertEq(_currentTick(), startTick, "round trip ends at the starting tick");
    }

    function _deployOracleFuse() private returns (address) {
        return
            deployCode(
                _ORACLE_FUSE_ARTIFACT,
                abi.encode(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS, _NONFUNGIBLE_POSITION_MANAGER)
            );
    }

    function _createPriceOracle() private returns (PriceOracleMiddleware priceOracle) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_FEED_REGISTRY);
        priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = _WETH;
        sources[0] = _CHAINLINK_ETH_USD;
        priceOracle.setAssetsPricesSources(assets, sources);
    }

    function _mint(int24 tickLower_, int24 tickUpper_) private returns (uint256 tokenId) {
        (tokenId, , , ) = _POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: _USDC,
                token1: _WETH,
                fee: _POOL_FEE,
                tickLower: tickLower_,
                tickUpper: tickUpper_,
                amount0Desired: _AMOUNT0,
                amount1Desired: _AMOUNT1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _collect(uint256 tokenId_) private returns (uint256 amount0, uint256 amount1) {
        return
            _POSITION_MANAGER.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId_,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
    }

    /// @dev One direct swap against the live pool to an exact target price. Asserts that the pool reached it.
    function _swapToSqrtPrice(uint160 targetSqrtPriceX96_) private {
        (uint160 sqrtPriceX96, , , , , , ) = _POOL.slot0();
        if (sqrtPriceX96 == targetSqrtPriceX96_) {
            return;
        }

        bool zeroForOne = targetSqrtPriceX96_ < sqrtPriceX96;
        address tokenIn = zeroForOne ? _USDC : _WETH;
        deal(tokenIn, address(this), IERC20(tokenIn).balanceOf(address(this)) + _SWAP_BUDGET);
        _POOL.swap(address(this), zeroForOne, type(int128).max, targetSqrtPriceX96_, "");

        (sqrtPriceX96, , , , , , ) = _POOL.slot0();
        assertEq(sqrtPriceX96, targetSqrtPriceX96_, "swap reached the target price");
    }

    function _valueOf(uint256 tokenId_, address fuse_) private returns (uint256) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId_;
        _vaultStorage.setTokenIds(tokenIds);
        return _vaultStorage.balanceOfFuse(fuse_);
    }

    /// @dev USD (WAD) value of a token amount at the test middleware price, as the fuses compute it
    function _usd(address token_, uint256 amount_) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = _priceOracle.getAssetPrice(token_);
        return IporMath.convertToWad(amount_ * price, IERC20Metadata(token_).decimals() + priceDecimals);
    }

    /// @dev First uninitialized tick from `tick_` (aligned down to the spacing), searching away from the price
    function _freshTick(int24 tick_, bool searchUp_) private view returns (int24 tick) {
        tick = _alignDown(tick_);
        bool initialized;
        for (uint256 i; i < _FRESH_TICK_SEARCH_STEPS; ++i) {
            (, , , , , , , initialized) = _POOL.ticks(tick);
            if (!initialized) {
                return tick;
            }
            tick = searchUp_ ? tick + _TICK_SPACING : tick - _TICK_SPACING;
        }
        assertFalse(initialized, "uninitialized tick found");
    }

    function _currentTick() private view returns (int24 tick) {
        (, tick, , , , , ) = _POOL.slot0();
    }

    function _alignDown(int24 tick_) private pure returns (int24) {
        int24 compressed = tick_ / _TICK_SPACING;
        if (tick_ < 0 && tick_ % _TICK_SPACING != 0) {
            --compressed;
        }
        return compressed * _TICK_SPACING;
    }

    function _max(int24 a_, int24 b_) private pure returns (int24) {
        return a_ > b_ ? a_ : b_;
    }

    function _min(int24 a_, int24 b_) private pure returns (int24) {
        return a_ < b_ ? a_ : b_;
    }
}
