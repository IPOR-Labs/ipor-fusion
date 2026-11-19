// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {EulerV2SwapPoolForkFixture} from "./EulerV2SwapPoolFairValueForkTest.t.sol";
import {EulerV2SwapFairPointLib} from "../../../contracts/fuses/euler/EulerV2SwapFairPointLib.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";

/// @title EulerV2SwapPoolFairPointForkTest
/// @notice IL-9706: the fair point of `EulerV2SwapFairPointLib` against the real EulerSwap pool `CurveLib.verify`.
///         A fee-free pool is deployed through the deploy fuse (with its pool entry), the cbETH feed moves, and a swap
///         that lands exactly on the fair point passes while the same swap with the input one base unit short reverts
///         `CurveViolation()`: the point is accepted by the real curve check and is the edge of the admissible region.
///         The suite imports the new library, so it is a post-change proof only (it is not run on the base commit).
contract EulerV2SwapPoolFairPointForkTest is EulerV2SwapPoolForkFixture {
    uint64 internal constant _C_HALF = 5e17;
    uint64 internal constant _C_ONE = 1e18;

    address internal constant _RECEIVER = address(0xCAFE);

    /// @dev Fee-free copy of the fixture curve at concentration `c_` and minimum reserve of asset0 `minReserve0_`
    function _feeFreeParams(
        uint64 c_,
        uint112 minReserve0_
    ) internal pure returns (IEulerV2Swap.DynamicParams memory dp) {
        dp = _dynamicParams(c_);
        dp.fee0 = 0;
        dp.fee1 = 0;
        dp.minReserve0 = minReserve0_;
    }

    function _prices() internal view returns (EulerV2SwapFairPointLib.AssetPrices memory prices) {
        prices = EulerV2SwapFairPointLib.AssetPrices({
            price0Wad: _priceWad(_CBETH),
            price1Wad: _priceWad(_WETH),
            decimals0: 18,
            decimals1: 18
        });
    }

    /// @dev Deploys the fee-free pool through the deploy fuse and moves the cbETH feed by `bps_`
    function _deployFeeFree(uint64 c_, uint112 minReserve0_, int256 bps_) internal returns (uint256, uint256) {
        IEulerV2Swap.DynamicParams memory dp = _feeFreeParams(c_, minReserve0_);

        _grantSubstrates(_pool);
        FuseAction[] memory supply = _supplyActions(10e18, 10e18);
        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = supply[0];
        actions[1] = supply[1];
        actions[2] = _deployAction(dp, _initialState());
        _execute(actions);

        _setCbEthFeedMove(bps_);
        return EulerV2SwapFairPointLib.fairPoint(dp, _prices());
    }

    /// @dev Swaps from the equilibrium reserves (5e18, 5e18) to the point `(fair0_, fair1_)`: the swapper puts the input
    ///      in front of the swap (like the periphery does), `shortBy_` base units short, and takes the output
    function _swapFromEquilibriumTo(uint256 fair0_, uint256 fair1_, uint256 shortBy_, bool expectViolation_) internal {
        uint256 out0 = fair0_ < 5e18 ? 5e18 - fair0_ : 0;
        uint256 out1 = fair1_ < 5e18 ? 5e18 - fair1_ : 0;
        assertTrue(out0 + out1 > 0, "the oracle move put the fair point away from the equilibrium");

        if (fair0_ > 5e18) {
            deal(_CBETH, _pool, fair0_ - 5e18 - shortBy_);
        } else {
            deal(_WETH, _pool, fair1_ - 5e18 - shortBy_);
        }
        if (expectViolation_) {
            vm.expectRevert(abi.encodeWithSignature("CurveViolation()"));
        }
        _poolSwap(_pool, out0, out1, _RECEIVER, "");
    }

    function _reserves() internal view returns (uint256 reserve0, uint256 reserve1) {
        (uint112 r0, uint112 r1, ) = IEulerV2Swap(_pool).getReserves();
        return (r0, r1);
    }

    // -----------------------------------------------------------------------
    // Concentrated curve, cbETH dearer than the curve price (fair point on the asset0 side)
    // -----------------------------------------------------------------------

    function testShouldAcceptSwapLandingExactlyOnFairPointAssetZeroSide() public {
        (uint256 fair0, uint256 fair1) = _deployFeeFree(_C_HALF, 0, 500);
        _swapFromEquilibriumTo(fair0, fair1, 0, false);
        (uint256 r0, uint256 r1) = _reserves();
        assertLt(fair0, 5e18, "fair point is below the equilibrium reserve of asset0");
        assertEq(r0, fair0, "reserve0 landed on the fair point");
        assertEq(r1, fair1, "reserve1 landed on the fair point");
        // the displacement is rounded up (reserves) against down (fair point): a few wei of USD WAD at most
        assertLe(
            EulerV2SwapFairPointLib.poolDisplacementWad(_feeFreeParams(_C_HALF, 0), r0, r1, _prices()),
            10,
            "no displacement at the fair point beyond rounding"
        );
        // the balance fuse values the pool at the fair point without a revert
        assertGt(_nav(), 0, "refresh works with the pool at the fair point");
    }

    function testShouldRevertSwapOneUnitShortOfFairPointAssetZeroSide() public {
        (uint256 fair0, uint256 fair1) = _deployFeeFree(_C_HALF, 0, 500);
        _swapFromEquilibriumTo(fair0, fair1, 1, true);
    }

    // -----------------------------------------------------------------------
    // Concentrated curve, cbETH cheaper than the curve price (fair point on the asset1 side)
    // -----------------------------------------------------------------------

    function testShouldAcceptSwapLandingExactlyOnFairPointAssetOneSide() public {
        (uint256 fair0, uint256 fair1) = _deployFeeFree(_C_HALF, 0, -500);
        _swapFromEquilibriumTo(fair0, fair1, 0, false);
        (uint256 r0, uint256 r1) = _reserves();
        assertLt(fair1, 5e18, "fair point is below the equilibrium reserve of asset1");
        assertEq(r0, fair0, "reserve0 landed on the fair point");
        assertEq(r1, fair1, "reserve1 landed on the fair point");
    }

    function testShouldRevertSwapOneUnitShortOfFairPointAssetOneSide() public {
        (uint256 fair0, uint256 fair1) = _deployFeeFree(_C_HALF, 0, -500);
        _swapFromEquilibriumTo(fair0, fair1, 1, true);
    }

    // -----------------------------------------------------------------------
    // Constant-sum corner (concentration 1e18), oracle price moved in the feed
    // -----------------------------------------------------------------------

    function testShouldAcceptSwapLandingExactlyOnFairPointInConstantSumCorner() public {
        (uint256 fair0, uint256 fair1) = _deployFeeFree(_C_ONE, 1e18, 500);
        _swapFromEquilibriumTo(fair0, fair1, 0, false);
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(fair0, 1e18, "constant sum: the fair point is the lowest admissible reserve");
        assertEq(r0, fair0, "reserve0 landed in the corner");
        assertEq(r1, fair1, "reserve1 landed in the corner");
        assertLe(
            EulerV2SwapFairPointLib.poolDisplacementWad(_feeFreeParams(_C_ONE, 1e18), r0, r1, _prices()),
            10,
            "no displacement in the corner beyond rounding"
        );
    }

    function testShouldRevertSwapOneUnitShortOfFairPointInConstantSumCorner() public {
        (uint256 fair0, uint256 fair1) = _deployFeeFree(_C_ONE, 1e18, 500);
        _swapFromEquilibriumTo(fair0, fair1, 1, true);
    }
}
