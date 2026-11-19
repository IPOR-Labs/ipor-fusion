// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {FuseStorageLib} from "../../../contracts/libraries/FuseStorageLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {RamsesV2Balance} from "../../../contracts/fuses/ramses/RamsesV2Balance.sol";
import {
    INonfungiblePositionManagerRamses,
    IRamsesV2Factory
} from "../../../contracts/fuses/ramses/ext/INonfungiblePositionManagerRamses.sol";
import {TickMath} from "../../../contracts/fuses/ramses/ext/TickMath.sol";

/// @dev Holds the two pieces of vault storage `RamsesV2Balance` reads (the tracked token ID list and the price oracle
///      middleware) and runs its `balanceOf` by delegatecall, the way a PlasmaVault does
contract RamsesV2BalanceFeeGrowthForkTestVaultStorage {
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

/// @title RamsesV2BalanceFeeGrowthForkTest
/// @notice D-050: `RamsesV2Balance` (market 18, live) values the fees of a position before `collect` as `collect`
///         returns them, computed from the pool's current fee growth. Before D-050 the fee read keyed
///         `pool.positions` by the vault while the pool keys positions by the position manager, so fees earned after
///         the last update of a position were valued at 0 until the position was updated.
/// @dev Regression proof for the live fuse: it uses no symbol added in this series, so it also runs on the base
///      commit, where both tests fail. Arbitrum fork at its own block (254261637). `RamsesV2OracleBalanceForkTest`
///      covers both Ramses V2 balance fuses together.
contract RamsesV2BalanceFeeGrowthForkTest is Test {
    using SafeERC20 for IERC20;

    uint256 private constant _FORK_BLOCK = 254261637;

    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant _FRAX = 0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F;

    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0xAA277CB7914b7e5514946Da92cb9De332Ce610EF;
    address private constant _RAMSES_FACTORY = 0xAA2cd7477c451E703f3B9Ba5663334914763edF8;

    address private constant _CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address private constant _CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address private constant _CHAINLINK_FRAX_USD = 0x0809E3d38d1B4214958faf06D8b1B1a2b73f2ab8;

    /// @dev WETH (18 decimals) is token0, USDC (6 decimals) token1
    uint24 private constant _WETH_USDC_FEE = 500;
    int24 private constant _WETH_USDC_TICK_SPACING = 10;

    /// @dev A live FRAX/USDC (fee 100) position at the fork block whose position manager fee growth checkpoints are
    ///      wrapped values (token0 checkpoint = 2^256 - 2.25e39) and whose pool fee growth inside wraps below zero
    uint256 private constant _WRAPPED_CHECKPOINT_TOKEN_ID = 190206;

    /// @dev Input budget dealt before every swap; far above what any swap in these tests consumes
    uint256 private constant _SWAP_BUDGET = 1e30;
    /// @dev Slack for the floor rounding of two independently converted token legs
    uint256 private constant _LEG_ROUNDING = 2;
    /// @dev Per-token slack (wei) between the fees valued before `collect` and the amounts `collect` transfers
    uint256 private constant _COLLECT_ROUNDING = 2;

    PriceOracleMiddleware private _priceOracle;
    RamsesV2Balance private _fuse;
    RamsesV2BalanceFeeGrowthForkTestVaultStorage private _vaultStorage;
    address private _wethUsdcPool;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), _FORK_BLOCK);

        _priceOracle = _createPriceOracle();
        _fuse = new RamsesV2Balance(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER,
            _RAMSES_FACTORY
        );
        _vaultStorage = new RamsesV2BalanceFeeGrowthForkTestVaultStorage(address(_priceOracle));

        _wethUsdcPool = IRamsesV2Factory(_RAMSES_FACTORY).getPool(_WETH, _USDC, _WETH_USDC_FEE);
        assertEq(IUniswapV3Pool(_wethUsdcPool).token0(), _WETH, "WETH is token0 of WETH/USDC");

        deal(_USDC, address(this), 10_000_000e6);
        deal(_WETH, address(this), 10_000e18);
        IERC20(_USDC).forceApprove(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
        IERC20(_WETH).forceApprove(_NONFUNGIBLE_POSITION_MANAGER, type(uint256).max);
    }

    /// @notice Fees earned after the last update of a position (nothing checkpointed in the position manager) are
    ///         valued before `collect` as `collect` returns them
    function testShouldValueFeesEarnedAfterLastPositionUpdateAsCollected() external {
        // given: an in-range position and a round trip of swaps inside its range, no update of the position after it
        int24 tick = _currentTick(_wethUsdcPool);
        uint256 tokenId = _mint(
            _alignDown(tick - 1_000, _WETH_USDC_TICK_SPACING),
            _alignDown(tick + 1_000, _WETH_USDC_TICK_SPACING),
            10e18,
            25_000e6
        );
        _roundTripSwaps(_wethUsdcPool, 300);

        INonfungiblePositionManagerRamses.Position memory position = _position(tokenId);
        uint256 valueBeforeCollect = _value(tokenId);

        // when
        (uint256 collected0, uint256 collected1) = _collect(tokenId);
        uint256 valueAfterCollect = _value(tokenId);

        // then
        assertEq(position.tokensOwed0, 0, "no token0 fees checkpointed in the position manager");
        assertEq(position.tokensOwed1, 0, "no token1 fees checkpointed in the position manager");
        assertGt(collected0, 0, "token0 fees earned and collected");
        assertGt(collected1, 0, "token1 fees earned and collected");
        _assertValuedFeesEqualCollected(valueBeforeCollect, valueAfterCollect, _WETH, _USDC, collected0, collected1);
    }

    /// @notice A live position whose fee growth checkpoints are wrapped values is valued without an arithmetic panic
    ///         and its fees as `collect` returns them
    function testShouldValueFeesOfPositionWithWrappedFeeGrowthCheckpointAsCollected() external {
        // given
        uint256 tokenId = _WRAPPED_CHECKPOINT_TOKEN_ID;
        INonfungiblePositionManagerRamses.Position memory position = _position(tokenId);
        assertEq(position.token0, _FRAX, "FRAX is token0");
        assertEq(position.token1, _USDC, "USDC is token1");
        assertGt(position.liquidity, 0, "position has liquidity");
        assertGt(position.feeGrowthInside0Last, type(uint256).max / 2, "token0 checkpoint is a wrapped value");
        assertGt(position.feeGrowthInside1Last, type(uint256).max / 2, "token1 checkpoint is a wrapped value");

        uint256 valueBeforeCollect = _value(tokenId);

        // when
        vm.prank(IERC721(_NONFUNGIBLE_POSITION_MANAGER).ownerOf(tokenId));
        (uint256 collected0, uint256 collected1) = _collect(tokenId);
        uint256 valueAfterCollect = _value(tokenId);

        // then
        assertGt(collected0, 0, "token0 fees collected");
        assertGt(collected1, 0, "token1 fees collected");
        _assertValuedFeesEqualCollected(valueBeforeCollect, valueAfterCollect, _FRAX, _USDC, collected0, collected1);
    }

    /// @dev Pays the pool for the swaps of this test
    function ramsesV2SwapCallback(int256 amount0Delta_, int256 amount1Delta_, bytes calldata data_) external {
        (address token0, address token1) = abi.decode(data_, (address, address));
        if (amount0Delta_ > 0) {
            IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta_));
        }
        if (amount1Delta_ > 0) {
            IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta_));
        }
    }

    /// @dev Asserts that the fuse value dropped by `collect` by the USD value of the collected amounts: the fees
    ///      valued before `collect` are what `collect` returned, within `_COLLECT_ROUNDING` wei of each token plus the
    ///      floor rounding of the two legs. `collect` changes neither the liquidity nor the pool price, so the
    ///      principal is the same in both states.
    function _assertValuedFeesEqualCollected(
        uint256 valueBeforeCollect_,
        uint256 valueAfterCollect_,
        address token0_,
        address token1_,
        uint256 collected0_,
        uint256 collected1_
    ) private view {
        uint256 collectedUsd = _usd(token0_, collected0_) + _usd(token1_, collected1_);
        uint256 tolerance = _usd(token0_, _COLLECT_ROUNDING) + _usd(token1_, _COLLECT_ROUNDING) + _LEG_ROUNDING;

        assertGt(collectedUsd, tolerance, "control: collected fees above the rounding tolerance");
        assertGe(valueBeforeCollect_, valueAfterCollect_, "collect does not raise the value");
        assertApproxEqAbs(
            valueBeforeCollect_ - valueAfterCollect_,
            collectedUsd,
            tolerance,
            "fees valued before collect = collected fees"
        );
    }

    /// @dev Middleware with explicit Chainlink feeds (Arbitrum has no feed registry) for USDC, WETH and FRAX
    function _createPriceOracle() private returns (PriceOracleMiddleware priceOracle) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        address[] memory assets = new address[](3);
        address[] memory sources = new address[](3);
        assets[0] = _USDC;
        sources[0] = _CHAINLINK_USDC_USD;
        assets[1] = _WETH;
        sources[1] = _CHAINLINK_ETH_USD;
        assets[2] = _FRAX;
        sources[2] = _CHAINLINK_FRAX_USD;
        priceOracle.setAssetsPricesSources(assets, sources);
    }

    function _mint(
        int24 tickLower_,
        int24 tickUpper_,
        uint256 amount0_,
        uint256 amount1_
    ) private returns (uint256 tokenId) {
        (tokenId, , , ) = INonfungiblePositionManagerRamses(_NONFUNGIBLE_POSITION_MANAGER).mint(
            INonfungiblePositionManagerRamses.MintParams({
                token0: _WETH,
                token1: _USDC,
                fee: _WETH_USDC_FEE,
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

    function _position(
        uint256 tokenId_
    ) private view returns (INonfungiblePositionManagerRamses.Position memory position) {
        (bool success, bytes memory data) = _NONFUNGIBLE_POSITION_MANAGER.staticcall(
            abi.encodeWithSelector(INonfungiblePositionManagerRamses.positions.selector, tokenId_)
        );
        assertTrue(success, "positions read");
        position = abi.decode(data, (INonfungiblePositionManagerRamses.Position));
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

    /// @dev One direct swap against the live pool to an exact target price; asserts that the pool reached the target
    function _swapToSqrtPrice(address pool_, uint160 targetSqrtPriceX96_) private {
        IUniswapV3Pool pool = IUniswapV3Pool(pool_);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        bool zeroForOne = targetSqrtPriceX96_ < sqrtPriceX96;
        address token0 = pool.token0();
        address token1 = pool.token1();
        address tokenIn = zeroForOne ? token0 : token1;
        deal(tokenIn, address(this), IERC20(tokenIn).balanceOf(address(this)) + _SWAP_BUDGET);

        pool.swap(address(this), zeroForOne, type(int128).max, targetSqrtPriceX96_, abi.encode(token0, token1));

        (sqrtPriceX96, , , , , , ) = pool.slot0();
        assertEq(sqrtPriceX96, targetSqrtPriceX96_, "swap reached the target price");
    }

    function _value(uint256 tokenId_) private returns (uint256) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId_;
        _vaultStorage.setTokenIds(tokenIds);
        return _vaultStorage.balanceOfFuse(address(_fuse));
    }

    /// @dev USD (WAD) value of a token amount at the test middleware price, as the fuse computes it
    function _usd(address token_, uint256 amount_) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = _priceOracle.getAssetPrice(token_);
        return IporMath.convertToWad(amount_ * price, IERC20Metadata(token_).decimals() + priceDecimals);
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
