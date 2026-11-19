// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {FuseAction, PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {OracleSqrtPriceX96Lib} from "../../../contracts/libraries/math/OracleSqrtPriceX96Lib.sol";
import {UniswapV4NewPositionFuseEnterData} from "../../../contracts/fuses/uniswap/UniswapV4NewPositionFuse.sol";
import {
    UniswapV4CollectFuse,
    UniswapV4CollectFuseEnterData
} from "../../../contracts/fuses/uniswap/UniswapV4CollectFuse.sol";
import {UniswapV4OracleBalance} from "../../../contracts/fuses/uniswap/UniswapV4OracleBalance.sol";

import {UniswapV4TestBase} from "./UniswapV4TestBase.sol";

/// @title UniswapV4OracleBalanceForkTest
/// @notice Base fork tests of the oracle version of the Uniswap V4 balance fuse (IL-9605, M15): the position
/// composition is taken from the oracle-implied price, so a same-transaction pool swap does not move the
/// principal, while the slot0 version (`UniswapV4Balance`, installed by the base) does.
/// @dev Uses its own fork block (`_forkBlock` hook) so it does not share a fork backend with the other V4 suites.
/// Every test starts with both workhorse pools moved exactly to the oracle-implied price (`setUp`), so the two
/// fuse versions value a fresh position identically. Values are compared through the vault
/// (`updateMarketsBalances` + `totalAssetsInMarket`, underlying USDC units) after switching the market balance
/// fuse with `addBalanceFuse`.
contract UniswapV4OracleBalanceForkTest is UniswapV4TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Own Base fork block (FORK_BLOCK of the base suite + 1)
    uint256 private constant ORACLE_BALANCE_FORK_BLOCK = 32_889_331;

    /// @dev ERC-7201 slot of FuseStorageLib.UniswapV4TokenIds (io.ipor.UniswapV4TokenIds)
    bytes32 private constant UNISWAP_V4_TOKEN_IDS_SLOT =
        0xa0cb9820b479943d568ab227efebaab415b98a8a6852b9c25e27d9ce5c481900;

    /// @dev Tolerance in underlying (USDC, 6 decimals) units for comparing independently rounded conversions
    uint256 private constant ROUNDING_TOLERANCE = 3;

    /// @dev Raw-unit slack on the swap fee bound: the pool rounds the fee up once per swap step
    uint256 private constant FEE_STEP_ROUNDING_SLACK = 100;

    /// @dev Position half-width in ticks used by the manipulation scenarios
    int24 private constant RANGE = 300;

    UniswapV4OracleBalance internal _oracleBalanceFuse;
    address internal _activeBalanceFuse;

    function setUp() public override {
        super.setUp();

        _oracleBalanceFuse = new UniswapV4OracleBalance(IporFusionMarkets.UNISWAP_V4, POSITION_MANAGER, POOL_MANAGER);
        _activeBalanceFuse = address(_balanceFuse);

        IporFusionAccessManager(_accessManager).grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, address(this), 0);

        _swapToSqrtPrice(_wethUsdcKey, _oracleSqrtPriceX96(_wethUsdcKey));
        _swapToSqrtPrice(_usdcCbbtcKey, _oracleSqrtPriceX96(_usdcCbbtcKey));
    }

    function _forkBlock() internal pure override returns (uint256) {
        return ORACLE_BALANCE_FORK_BLOCK;
    }

    // ------------------------------------------------------------------
    // constructor and direct calls
    // ------------------------------------------------------------------

    function testShouldRevertConstructorOnZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(UniswapV4OracleBalance.UniswapV4OracleBalanceZeroAddress.selector));
        new UniswapV4OracleBalance(IporFusionMarkets.UNISWAP_V4, address(0), POOL_MANAGER);

        vm.expectRevert(abi.encodeWithSelector(UniswapV4OracleBalance.UniswapV4OracleBalanceZeroAddress.selector));
        new UniswapV4OracleBalance(IporFusionMarkets.UNISWAP_V4, POSITION_MANAGER, address(0));
    }

    function testShouldExposeConstructorParameters() external view {
        assertEq(_oracleBalanceFuse.MARKET_ID(), IporFusionMarkets.UNISWAP_V4, "market id");
        assertEq(_oracleBalanceFuse.MARKET_ID(), _balanceFuse.MARKET_ID(), "same market as the slot0 fuse");
        assertEq(_oracleBalanceFuse.VERSION(), address(_oracleBalanceFuse), "version");
        assertEq(_oracleBalanceFuse.POSITION_MANAGER(), POSITION_MANAGER, "position manager");
        assertEq(address(_oracleBalanceFuse.POOL_MANAGER()), POOL_MANAGER, "pool manager");
    }

    function testShouldRevertWhenPriceOracleMiddlewareNotSet() external {
        // given — a direct call reads the fuse contract's own storage: no tracked tokenIds yet -> zero
        assertEq(_oracleBalanceFuse.balanceOf(), 0, "empty tokenId list -> zero");

        // one tracked tokenId and no price oracle middleware in the fuse contract's own storage
        vm.store(address(_oracleBalanceFuse), UNISWAP_V4_TOKEN_IDS_SLOT, bytes32(uint256(1)));
        vm.store(address(_oracleBalanceFuse), keccak256(abi.encode(UNISWAP_V4_TOKEN_IDS_SLOT)), bytes32(uint256(1)));

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4OracleBalance.UniswapV4OracleBalancePriceOracleMiddlewareNotSet.selector)
        );
        _oracleBalanceFuse.balanceOf();
    }

    function testShouldReturnZeroWhenNoPositions() external {
        assertEq(_marketValueWith(address(_oracleBalanceFuse)), 0, "no positions -> zero market balance");
    }

    // ------------------------------------------------------------------
    // (1) parity with the slot0 fuse when the pool is at the oracle price
    // ------------------------------------------------------------------

    function testShouldMatchSlot0FuseInRangeAtOraclePriceWethUsdc() external {
        // given — pool at the oracle-implied price (setUp)
        _openPosition(_wethUsdcKey, RANGE, 2e18, 6_000e6);

        // when
        uint256 oldValue = _marketValueWith(address(_balanceFuse));
        uint256 newValue = _marketValueWith(address(_oracleBalanceFuse));

        // then
        assertGt(newValue, 0, "position valued");
        assertEq(newValue, oldValue, "oracle fuse equals slot0 fuse at the oracle price (18/6 decimals)");
    }

    function testShouldMatchSlot0FuseInRangeAtOraclePriceUsdcCbbtcMixedDecimals() external {
        // given — pool at the oracle-implied price (setUp), 6/8 decimals
        _openPosition(_usdcCbbtcKey, RANGE, 20_000e6, 20e6);

        // when
        uint256 oldValue = _marketValueWith(address(_balanceFuse));
        uint256 newValue = _marketValueWith(address(_oracleBalanceFuse));

        // then
        assertGt(newValue, 0, "position valued");
        assertEq(newValue, oldValue, "oracle fuse equals slot0 fuse at the oracle price (6/8 decimals)");
    }

    function testShouldMatchSlot0FuseForOutOfRangeAndFullRangePositions() external {
        (, int24 wethUsdcTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());
        (, int24 usdcCbbtcTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_usdcCbbtcKey.toId());

        // given — range below the current tick: token1 only (USDC of WETH/USDC)
        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        _enterPosition(_wethUsdcKey, wethUsdcTick - 2 * RANGE, wethUsdcTick - RANGE, 0, 3_000e6);
        uint256 belowRangeSpent = usdcBefore - ERC20(USDC).balanceOf(_plasmaVault);
        uint256 belowRangeValue = _marketValueWith(address(_oracleBalanceFuse));

        assertGt(belowRangeSpent, 0, "USDC spent below range");
        assertApproxEqAbs(
            belowRangeValue,
            _valueInUnderlying(USDC, belowRangeSpent),
            ROUNDING_TOLERANCE,
            "below range: token1-only valuation"
        );

        // range above the current tick: token0 only (USDC of USDC/cbBTC)
        usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        _enterPosition(_usdcCbbtcKey, usdcCbbtcTick + RANGE, usdcCbbtcTick + 2 * RANGE, 10_000e6, 0);
        uint256 aboveRangeSpent = usdcBefore - ERC20(USDC).balanceOf(_plasmaVault);
        uint256 bothValue = _marketValueWith(address(_oracleBalanceFuse));

        assertGt(aboveRangeSpent, 0, "USDC spent above range");
        assertApproxEqAbs(
            bothValue - belowRangeValue,
            _valueInUnderlying(USDC, aboveRangeSpent),
            ROUNDING_TOLERANCE,
            "above range: token0-only valuation"
        );

        // full range (extreme getSqrtPriceAtTick inputs)
        _enterPosition(_wethUsdcKey, -887270, 887270, 1e18, 3_000e6);

        // when
        uint256 oldValue = _marketValueWith(address(_balanceFuse));
        uint256 newValue = _marketValueWith(address(_oracleBalanceFuse));

        // then
        assertGt(newValue, bothValue, "full-range position valued");
        assertEq(newValue, oldValue, "oracle fuse equals slot0 fuse for out-of-range and full-range positions");
    }

    // ------------------------------------------------------------------
    // (2) same-transaction pool manipulation, (2b) fees equal collected amounts
    // ------------------------------------------------------------------

    function testShouldKeepPrincipalWhenPoolPushedToLowerRangeEdgeWethUsdc() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, RANGE, 2e18, 6_000e6);
        (, int24 tickLower, ) = _positionTickRange(tokenId);

        // when — swap token0 in to push the pool price exactly to the lower edge of the range
        (uint256 oldBefore, uint256 newBefore, uint256 oldAfter, uint256 newAfter, uint256 feeBound) = _manipulate(
            _wethUsdcKey,
            TickMath.getSqrtPriceAtTick(tickLower)
        );

        // then — control: the slot0 fuse moves by more than any fee the swap could have paid
        assertGt(oldAfter, oldBefore + feeBound, "control: slot0 fuse value moves beyond the swap fee");

        // the oracle fuse moves by at most the swap fee, and only by the position's fees
        _assertOracleFuseMovedOnlyByFees(tokenId, _wethUsdcKey, oldAfter, newBefore, newAfter, feeBound);
    }

    function testShouldKeepPrincipalWhenPoolPushedBeyondUpperRangeEdgeUsdcCbbtc() external {
        // given — mixed decimals (6/8)
        uint256 tokenId = _openPosition(_usdcCbbtcKey, RANGE, 20_000e6, 20e6);
        (, , int24 tickUpper) = _positionTickRange(tokenId);

        // when — swap token1 in to push the pool price beyond the upper edge of the range
        (uint256 oldBefore, uint256 newBefore, uint256 oldAfter, uint256 newAfter, uint256 feeBound) = _manipulate(
            _usdcCbbtcKey,
            TickMath.getSqrtPriceAtTick(tickUpper + RANGE)
        );

        // then — control: the slot0 fuse value moves
        assertGt(oldAfter, oldBefore, "control: slot0 fuse value moves");

        // the oracle fuse moves by at most the swap fee, and only by the position's fees
        _assertOracleFuseMovedOnlyByFees(tokenId, _usdcCbbtcKey, oldAfter, newBefore, newAfter, feeBound);
    }

    // ------------------------------------------------------------------
    // (4) switching the market balance fuse on a vault with an open position
    // ------------------------------------------------------------------

    function testShouldSwitchVaultFromSlot0FuseToOracleFuseWithOpenPosition() external {
        // given — the vault runs on the slot0 fuse (base setUp) with an open position
        assertTrue(
            PlasmaVaultGovernance(_plasmaVault).isBalanceFuseSupported(
                IporFusionMarkets.UNISWAP_V4,
                address(_balanceFuse)
            ),
            "slot0 fuse installed"
        );
        uint256 tokenId = _openPosition(_usdcCbbtcKey, RANGE, 20_000e6, 20e6);
        (, , int24 tickUpper) = _positionTickRange(tokenId);
        uint256 valueAtOraclePrice = _v4MarketBalance();

        // the pool price is pushed away from the oracle and the slot0 fuse refreshes on it
        (address tokenIn, uint256 amountIn) = _swapToSqrtPrice(
            _usdcCbbtcKey,
            TickMath.getSqrtPriceAtTick(tickUpper + RANGE)
        );
        uint256 feeBound = _swapFeeBound(_usdcCbbtcKey, tokenIn, amountIn);
        _updateV4MarketBalance();
        uint256 slot0Value = _v4MarketBalance();
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        // when — the atomist switches the market to the oracle fuse
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.UNISWAP_V4, address(_oracleBalanceFuse));
        _updateV4MarketBalance();

        // then — the oracle fuse values the market: principal at the oracle price plus the position's fees
        assertTrue(
            PlasmaVaultGovernance(_plasmaVault).isBalanceFuseSupported(
                IporFusionMarkets.UNISWAP_V4,
                address(_oracleBalanceFuse)
            ),
            "oracle fuse installed"
        );
        assertFalse(
            PlasmaVaultGovernance(_plasmaVault).isBalanceFuseSupported(
                IporFusionMarkets.UNISWAP_V4,
                address(_balanceFuse)
            ),
            "slot0 fuse replaced"
        );

        uint256 oracleValue = _v4MarketBalance();
        assertGt(slot0Value, oracleValue, "switch removes the spot-composition valuation");
        assertGe(oracleValue + ROUNDING_TOLERANCE, valueAtOraclePrice, "principal kept at the oracle price");
        assertLe(oracleValue, valueAtOraclePrice + feeBound, "oracle value differs only by the swap fee");

        // NAV follows the new market valuation
        assertApproxEqAbs(
            PlasmaVault(_plasmaVault).totalAssets(),
            totalAssetsBefore - slot0Value + oracleValue,
            ROUNDING_TOLERANCE,
            "NAV after the switch = valuation of the oracle fuse"
        );
    }

    // ------------------------------------------------------------------
    // (5) no fallback to slot0 when a feed is missing
    // ------------------------------------------------------------------

    function testShouldRevertWhenPriceFeedMissingEvenForSingleSidedPosition() external {
        // given — a USDC-only position in USDC/cbBTC (range above the current tick); the vault holds no cbBTC,
        // so nothing else in the refresh needs a cbBTC price
        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_usdcCbbtcKey.toId());
        _enterPosition(_usdcCbbtcKey, currentTick + RANGE, currentTick + 2 * RANGE, 10_000e6, 0);
        deal(CBBTC, _plasmaVault, 0);

        // the price oracle has no price for cbBTC
        vm.mockCallRevert(
            _priceOracle,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, CBBTC),
            abi.encodeWithSelector(PriceOracleMiddlewareManager.UnsupportedAsset.selector)
        );

        // control — the slot0 fuse does not need the cbBTC price for a USDC-only position
        uint256 slot0Value = _marketValueWith(address(_balanceFuse));
        assertGt(slot0Value, 0, "control: slot0 fuse values the position without a cbBTC price");

        // when / then — the oracle fuse needs both prices for the composition and reverts (no slot0 fallback)
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.UNISWAP_V4, address(_oracleBalanceFuse));
        uint256[] memory markets = new uint256[](1);
        markets[0] = IporFusionMarkets.UNISWAP_V4;
        vm.expectRevert(abi.encodeWithSelector(PriceOracleMiddlewareManager.UnsupportedAsset.selector));
        PlasmaVault(_plasmaVault).updateMarketsBalances(markets);

        // the cached market value is unchanged by the reverted refresh
        assertEq(_v4MarketBalance(), slot0Value, "market cache unchanged");
    }

    // ------------------------------------------------------------------
    // gas
    // ------------------------------------------------------------------

    function testOracleBalanceGasAtTenPositions() external {
        // given
        _useBalanceFuse(address(_oracleBalanceFuse));
        for (uint256 i; i < 10; ++i) {
            _openPosition(_wethUsdcKey, int24(int256(300 + i * 50)), 5e17, 1_500e6);
        }

        // when — measure a full balance refresh over 10 positions
        uint256 gasBefore = gasleft();
        _updateV4MarketBalance();
        uint256 gasUsed = gasBefore - gasleft();

        // then
        assertGt(_v4MarketBalance(), 0, "ten positions valued");
        assertLt(gasUsed, 5_000_000, "balance refresh for 10 positions below 5M gas");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev Values the position with both fuses before and after a same-transaction swap to `targetSqrtPriceX96_`.
    /// Checks that the swap did not change the oracle inputs and that both fuses agree before the swap.
    function _manipulate(
        PoolKey memory poolKey_,
        uint160 targetSqrtPriceX96_
    ) private returns (uint256 oldBefore, uint256 newBefore, uint256 oldAfter, uint256 newAfter, uint256 feeBound) {
        uint160 oracleSqrtPriceBefore = _oracleSqrtPriceX96(poolKey_);
        oldBefore = _marketValueWith(address(_balanceFuse));
        newBefore = _marketValueWith(address(_oracleBalanceFuse));
        assertEq(newBefore, oldBefore, "parity before the swap (pool at the oracle price)");

        (address tokenIn, uint256 amountIn) = _swapToSqrtPrice(poolKey_, targetSqrtPriceX96_);
        feeBound = _swapFeeBound(poolKey_, tokenIn, amountIn);

        oldAfter = _marketValueWith(address(_balanceFuse));
        newAfter = _marketValueWith(address(_oracleBalanceFuse));

        assertEq(_oracleSqrtPriceX96(poolKey_), oracleSqrtPriceBefore, "oracle inputs unchanged by the swap");
    }

    /// @dev Asserts that the oracle fuse moved only by the position's fees: (a) bounded by the swap fee,
    /// (b) after collecting the fees the value equals the value before the swap (principal unchanged),
    /// (c) the valued pending fees equal the amounts actually collected. Also checks the control that the
    /// slot0 fuse moved the principal (both fuses value fees identically, so their gap is the principal shift).
    function _assertOracleFuseMovedOnlyByFees(
        uint256 tokenId_,
        PoolKey memory poolKey_,
        uint256 oldAfter_,
        uint256 newBefore_,
        uint256 newAfter_,
        uint256 feeBound_
    ) private {
        assertGt(oldAfter_, newAfter_ + newBefore_ / 500, "control: slot0 principal shifted by more than 0.2%");

        assertGe(newAfter_ + ROUNDING_TOLERANCE, newBefore_, "oracle fuse does not lose value");
        assertLe(newAfter_, newBefore_ + feeBound_, "oracle fuse moved by at most the swap fee");

        (uint256 collected0, uint256 collected1) = _collectFees(tokenId_);
        uint256 collectedValue = _valueInUnderlying(Currency.unwrap(poolKey_.currency0), collected0) +
            _valueInUnderlying(Currency.unwrap(poolKey_.currency1), collected1);
        uint256 principalAfter = _marketValueWith(address(_oracleBalanceFuse));

        assertGt(collected0 + collected1, 0, "the swap paid fees to the position");
        assertEq(principalAfter, newBefore_, "principal unchanged by the swap");
        assertApproxEqAbs(
            newAfter_ - principalAfter,
            collectedValue,
            ROUNDING_TOLERANCE,
            "valued pending fees equal the amounts collected"
        );
    }

    /// @dev Installs `fuse_` as the market balance fuse (if needed), refreshes the market and returns its value
    /// in underlying units.
    function _marketValueWith(address fuse_) private returns (uint256) {
        _useBalanceFuse(fuse_);
        _updateV4MarketBalance();
        return _v4MarketBalance();
    }

    function _useBalanceFuse(address fuse_) private {
        if (_activeBalanceFuse != fuse_) {
            PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.UNISWAP_V4, fuse_);
            _activeBalanceFuse = fuse_;
        }
    }

    function _updateV4MarketBalance() private {
        uint256[] memory markets = new uint256[](1);
        markets[0] = IporFusionMarkets.UNISWAP_V4;
        PlasmaVault(_plasmaVault).updateMarketsBalances(markets);
    }

    function _oracleSqrtPriceX96(PoolKey memory poolKey_) private view returns (uint160) {
        return
            OracleSqrtPriceX96Lib.fromOracle(
                Currency.unwrap(poolKey_.currency0),
                Currency.unwrap(poolKey_.currency1),
                _priceOracle
            );
    }

    /// @dev Exact-input swap from the test contract that stops exactly at `targetSqrtPriceX96_` (price limit);
    /// asserts the pool reached it. Returns the input token and the amount actually paid into the pool.
    function _swapToSqrtPrice(
        PoolKey memory poolKey_,
        uint160 targetSqrtPriceX96_
    ) private returns (address tokenIn, uint256 amountIn) {
        (uint160 currentSqrtPriceX96, , , ) = IPoolManager(POOL_MANAGER).getSlot0(poolKey_.toId());
        if (currentSqrtPriceX96 == targetSqrtPriceX96_) {
            return (address(0), 0);
        }

        bool zeroForOne = targetSqrtPriceX96_ < currentSqrtPriceX96;
        tokenIn = zeroForOne ? Currency.unwrap(poolKey_.currency0) : Currency.unwrap(poolKey_.currency1);
        uint256 budget = _swapBudget(tokenIn);

        deal(tokenIn, address(this), budget);
        ERC20(tokenIn).approve(address(_poolSwapTest), 0);
        ERC20(tokenIn).approve(address(_poolSwapTest), budget);

        BalanceDelta delta = _poolSwapTest.swap(
            poolKey_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(budget),
                sqrtPriceLimitX96: targetSqrtPriceX96_
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        amountIn = uint256(uint128(-paid));

        (uint160 sqrtPriceAfter, , , ) = IPoolManager(POOL_MANAGER).getSlot0(poolKey_.toId());
        assertEq(sqrtPriceAfter, targetSqrtPriceX96_, "pool moved exactly to the target price");
    }

    /// @dev Upper bound, in underlying units, of the LP fee an exact-input swap of `amountIn_` paid to the
    /// whole range: amountIn * fee / 1e6 plus one raw unit of rounding per swap step.
    function _swapFeeBound(
        PoolKey memory poolKey_,
        address tokenIn_,
        uint256 amountIn_
    ) private view returns (uint256) {
        return
            _valueInUnderlying(tokenIn_, (amountIn_ * uint256(poolKey_.fee)) / 1_000_000 + FEE_STEP_ROUNDING_SLACK) +
            ROUNDING_TOLERANCE;
    }

    function _swapBudget(address token_) private pure returns (uint256) {
        if (token_ == WETH) {
            return 10_000e18;
        }
        if (token_ == CBBTC) {
            return 500e8;
        }
        return 50_000_000e6;
    }

    function _enterPosition(
        PoolKey memory poolKey_,
        int24 tickLower_,
        int24 tickUpper_,
        uint256 amount0Desired_,
        uint256 amount1Desired_
    ) private {
        _executeEnterNewPosition(
            UniswapV4NewPositionFuseEnterData({
                poolKey: poolKey_,
                tickLower: _alignTick(tickLower_, poolKey_.tickSpacing),
                tickUpper: _alignTick(tickUpper_, poolKey_.tickSpacing),
                amount0Desired: amount0Desired_,
                amount1Desired: amount1Desired_,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                hookData: bytes(""),
                deadline: block.timestamp + 100
            })
        );
    }

    function _collectFees(uint256 tokenId_) private returns (uint256 amount0, uint256 amount1) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId_;
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(tokenIds))
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (, amount0, amount1) = _extractCollectEvent(entries);
    }
}
