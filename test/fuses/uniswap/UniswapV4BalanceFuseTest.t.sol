// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {FuseAction, PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {UniswapV4TestBase} from "./UniswapV4TestBase.sol";
import {
    UniswapV4NewPositionFuse,
    UniswapV4NewPositionFuseEnterData
} from "../../../contracts/fuses/uniswap/UniswapV4NewPositionFuse.sol";
import {
    UniswapV4CollectFuse,
    UniswapV4CollectFuseEnterData
} from "../../../contracts/fuses/uniswap/UniswapV4CollectFuse.sol";
import {UniswapV4Balance} from "../../../contracts/fuses/uniswap/UniswapV4Balance.sol";
import {IPositionManagerV4} from "../../../contracts/fuses/uniswap/ext/v4/IPositionManagerV4.sol";

contract UniswapV4BalanceFuseTest is UniswapV4TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------
    // Scenario 5 — NAV valuation
    // ------------------------------------------------------------------

    function testShouldRevertBalanceConstructorOnZeroAddress() external {
        vm.expectRevert(UniswapV4Balance.UniswapV4BalanceInvalidAddress.selector);
        new UniswapV4Balance(1, address(0), POOL_MANAGER);

        vm.expectRevert(UniswapV4Balance.UniswapV4BalanceInvalidAddress.selector);
        new UniswapV4Balance(1, POSITION_MANAGER, address(0));
    }

    function testBalanceZeroWhenNoPositions() external {
        // when
        _refreshMarketBalance();

        // then
        assertEq(_v4MarketBalance(), 0, "no positions -> zero market balance");
    }

    function testBalanceMatchesDepositedValueWethUsdc() external {
        // given / when
        vm.recordLogs();
        _openPosition(_wethUsdcKey, 1000, 2e18, 6_000e6);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (, , uint256 amount0, uint256 amount1) = _extractNewPositionEnterEvent(entries);

        // then — market balance (USDC terms) matches oracle value of the amounts actually deposited
        uint256 expected = _valueInUnderlying(WETH, amount0) + _valueInUnderlying(USDC, amount1);
        assertApproxEqRel(_v4MarketBalance(), expected, 0.005e18, "balance approx deposited value");
    }

    function testBalanceMixedDecimalsUsdcCbbtc() external {
        // given / when — 6-decimals + 8-decimals pool
        vm.recordLogs();
        _openPosition(_usdcCbbtcKey, 1000, 10_000e6, 10e6);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (, , uint256 amount0, uint256 amount1) = _extractNewPositionEnterEvent(entries);

        // then
        uint256 expected = _valueInUnderlying(USDC, amount0) + _valueInUnderlying(CBBTC, amount1);
        assertApproxEqRel(_v4MarketBalance(), expected, 0.005e18, "balance approx deposited value");
    }

    function testBalanceTwoPoolsAggregated() external {
        // given / when
        vm.recordLogs();
        _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        _openPosition(_usdcCbbtcKey, 1000, 5_000e6, 5e6);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then — sum of both positions
        uint256 expected;
        (, , uint256 a0, uint256 a1) = _extractNewPositionEnterEvent(entries);
        expected += _valueInUnderlying(WETH, a0) + _valueInUnderlying(USDC, a1);
        (uint256 tokenId2, , uint256 b0, uint256 b1) = _extractSecondEnterEvent(entries);
        expected += _valueInUnderlying(USDC, b0) + _valueInUnderlying(CBBTC, b1);

        assertGt(tokenId2, 0, "second position found");
        assertApproxEqRel(_v4MarketBalance(), expected, 0.005e18, "aggregated balance");
    }

    function testBalanceIncludesPendingFees() external {
        // given
        _openPosition(_usdcCbbtcKey, 2_000, 20_000e6, 20e6);
        uint256 balanceAfterMint = _v4MarketBalance();

        // when — swaps accrue LP fees (external to the vault), then refresh vault accounting
        _swapV4(_usdcCbbtcKey, true, 100_000e6);
        _swapV4(_usdcCbbtcKey, false, 1e8);
        _refreshMarketBalance();

        // then — pending (uncollected) fees are part of the NAV
        assertGt(_v4MarketBalance(), balanceAfterMint, "balance grew by pending fees");
    }

    function testBalanceFeesMatchCollectedAmounts() external {
        // given — accrue fees, snapshot valuation including pending fees
        uint256 tokenId = _openPosition(_usdcCbbtcKey, 2_000, 20_000e6, 20e6);
        _swapV4(_usdcCbbtcKey, true, 100_000e6);
        _swapV4(_usdcCbbtcKey, false, 1e8);
        _refreshMarketBalance();
        uint256 balanceWithPendingFees = _v4MarketBalance();

        // when — collect fees to the vault
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(tokenIds))
        );
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (, uint256 collected0, uint256 collected1) = _extractCollectEvent(entries);

        // then — the drop in market balance equals the oracle value of what was collected
        uint256 balanceAfterCollect = _v4MarketBalance();
        uint256 collectedValue = _valueInUnderlying(USDC, collected0) + _valueInUnderlying(CBBTC, collected1);

        assertGt(collectedValue, 0, "fees collected");
        assertApproxEqRel(
            balanceWithPendingFees - balanceAfterCollect,
            collectedValue,
            0.005e18,
            "pending fee valuation matches collected amounts"
        );
    }

    function testBalanceAfterFullExitIsZero() external {
        // given
        uint256 tokenId1 = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        uint256 tokenId2 = _openPosition(_usdcCbbtcKey, 1000, 5_000e6, 5e6);
        assertGt(_v4MarketBalance(), 0, "positions valued");

        // when
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;
        _closePositions(tokenIds);

        // then
        assertEq(_v4MarketBalance(), 0, "zero after closing all positions");
    }

    function testBalanceOutOfRangePositionSingleSided() external {
        // given — a range entirely below the current tick holds only token1 (USDC for WETH/USDC)
        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        uint256 wethBefore = ERC20(WETH).balanceOf(_plasmaVault);
        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        _executeEnterNewPosition(
            UniswapV4NewPositionFuseEnterData({
                poolKey: _wethUsdcKey,
                tickLower: _alignTick(currentTick - 2000, 10),
                tickUpper: _alignTick(currentTick - 1000, 10),
                amount0Desired: 0,
                amount1Desired: 3_000e6,
                amount0Max: 1e9,
                amount1Max: 6_000e6,
                hookData: bytes(""),
                deadline: block.timestamp + 100
            })
        );

        // then — only USDC was spent and the position is valued accordingly
        uint256 usdcSpent = usdcBefore - ERC20(USDC).balanceOf(_plasmaVault);
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), wethBefore, "no WETH spent");
        assertGt(usdcSpent, 0, "USDC spent");
        assertApproxEqRel(_v4MarketBalance(), _valueInUnderlying(USDC, usdcSpent), 0.005e18, "single-sided valuation");
    }

    function testBalanceOutOfRangeAboveTickSingleSidedToken0() external {
        // given — a range entirely above the current tick holds only token0 (WETH for WETH/USDC)
        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        uint256 wethBefore = ERC20(WETH).balanceOf(_plasmaVault);
        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        _executeEnterNewPosition(
            UniswapV4NewPositionFuseEnterData({
                poolKey: _wethUsdcKey,
                tickLower: _alignTick(currentTick + 1000, 10),
                tickUpper: _alignTick(currentTick + 2000, 10),
                amount0Desired: 1e18,
                amount1Desired: 0,
                amount0Max: 2e18,
                amount1Max: 1e3,
                hookData: bytes(""),
                deadline: block.timestamp + 100
            })
        );

        // then — only WETH was spent and the position is valued accordingly
        uint256 wethSpent = wethBefore - ERC20(WETH).balanceOf(_plasmaVault);
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), usdcBefore, "no USDC spent");
        assertGt(wethSpent, 0, "WETH spent");
        assertApproxEqRel(_v4MarketBalance(), _valueInUnderlying(WETH, wethSpent), 0.005e18, "single-sided valuation");
    }

    function testBalanceFullRangePosition() external {
        // given / when — full-range position exercises extreme getSqrtPriceAtTick inputs
        vm.recordLogs();
        _executeEnterNewPosition(
            UniswapV4NewPositionFuseEnterData({
                poolKey: _wethUsdcKey,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1e18,
                amount1Desired: 3_000e6,
                amount0Max: 2e18,
                amount1Max: 6_000e6,
                hookData: bytes(""),
                deadline: block.timestamp + 100
            })
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (, , uint256 amount0, uint256 amount1) = _extractNewPositionEnterEvent(entries);

        // then
        uint256 expected = _valueInUnderlying(WETH, amount0) + _valueInUnderlying(USDC, amount1);
        assertApproxEqRel(_v4MarketBalance(), expected, 0.005e18, "full-range valuation");
    }

    function testBalanceRoundTripCloseMatchesValuation() external {
        // given — valuation just before closing should match what the vault actually receives
        uint256 tokenId = _openPosition(_usdcCbbtcKey, 1000, 10_000e6, 10e6);
        _swapV4(_usdcCbbtcKey, true, 50_000e6);
        _refreshMarketBalance();
        uint256 valuationBeforeClose = _v4MarketBalance();

        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 cbbtcBefore = ERC20(CBBTC).balanceOf(_plasmaVault);

        // when
        _closePosition(tokenId);

        // then
        uint256 receivedValue = _valueInUnderlying(USDC, ERC20(USDC).balanceOf(_plasmaVault) - usdcBefore) +
            _valueInUnderlying(CBBTC, ERC20(CBBTC).balanceOf(_plasmaVault) - cbbtcBefore);

        assertApproxEqRel(receivedValue, valuationBeforeClose, 0.005e18, "valuation matches realized amounts");
    }

    function testBalanceManipulationSensitivity() external {
        // given — documents the spot-price valuation exposure (design doc §4.3): a large swap moves the
        // pool price; both legs are still valued at oracle prices, so NAV drifts only by the range shift
        _openPosition(_usdcCbbtcKey, 2_000, 20_000e6, 20e6);
        _refreshMarketBalance();
        uint256 balanceBefore = _v4MarketBalance();

        // when — push the price hard, then refresh
        _swapV4(_usdcCbbtcKey, true, 2_000_000e6);
        _refreshMarketBalance();
        uint256 balanceAfter = _v4MarketBalance();

        // then — drift bounded for an in-range->skewed position at oracle pricing (spot-composition
        // valuation at oracle prices — accepted v1 risk, design doc section 4.3)
        uint256 drift = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : balanceBefore - balanceAfter;
        assertGt(drift, 0, "manipulation shifts NAV (documented spot-composition exposure)");
        assertLt(drift, (balanceBefore * 10) / 100, "NAV drift below 10% under heavy pool manipulation");
    }

    function testBalanceGasAtTenPositions() external {
        // given
        for (uint256 i; i < 10; ++i) {
            _openPosition(_wethUsdcKey, int24(int256(1000 + i * 100)), 5e17, 1_500e6);
        }

        // when — measure a full balance refresh over 10 positions
        uint256 gasBefore = gasleft();
        _refreshMarketBalance();
        uint256 gasUsed = gasBefore - gasleft();

        // then
        assertGt(_v4MarketBalance(), 0, "ten positions valued");
        assertLt(gasUsed, 5_000_000, "balance refresh for 10 positions below 5M gas");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev Extracts the SECOND UniswapV4NewPositionFuseEnter event from recorded logs.
    function _extractSecondEnterEvent(
        Vm.Log[] memory entries_
    ) private pure returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        uint256 found;
        for (uint256 i; i < entries_.length; i++) {
            if (
                entries_[i].topics[0] ==
                keccak256("UniswapV4NewPositionFuseEnter(address,uint256,uint128,uint256,uint256,bytes32,int24,int24)")
            ) {
                found++;
                if (found == 2) {
                    (, tokenId, liquidity, amount0, amount1, , , ) = abi.decode(
                        entries_[i].data,
                        (address, uint256, uint128, uint256, uint256, bytes32, int24, int24)
                    );
                    break;
                }
            }
        }
    }
}
