// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PlasmaVaultConfigLib} from "../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../../../contracts/libraries/PlasmaVaultLib.sol";
import {VelodromeSuperchainBalanceFuse} from "../../../../contracts/fuses/velodrome_superchain/VelodromeSuperchainBalanceFuse.sol";
import {
    VelodromeSuperchainSubstrateLib,
    VelodromeSuperchainSubstrate,
    VelodromeSuperchainSubstrateType
} from "../../../../contracts/fuses/velodrome_superchain/VelodromeSuperchainLib.sol";

/// @notice Minimal stand-in for a PlasmaVault: it owns the ERC-7201 storage the balance fuse reads
///         (granted market substrates, price oracle middleware) and delegatecalls the fuse exactly
///         the way `PlasmaVaultMarketsLib.updateMarketsBalances` does.
contract VelodromeBalanceFuseHarness {
    error BalanceOfFailed();

    function configure(uint256 marketId_, bytes32[] memory substrates_, address priceOracleMiddleware_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    function readBalance(address fuse_) external returns (uint256) {
        (bool success, bytes memory data) = fuse_.delegatecall(abi.encodeWithSignature("balanceOf()"));

        if (!success) {
            revert BalanceOfFailed();
        }

        return abi.decode(data, (uint256));
    }
}

/// @title VelodromeSuperchainBalanceFuseFairReserveTest
/// @notice IL-7957 regression tests for `VelodromeSuperchainBalanceFuse`, driven entirely from mocks.
/// @dev The Velodrome Superchain fork suite (`test/fuses/velodrome/VelodromeSuperchainFuseTests.t.sol`)
///      is red for an unrelated reason - its `setUp()` reverts with `WrongAddress()` on the INK fork at
///      block 19702898 - so the Velodrome side of this fix is proven here, without a fork. The fuse is
///      deployed locally with `new`, so these tests execute the bytecode built from this working tree.
contract VelodromeSuperchainBalanceFuseFairReserveTest is Test {
    uint256 private constant _MARKET_ID = 777;

    /// @dev token0: 18 decimals, token1: 6 decimals, both priced at exactly 1 USD (18 price decimals).
    address private constant _TOKEN_0 = address(0xA0);
    address private constant _TOKEN_1 = address(0xB0);
    address private constant _POOL = address(0xC0);
    address private constant _PRICE_ORACLE = address(0xD0);

    uint256 private constant _WAD = 1e18;

    VelodromeSuperchainBalanceFuse private _fuse;
    VelodromeBalanceFuseHarness private _harness;

    function setUp() public {
        _fuse = new VelodromeSuperchainBalanceFuse(_MARKET_ID);
        _harness = new VelodromeBalanceFuseHarness();

        // Give every mocked address code so high-level calls are not rejected by the extcodesize check
        vm.etch(_TOKEN_0, hex"01");
        vm.etch(_TOKEN_1, hex"01");
        vm.etch(_POOL, hex"01");
        vm.etch(_PRICE_ORACLE, hex"01");

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = VelodromeSuperchainSubstrateLib.substrateToBytes32(
            VelodromeSuperchainSubstrate({
                substrateAddress: _POOL,
                substrateType: VelodromeSuperchainSubstrateType.Pool
            })
        );

        _harness.configure(_MARKET_ID, substrates, _PRICE_ORACLE);

        vm.mockCall(_TOKEN_0, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.mockCall(_TOKEN_1, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));

        vm.mockCall(
            _PRICE_ORACLE,
            abi.encodeWithSignature("getAssetPrice(address)", _TOKEN_0),
            abi.encode(uint256(1e18), uint256(18))
        );
        vm.mockCall(
            _PRICE_ORACLE,
            abi.encodeWithSignature("getAssetPrice(address)", _TOKEN_1),
            abi.encode(uint256(1e18), uint256(18))
        );

        vm.mockCall(_POOL, abi.encodeWithSignature("token0()"), abi.encode(_TOKEN_0));
        vm.mockCall(_POOL, abi.encodeWithSignature("token1()"), abi.encode(_TOKEN_1));

        // The vault owns the whole pool, so the reported balance is the pool's own basket value
        vm.mockCall(_POOL, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1e18)));
        vm.mockCall(_POOL, abi.encodeWithSignature("balanceOf(address)", address(_harness)), abi.encode(uint256(1e18)));

        // Fee accounting is out of scope for this vector - zero it out so the assertions isolate the
        // liquidity leg
        vm.mockCall(_POOL, abi.encodeWithSignature("index0()"), abi.encode(uint256(0)));
        vm.mockCall(_POOL, abi.encodeWithSignature("index1()"), abi.encode(uint256(0)));
        vm.mockCall(_POOL, abi.encodeWithSignature("supplyIndex0(address)", address(_harness)), abi.encode(uint256(0)));
        vm.mockCall(_POOL, abi.encodeWithSignature("supplyIndex1(address)", address(_harness)), abi.encode(uint256(0)));
        vm.mockCall(_POOL, abi.encodeWithSignature("claimable0(address)", address(_harness)), abi.encode(uint256(0)));
        vm.mockCall(_POOL, abi.encodeWithSignature("claimable1(address)", address(_harness)), abi.encode(uint256(0)));
    }

    function _setPool(uint256 reserve0_, uint256 reserve1_, bool stable_) private {
        vm.mockCall(
            _POOL,
            abi.encodeWithSignature("getReserves()"),
            abi.encode(reserve0_, reserve1_, uint256(block.timestamp))
        );
        vm.mockCall(_POOL, abi.encodeWithSignature("stable()"), abi.encode(stable_));
    }

    /// @dev The pre-fix valuation: the vault's pro-rata share of the LIVE reserves, priced with the
    ///      oracle. With totalSupply == liquidity and both tokens at 1 USD this is just the basket
    ///      value of the live reserves, in WAD.
    function _spotValuation(uint256 reserve0_, uint256 reserve1_) private pure returns (uint256) {
        return reserve0_ + reserve1_ * 1e12;
    }

    // --- Solidly stable-curve reference, transcribed from the pool's own implementation ------------

    function _f(uint256 x0_, uint256 y_) private pure returns (uint256) {
        uint256 a = (x0_ * y_) / _WAD;
        uint256 b = ((x0_ * x0_) / _WAD + (y_ * y_) / _WAD);
        return (a * b) / _WAD;
    }

    function _d(uint256 x0_, uint256 y_) private pure returns (uint256) {
        return (3 * x0_ * ((y_ * y_) / _WAD)) / _WAD + ((((x0_ * x0_) / _WAD) * x0_) / _WAD);
    }

    /// @dev `Pool._get_y`: the y that keeps the stable invariant at `xy_` for a given `x0_`.
    function _getY(uint256 x0_, uint256 xy_, uint256 y_) private pure returns (uint256) {
        for (uint256 i; i < 255; ++i) {
            uint256 yPrev = y_;
            uint256 k = _f(x0_, y_);

            if (k < xy_) {
                y_ = y_ + ((xy_ - k) * _WAD) / _d(x0_, y_);
            } else {
                y_ = y_ - ((k - xy_) * _WAD) / _d(x0_, y_);
            }

            if (y_ > yPrev) {
                if (y_ - yPrev <= 1) {
                    return y_;
                }
            } else {
                if (yPrev - y_ <= 1) {
                    return y_;
                }
            }
        }

        return y_;
    }

    /// @notice IL-7957 (stable branch): moving the pool along its own stable invariant must not change
    /// the reported balance. Before the fix the fuse split the vault's LP over the LIVE reserves, so
    /// the same on-curve move inflated the reported value by more than 100%.
    function test_shouldNotInflateBalanceWhenStablePoolReservesMovedAlongInvariant() public {
        // given - reserves at the oracle-consistent point: 1000 whole units of each token, both 1 USD
        _setPool(1000e18, 1000e6, true);

        uint256 balanceBefore = _harness.readBalance(address(_fuse));

        // when - a single swap pushes the pool 4x along its own invariant (k preserved exactly, as an
        // Aerodrome/Velodrome swap does: the fee is skimmed to PoolFees before the invariant check)
        uint256 invariant = _f(1000e18, 1000e18);
        uint256 manipulatedNormalized0 = 4000e18;
        uint256 manipulatedNormalized1 = _getY(manipulatedNormalized0, invariant, 1000e18);

        _setPool(manipulatedNormalized0, manipulatedNormalized1 / 1e12, true);

        uint256 balanceAfter = _harness.readBalance(address(_fuse));

        // then - the manipulation is worth more than 100% of NAV when read off spot reserves ...
        assertGt(
            _spotValuation(manipulatedNormalized0, manipulatedNormalized1 / 1e12),
            (_spotValuation(1000e18, 1000e6) * 190) / 100,
            "the manipulation must actually move the spot valuation, otherwise this test proves nothing"
        );

        // ... and none of it reaches the fuse
        assertApproxEqRel(
            balanceAfter,
            balanceBefore,
            1e12,
            "stable pool: balance must not move when the pool is pushed along its own invariant"
        );
        assertApproxEqAbs(balanceBefore, 2000e18, 1e15, "baseline balance must be the 2000 USD basket");
    }

    /// @notice IL-7957 (volatile branch): moving the pool along `x * y = k` must not change the
    /// reported balance.
    function test_shouldNotInflateBalanceWhenVolatilePoolReservesMovedAlongInvariant() public {
        // given - reserves at the oracle-consistent point of x * y = k
        _setPool(1000e18, 1000e6, false);

        uint256 balanceBefore = _harness.readBalance(address(_fuse));

        // when - a single swap pushes the pool 4x along x * y = k
        uint256 invariant = uint256(1000e18) * uint256(1000e6);
        uint256 manipulatedReserve0 = 4000e18;
        uint256 manipulatedReserve1 = invariant / manipulatedReserve0;

        _setPool(manipulatedReserve0, manipulatedReserve1, false);

        uint256 balanceAfter = _harness.readBalance(address(_fuse));

        // then
        assertGt(
            _spotValuation(manipulatedReserve0, manipulatedReserve1),
            (_spotValuation(1000e18, 1000e6) * 190) / 100,
            "the manipulation must actually move the spot valuation, otherwise this test proves nothing"
        );

        assertApproxEqRel(
            balanceAfter,
            balanceBefore,
            1e12,
            "volatile pool: balance must not move when the pool is pushed along x * y = k"
        );
        assertApproxEqAbs(balanceBefore, 2000e18, 1e15, "baseline balance must be the 2000 USD basket");
    }

    /// @notice Healthy-price sanity pin: at the oracle-consistent composition the fair valuation must
    /// agree with the spot valuation, so normal accounting is not distorted by the fix. Both branches
    /// are reached through healthy, unmanipulated reserves.
    function test_fairValuationMatchesSpotValuationAtHealthyPrice() public {
        _setPool(1000e18, 1000e6, true);
        assertApproxEqRel(
            _harness.readBalance(address(_fuse)),
            _spotValuation(1000e18, 1000e6),
            1e12,
            "stable pool: fair valuation must match spot at the oracle-consistent composition"
        );

        _setPool(1000e18, 1000e6, false);
        assertApproxEqRel(
            _harness.readBalance(address(_fuse)),
            _spotValuation(1000e18, 1000e6),
            1e12,
            "volatile pool: fair valuation must match spot at the oracle-consistent composition"
        );
    }

    /// @notice Healthy-price sanity pin with ASYMMETRIC prices (token1 at 4 USD, token0 at 1 USD).
    /// @dev The equal-price variant above cannot detect a fair-reserve formula whose two price weights
    /// are transposed, because transposing equal weights is a no-op. Here the reserves are placed at the
    /// oracle-consistent point of `x * y = k` for a 1:4 price (1000 whole token0 against 250 whole
    /// token1, i.e. 1000 USD on each leg), so any inversion of the weights moves the reported value.
    function test_fairValuationMatchesSpotValuationAtHealthyPriceWithAsymmetricPrices() public {
        vm.mockCall(
            _PRICE_ORACLE,
            abi.encodeWithSignature("getAssetPrice(address)", _TOKEN_1),
            abi.encode(uint256(4e18), uint256(18))
        );

        _setPool(1000e18, 250e6, false);

        // 1000 whole token0 at 1 USD + 250 whole token1 at 4 USD = 2000 USD
        assertApproxEqRel(
            _harness.readBalance(address(_fuse)),
            2000e18,
            1e12,
            "volatile pool: fair valuation must match spot at an asymmetric-price healthy composition"
        );
    }

    /// @notice `_calculateBalanceFromLiquidity` must not divide by zero when a granted pool has no
    /// LP supply at all - `balanceOf()` reverting would propagate into `totalAssets()`.
    function test_shouldReturnZeroLiquidityValueWhenTotalSupplyIsZero() public {
        _setPool(1000e18, 1000e6, false);
        vm.mockCall(_POOL, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(0)));

        assertEq(_harness.readBalance(address(_fuse)), 0, "balance must be zero, not a revert");
    }
}
