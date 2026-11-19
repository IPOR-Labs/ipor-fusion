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
import {IUniswapV3Pool as IUniswapV3PoolCore} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

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
import {UniswapV3Balance} from "../../../contracts/fuses/uniswap/UniswapV3Balance.sol";
import {UniswapV3OracleBalance} from "../../../contracts/fuses/uniswap/UniswapV3OracleBalance.sol";
import {
    UniswapV3NewPositionFuse,
    UniswapV3NewPositionFuseEnterData
} from "../../../contracts/fuses/uniswap/UniswapV3NewPositionFuse.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3Factory
} from "../../../contracts/fuses/uniswap/ext/INonfungiblePositionManager.sol";
import {PositionValue} from "../../../contracts/fuses/uniswap/ext/PositionValue.sol";
import {TickMath} from "../../../contracts/fuses/uniswap/ext/TickMath.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

/// @dev Holds the two pieces of vault storage a Uniswap V3 balance fuse reads (the tracked token ID list and the
///      price oracle middleware) and runs a fuse's `balanceOf` by delegatecall, the way a PlasmaVault does. Lets the
///      test value the same positions with `UniswapV3Balance` and `UniswapV3OracleBalance` in the same state.
contract UniswapV3OracleBalanceForkTestVaultStorage {
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

/// @title UniswapV3OracleBalanceForkTest
/// @notice IL-9605 (M15): `UniswapV3OracleBalance` values Uniswap V3 positions at an oracle-implied composition, so a
///         swap in the pool cannot move the principal part of the market value, while `UniswapV3Balance` (slot0) can.
/// @dev Ethereum fork at its own block (20639327). Every manipulation test asserts in the same state that the slot0
///      fuse moves (control that the scenario reaches the valuation) and that the oracle fuse moves only by fees.
contract UniswapV3OracleBalanceForkTest is Test {
    using SafeERC20 for IERC20;

    struct Values {
        uint256 spot;
        uint256 oracle;
    }

    struct Swap {
        address tokenIn;
        uint256 amountIn;
        uint24 fee;
    }

    uint256 private constant _FORK_BLOCK = 20639327;

    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address private constant _UNISWAP_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address private constant _CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant _CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address private constant _CHAINLINK_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    uint24 private constant _USDC_WETH_FEE = 500;
    int24 private constant _USDC_WETH_TICK_SPACING = 10;
    uint24 private constant _DAI_USDC_FEE = 100;
    int24 private constant _DAI_USDC_TICK_SPACING = 1;

    /// @dev Input budget dealt before every manipulation swap; far above what any swap in these tests consumes
    uint256 private constant _SWAP_BUDGET = 1e30;
    /// @dev Per-step round-up of Uniswap fee amounts, added to the swap fee upper bound
    uint256 private constant _SWAP_FEE_ROUNDING = 1_000;
    /// @dev Slack for the floor rounding of two independently converted token legs
    uint256 private constant _LEG_ROUNDING = 2;
    /// @dev Maximum number of tick-spacing steps searched for an uninitialized tick
    uint256 private constant _FRESH_TICK_SEARCH_STEPS = 50;

    PriceOracleMiddleware private _priceOracle;
    UniswapV3Balance private _spotFuse;
    UniswapV3OracleBalance private _oracleFuse;
    UniswapV3OracleBalanceForkTestVaultStorage private _vaultStorage;
    address private _usdcWethPool;
    address private _daiUsdcPool;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        _priceOracle = _createRegistryPriceOracle();

        _spotFuse = new UniswapV3Balance(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER,
            _UNISWAP_FACTORY
        );
        _oracleFuse = new UniswapV3OracleBalance(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER
        );
        _vaultStorage = new UniswapV3OracleBalanceForkTestVaultStorage(address(_priceOracle));

        _usdcWethPool = IUniswapV3Factory(_UNISWAP_FACTORY).getPool(_USDC, _WETH, _USDC_WETH_FEE);
        _daiUsdcPool = IUniswapV3Factory(_UNISWAP_FACTORY).getPool(_DAI, _USDC, _DAI_USDC_FEE);
        assertTrue(_usdcWethPool != address(0) && _daiUsdcPool != address(0), "pools exist");
        assertEq(IUniswapV3PoolCore(_usdcWethPool).token0(), _USDC, "USDC is token0 of USDC/WETH");
        assertEq(IUniswapV3PoolCore(_daiUsdcPool).token0(), _DAI, "DAI is token0 of DAI/USDC");

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

    function testShouldSetMarketIdVersionAndPositionManager() external view {
        assertEq(_oracleFuse.MARKET_ID(), IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS, "MARKET_ID");
        assertEq(_oracleFuse.MARKET_ID(), _spotFuse.MARKET_ID(), "same market as the slot0 fuse");
        assertEq(_oracleFuse.VERSION(), address(_oracleFuse), "VERSION");
        assertEq(_oracleFuse.NONFUNGIBLE_POSITION_MANAGER(), _NONFUNGIBLE_POSITION_MANAGER, "position manager");
    }

    function testShouldRevertWhenPositionManagerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(UniswapV3OracleBalance.UniswapV3OracleBalanceZeroAddress.selector));
        new UniswapV3OracleBalance(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS, address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // (1) Parity with the slot0 fuse
    // ---------------------------------------------------------------------------------------------

    /// @notice With the pool moved exactly to the oracle-implied price, both fuses compute the same composition and
    ///         the same fees, so they report the same value.
    function testShouldMatchSlot0FuseWhenPoolTradesAtOraclePrice() external {
        // given
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcWethPool, _USDC_WETH_TICK_SPACING, 1_000);
        uint256 tokenId = _mint(_USDC, _WETH, _USDC_WETH_FEE, tickLower, tickUpper, 25_000e6, 10e18);

        // when
        _moveToOraclePrice(_usdcWethPool);
        Values memory values = _values(tokenId);

        // then
        (uint160 poolSqrtPriceX96, int24 poolTick, , , , , ) = IUniswapV3PoolCore(_usdcWethPool).slot0();
        assertEq(poolSqrtPriceX96, _oracleSqrtPriceX96(_USDC, _WETH), "pool trades at the oracle-implied price");
        assertTrue(poolTick >= tickLower && poolTick < tickUpper, "position in range");
        assertGt(values.oracle, 0, "position has value");
        assertEq(values.oracle, values.spot, "oracle fuse = slot0 fuse at the oracle price");
    }

    /// @notice On the untouched fork pool the oracle fuse stays within 0.01% of the slot0 fuse and never above it
    ///         (at fixed leg prices the value of a position's composition is lowest at the leg price ratio).
    function testShouldStayCloseToSlot0FuseAtForkPoolPrice() external {
        // given
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcWethPool, _USDC_WETH_TICK_SPACING, 1_000);
        uint256 tokenId = _mint(_USDC, _WETH, _USDC_WETH_FEE, tickLower, tickUpper, 25_000e6, 10e18);

        // when
        Values memory values = _values(tokenId);

        // then
        assertGt(values.oracle, 0, "position has value");
        assertLe(values.oracle, values.spot, "oracle fuse not above the slot0 fuse");
        assertApproxEqRel(values.oracle, values.spot, 1e14, "oracle fuse within 0.01% of the slot0 fuse");
    }

    // ---------------------------------------------------------------------------------------------
    // (2) Same-transaction pool swap: principal unchanged, total moves only by fees
    // ---------------------------------------------------------------------------------------------

    function testShouldNotMoveOracleFusePrincipalWhenSpotIsPushedAboveRange() external {
        _assertSpotPushMovesOracleFuseOnlyByFees(true);
    }

    function testShouldNotMoveOracleFusePrincipalWhenSpotIsPushedBelowRange() external {
        _assertSpotPushMovesOracleFuseOnlyByFees(false);
    }

    // ---------------------------------------------------------------------------------------------
    // (2b) Fees: valued as collected, and as the slot0 fuse values them
    // ---------------------------------------------------------------------------------------------

    function testShouldValueAccruedFeesAsCollectedAndAsSlot0Fuse() external {
        // given: an in-range position and a round trip of swaps inside its range, so both tokens accrue fees and the
        // pool ends at its starting price
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcWethPool, _USDC_WETH_TICK_SPACING, 1_000);
        uint256 tokenId = _mint(_USDC, _WETH, _USDC_WETH_FEE, tickLower, tickUpper, 25_000e6, 10e18);
        (uint160 startSqrtPriceX96, int24 startTick, , , , , ) = IUniswapV3PoolCore(_usdcWethPool).slot0();
        _swapToSqrtPrice(_usdcWethPool, TickMath.getSqrtRatioAtTick(startTick + 300));
        _swapToSqrtPrice(_usdcWethPool, startSqrtPriceX96);

        (uint256 fees0, uint256 fees1) = PositionValue.fees(
            INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER),
            tokenId
        );
        Values memory withFees = _values(tokenId);

        // when
        (uint256 collected0, uint256 collected1) = _collect(tokenId);
        Values memory withoutFees = _values(tokenId);

        // then
        assertGt(collected0, 0, "token0 fees accrued");
        assertGt(collected1, 0, "token1 fees accrued");
        assertEq(fees0, collected0, "token0 fees valued before collect = collected");
        assertEq(fees1, collected1, "token1 fees valued before collect = collected");
        assertApproxEqAbs(
            withFees.oracle - withoutFees.oracle,
            _usd(_USDC, collected0) + _usd(_WETH, collected1),
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

    // ---------------------------------------------------------------------------------------------
    // (3) Out-of-range positions on both sides, full range, both decimal orders
    // ---------------------------------------------------------------------------------------------

    /// @notice USDC (6) / WETH (18) and DAI (18) / USDC (6) pools, each with an in-range, a below-range, an
    ///         above-range and a full-range position: at the oracle price every position matches the slot0 fuse;
    ///         after the spot is pushed through several ranges the oracle fuse principal of every position is
    ///         unchanged while the slot0 fuse total moves.
    function testShouldHandleOutOfRangeFullRangeAndMixedDecimalPositions() external {
        // given
        _moveToOraclePrice(_usdcWethPool);
        _moveToOraclePrice(_daiUsdcPool);
        uint256[] memory tokenIds = new uint256[](8);
        _mintRangeSet(tokenIds, 0, _usdcWethPool, _USDC_WETH_TICK_SPACING, 500, 25_000e6, 10e18);
        _mintRangeSet(tokenIds, 4, _daiUsdcPool, _DAI_USDC_TICK_SPACING, 20, 25_000e18, 25_000e6);

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

        // when: the USDC/WETH spot is pushed up through the in-range and above-range positions, the DAI/USDC spot down
        // through the in-range and below-range positions
        _swapToSqrtPrice(_usdcWethPool, TickMath.getSqrtRatioAtTick(_currentTick(_usdcWethPool) + 1_700));
        _swapToSqrtPrice(_daiUsdcPool, TickMath.getSqrtRatioAtTick(_currentTick(_daiUsdcPool) - 80));
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
    ///         refresh books the inflated value. `addBalanceFuse(8, oracleFuse)` replaces the fuse without any
    ///         storage migration and the next refresh books the oracle valuation of the same tracked position.
    function testShouldRevalueOpenVaultPositionAfterSwitchingToOracleFuse() external {
        // given
        PlasmaVault plasmaVault = _createVaultOnSlot0Fuse();
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcWethPool, _USDC_WETH_TICK_SPACING, 1_000);
        uint256 tokenId = _openVaultPosition(plasmaVault, tickLower, tickUpper);
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS;

        uint256[] memory trackedTokenIds = new uint256[](1);
        trackedTokenIds[0] = tokenId;
        _vaultStorage.setTokenIds(trackedTokenIds);
        uint256 oracleValueBefore = _vaultStorage.balanceOfFuse(address(_oracleFuse));

        plasmaVault.updateMarketsBalances(marketIds);
        uint256 marketOnSlot0Fuse = plasmaVault.totalAssetsInMarket(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS);
        assertEq(
            marketOnSlot0Fuse,
            _toUsdcUnderlying(_vaultStorage.balanceOfFuse(address(_spotFuse))),
            "vault books the slot0 fuse value"
        );

        // when: spot pushed above the range and refreshed on the slot0 fuse
        Swap memory swap = _swapToSqrtPrice(_usdcWethPool, TickMath.getSqrtRatioAtTick(tickUpper + 200));
        plasmaVault.updateMarketsBalances(marketIds);
        assertGt(
            plasmaVault.totalAssetsInMarket(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS),
            marketOnSlot0Fuse + marketOnSlot0Fuse / 100,
            "control: the slot0 fuse books an inflated market value"
        );

        // when: the atomist switches the market to the oracle fuse and the market is refreshed
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            address(_oracleFuse)
        );
        plasmaVault.updateMarketsBalances(marketIds);

        // then
        assertTrue(
            PlasmaVaultGovernance(address(plasmaVault)).isBalanceFuseSupported(
                IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
                address(_oracleFuse)
            ),
            "oracle fuse installed"
        );
        assertFalse(
            PlasmaVaultGovernance(address(plasmaVault)).isBalanceFuseSupported(
                IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
                address(_spotFuse)
            ),
            "slot0 fuse replaced"
        );
        uint256 oracleValueAfter = _vaultStorage.balanceOfFuse(address(_oracleFuse));
        assertEq(
            plasmaVault.totalAssetsInMarket(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS),
            _toUsdcUnderlying(oracleValueAfter),
            "vault books the oracle fuse value of the tracked position"
        );
        assertGe(oracleValueAfter, oracleValueBefore, "oracle value can only grow by fees");
        assertLe(oracleValueAfter - oracleValueBefore, _swapFeeUsd(swap), "oracle value moved at most by fees");
    }

    // ---------------------------------------------------------------------------------------------
    // (5) Reverts: no fallback to slot0
    // ---------------------------------------------------------------------------------------------

    /// @notice A middleware without a WETH price reverts the oracle fuse for a USDC/WETH position; the same
    ///         middleware values a DAI/USDC position (control that the revert comes from the missing feed).
    function testShouldRevertWhenTokenHasNoPriceFeed() external {
        // given
        PriceOracleMiddleware priceOracle = _createPriceOracleWithoutRegistry();
        UniswapV3OracleBalanceForkTestVaultStorage vaultStorage = new UniswapV3OracleBalanceForkTestVaultStorage(
            address(priceOracle)
        );
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_daiUsdcPool, _DAI_USDC_TICK_SPACING, 20);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _mint(_DAI, _USDC, _DAI_USDC_FEE, tickLower, tickUpper, 25_000e18, 25_000e6);
        vaultStorage.setTokenIds(tokenIds);
        assertGt(vaultStorage.balanceOfFuse(address(_oracleFuse)), 0, "control: priced pair is valued");

        (tickLower, tickUpper) = _rangeAroundCurrentTick(_usdcWethPool, _USDC_WETH_TICK_SPACING, 1_000);
        tokenIds[0] = _mint(_USDC, _WETH, _USDC_WETH_FEE, tickLower, tickUpper, 25_000e6, 10e18);
        vaultStorage.setTokenIds(tokenIds);

        // then
        vm.expectRevert(abi.encodeWithSelector(IPriceOracleMiddleware.UnsupportedAsset.selector));
        vaultStorage.balanceOfFuse(address(_oracleFuse));
    }

    /// @notice An oracle-implied raw price `token1 / token0 >= 2^128` reverts the oracle fuse; the slot0 fuse still
    ///         returns a value in the same state, so the oracle fuse does not fall back to the pool price.
    function testShouldRevertWhenOracleImpliedPriceIsOutOfQ64x96Range() external {
        // given
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcWethPool, _USDC_WETH_TICK_SPACING, 1_000);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _mint(_USDC, _WETH, _USDC_WETH_FEE, tickLower, tickUpper, 25_000e6, 10e18);
        _vaultStorage.setTokenIds(tokenIds);
        vm.mockCall(
            address(_priceOracle),
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, _USDC),
            abi.encode(uint256(1e50), uint256(18))
        );

        // then
        assertGt(_vaultStorage.balanceOfFuse(address(_spotFuse)), 0, "control: slot0 fuse still values the position");
        vm.expectRevert(abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector));
        _vaultStorage.balanceOfFuse(address(_oracleFuse));
    }

    function testShouldRevertWhenPriceOracleMiddlewareIsNotSet() external {
        // given
        UniswapV3OracleBalanceForkTestVaultStorage vaultStorage = new UniswapV3OracleBalanceForkTestVaultStorage(
            address(0)
        );
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcWethPool, _USDC_WETH_TICK_SPACING, 1_000);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _mint(_USDC, _WETH, _USDC_WETH_FEE, tickLower, tickUpper, 25_000e6, 10e18);
        vaultStorage.setTokenIds(tokenIds);

        // then
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3OracleBalance.UniswapV3OracleBalancePriceOracleMiddlewareNotSet.selector)
        );
        vaultStorage.balanceOfFuse(address(_oracleFuse));
    }

    function testShouldReturnZeroWithoutTrackedPositions() external {
        // given: no middleware either, so a read of it would revert
        UniswapV3OracleBalanceForkTestVaultStorage vaultStorage = new UniswapV3OracleBalanceForkTestVaultStorage(
            address(0)
        );

        // then
        assertEq(vaultStorage.balanceOfFuse(address(_oracleFuse)), 0, "no tracked positions");
    }

    // ---------------------------------------------------------------------------------------------
    // Uniswap V3 pool swap callback
    // ---------------------------------------------------------------------------------------------

    /// @dev Pays the pool for the manipulation swaps of this test
    function uniswapV3SwapCallback(int256 amount0Delta_, int256 amount1Delta_, bytes calldata data_) external {
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

    function _assertSpotPushMovesOracleFuseOnlyByFees(bool pushAboveRange_) private {
        // given: an in-range USDC/WETH position with no fees accrued yet
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(_usdcWethPool, _USDC_WETH_TICK_SPACING, 1_000);
        uint256 tokenId = _mint(_USDC, _WETH, _USDC_WETH_FEE, tickLower, tickUpper, 25_000e6, 10e18);
        Values memory initial = _values(tokenId);
        uint160 oracleSqrtPriceBefore = _oracleSqrtPriceX96(_USDC, _WETH);

        // when: one swap pushes the pool spot past the range edge
        Swap memory swap = _swapToSqrtPrice(
            _usdcWethPool,
            TickMath.getSqrtRatioAtTick(pushAboveRange_ ? tickUpper + 200 : tickLower - 200)
        );
        Values memory afterSwap = _values(tokenId);

        // then: the scenario reached the valuation and the oracle inputs are unchanged
        if (pushAboveRange_) {
            assertGe(_currentTick(_usdcWethPool), tickUpper, "spot pushed above the range");
        } else {
            assertLt(_currentTick(_usdcWethPool), tickLower, "spot pushed below the range");
        }
        assertEq(_oracleSqrtPriceX96(_USDC, _WETH), oracleSqrtPriceBefore, "oracle inputs unchanged by the swap");
        assertGt(afterSwap.spot, initial.spot + initial.spot / 100, "control: slot0 fuse value moved by more than 1%");

        // then: the oracle fuse moved only up, and at most by the fee the swap paid
        assertGe(afterSwap.oracle, initial.oracle, "oracle fuse can only grow by accrued fees");
        assertLe(afterSwap.oracle - initial.oracle, _swapFeeUsd(swap), "oracle fuse moved at most by the swap fee");

        // when: the fees are collected
        (uint256 collected0, uint256 collected1) = _collect(tokenId);
        Values memory afterCollect = _values(tokenId);

        // then: principal alone is unchanged for the oracle fuse, still moved for the slot0 fuse
        assertEq(afterCollect.oracle, initial.oracle, "oracle fuse principal unchanged by the spot swap");
        assertGt(afterCollect.spot, initial.spot + initial.spot / 100, "control: slot0 fuse principal moved");
        assertGt(collected0 + collected1, 0, "the swap credited fees to the position");
        assertApproxEqAbs(
            afterSwap.oracle - afterCollect.oracle,
            _usd(_USDC, collected0) + _usd(_WETH, collected1),
            _LEG_ROUNDING,
            "oracle fuse change = USD value of the collected fees"
        );
    }

    /// @dev Mints four positions of one pool into `tokenIds_` from `offset_`: in range, below range, above range and
    ///      full range. `width_` is the half-width of the in-range position in ticks; out-of-range positions sit
    ///      between 2 and 3 widths from the current tick, on uninitialized ticks (see `_freshTick`).
    function _mintRangeSet(
        uint256[] memory tokenIds_,
        uint256 offset_,
        address pool_,
        int24 tickSpacing_,
        int24 width_,
        uint256 amount0_,
        uint256 amount1_
    ) private {
        int24 tick = _currentTick(pool_);
        (int24 tickLower, int24 tickUpper) = _rangeAroundCurrentTick(pool_, tickSpacing_, width_);
        tokenIds_[offset_] = _mintInPool(pool_, tickLower, tickUpper, amount0_, amount1_);

        tickLower = _freshTick(pool_, tick - 3 * width_, tickSpacing_, false);
        tickUpper = _freshTick(pool_, tick - 2 * width_, tickSpacing_, false);
        assertTrue(tickLower < tickUpper && tickUpper <= tick, "below-range position below the current tick");
        tokenIds_[offset_ + 1] = _mintInPool(pool_, tickLower, tickUpper, amount0_, amount1_);

        tickLower = _freshTick(pool_, tick + 2 * width_, tickSpacing_, true);
        tickUpper = _freshTick(pool_, tick + 3 * width_, tickSpacing_, true);
        assertTrue(tick < tickLower && tickLower < tickUpper, "above-range position above the current tick");
        tokenIds_[offset_ + 2] = _mintInPool(pool_, tickLower, tickUpper, amount0_, amount1_);

        tickUpper = _alignDown(TickMath.MAX_TICK, tickSpacing_);
        tokenIds_[offset_ + 3] = _mintInPool(pool_, -tickUpper, tickUpper, amount0_, amount1_);
    }

    function _mintInPool(
        address pool_,
        int24 tickLower_,
        int24 tickUpper_,
        uint256 amount0_,
        uint256 amount1_
    ) private returns (uint256) {
        IUniswapV3PoolCore pool = IUniswapV3PoolCore(pool_);
        return _mint(pool.token0(), pool.token1(), pool.fee(), tickLower_, tickUpper_, amount0_, amount1_);
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
            new UniswapV3NewPositionFuse(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS, _NONFUNGIBLE_POSITION_MANAGER)
        );

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS, address(_spotFuse));
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        bytes32[] memory tokens = new bytes32[](2);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        tokens[1] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS, tokens);
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
        dependentMarkets[0] = IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS;
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
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                UniswapV3NewPositionFuseEnterData({
                    token0: _USDC,
                    token1: _WETH,
                    fee: _USDC_WETH_FEE,
                    tickLower: tickLower_,
                    tickUpper: tickUpper_,
                    amount0Desired: 25_000e6,
                    amount1Desired: 10e18,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            )
        );
        plasmaVault_.execute(calls);

        assertEq(IERC721Enumerable(_NONFUNGIBLE_POSITION_MANAGER).balanceOf(address(plasmaVault_)), 1, "one NFT");
        tokenId = IERC721Enumerable(_NONFUNGIBLE_POSITION_MANAGER).tokenOfOwnerByIndex(address(plasmaVault_), 0);
    }

    function _createRegistryPriceOracle() private returns (PriceOracleMiddleware priceOracle) {
        priceOracle = _createPriceOracle(_CHAINLINK_FEED_REGISTRY);
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = _WETH;
        sources[0] = _CHAINLINK_ETH_USD;
        priceOracle.setAssetsPricesSources(assets, sources);
    }

    /// @dev Middleware with explicit USDC and DAI feeds only: no registry fallback, so WETH has no price
    function _createPriceOracleWithoutRegistry() private returns (PriceOracleMiddleware priceOracle) {
        priceOracle = _createPriceOracle(address(0));
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = _USDC;
        sources[0] = _CHAINLINK_USDC_USD;
        assets[1] = _DAI;
        sources[1] = _CHAINLINK_DAI_USD;
        priceOracle.setAssetsPricesSources(assets, sources);
    }

    function _createPriceOracle(address chainlinkFeedRegistry_) private returns (PriceOracleMiddleware) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(chainlinkFeedRegistry_);
        return
            PriceOracleMiddleware(
                address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeWithSignature("initialize(address)", address(this))
                    )
                )
            );
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
        (tokenId, , , ) = INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
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
                deadline: block.timestamp
            })
        );
    }

    function _collect(uint256 tokenId_) private returns (uint256 amount0, uint256 amount1) {
        return
            INonfungiblePositionManager(_NONFUNGIBLE_POSITION_MANAGER).collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId_,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
    }

    /// @dev One direct swap against the live pool to an exact target price, the mechanism a flash-loan attacker
    ///      uses (only capital, no role). Asserts that the pool reached the target.
    function _swapToSqrtPrice(address pool_, uint160 targetSqrtPriceX96_) private returns (Swap memory swap) {
        IUniswapV3PoolCore pool = IUniswapV3PoolCore(pool_);
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
        _swapToSqrtPrice(
            pool_,
            _oracleSqrtPriceX96(IUniswapV3PoolCore(pool_).token0(), IUniswapV3PoolCore(pool_).token1())
        );
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
        tickLower = _freshTick(pool_, tick - halfWidth_, tickSpacing_, false);
        tickUpper = _freshTick(pool_, tick + halfWidth_, tickSpacing_, true);
    }

    /// @dev First uninitialized tick from `tick_` (aligned down to the spacing), searching away from the price.
    ///      Positions in these tests sit on uninitialized ticks so that their fee growth inside starts at zero and
    ///      the expected fee bounds stay simple through every crossing in the scenarios. `PositionValue.fees` itself
    ///      handles wrapped ranges (fee growth outside values summing above the global growth); that case is covered
    ///      by `PositionValueFeeGrowthWrapForkTest`.
    function _freshTick(
        address pool_,
        int24 tick_,
        int24 tickSpacing_,
        bool searchUp_
    ) private view returns (int24 tick) {
        tick = _alignDown(tick_, tickSpacing_);
        bool initialized;
        for (uint256 i; i < _FRESH_TICK_SEARCH_STEPS; ++i) {
            (, , , , , , , initialized) = IUniswapV3PoolCore(pool_).ticks(tick);
            if (!initialized) {
                return tick;
            }
            tick = searchUp_ ? tick + tickSpacing_ : tick - tickSpacing_;
        }
        assertFalse(initialized, "uninitialized tick found");
    }

    function _currentTick(address pool_) private view returns (int24 tick) {
        (, tick, , , , , ) = IUniswapV3PoolCore(pool_).slot0();
    }

    function _alignDown(int24 tick_, int24 tickSpacing_) private pure returns (int24) {
        int24 compressed = tick_ / tickSpacing_;
        if (tick_ < 0 && tick_ % tickSpacing_ != 0) {
            --compressed;
        }
        return compressed * tickSpacing_;
    }
}
