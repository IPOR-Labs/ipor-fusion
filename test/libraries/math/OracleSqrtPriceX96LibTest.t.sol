// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {OracleSqrtPriceX96Lib} from "../../../contracts/libraries/math/OracleSqrtPriceX96Lib.sol";

contract OracleSqrtPriceX96LibHarness {
    function fromRatio(uint256 num_, uint256 den_) external pure returns (uint160) {
        return OracleSqrtPriceX96Lib.fromRatio(num_, den_);
    }

    function fromOracle(address token0_, address token1_, address oracle_) external view returns (uint160) {
        return OracleSqrtPriceX96Lib.fromOracle(token0_, token1_, oracle_);
    }

    /// @dev The complete pre-IL-8789 formula (two-step mulDiv by 2^192 and 10^k), kept for comparison
    function oldFromOracle(address token0_, address token1_, address oracle_) external view returns (uint160) {
        (uint256 price0, uint256 priceDecimals0) = IPriceOracleMiddleware(oracle_).getAssetPrice(token0_);
        (uint256 price1, uint256 priceDecimals1) = IPriceOracleMiddleware(oracle_).getAssetPrice(token1_);
        uint256 numExp = priceDecimals1 + IERC20Metadata(token1_).decimals();
        uint256 denExp = priceDecimals0 + IERC20Metadata(token0_).decimals();
        uint256 ratioX192 = Math.mulDiv(price0, 1 << 192, price1);
        if (numExp >= denExp) {
            ratioX192 = Math.mulDiv(ratioX192, 10 ** (numExp - denExp), 1);
        } else {
            ratioX192 = Math.mulDiv(ratioX192, 1, 10 ** (denExp - numExp));
        }
        return SafeCast.toUint160(Math.sqrt(ratioX192));
    }

    /// @dev The pre-IL-8789 single-ratio formula (scaled by 2^192), kept for comparison
    function oldFromRatio(uint256 num_, uint256 den_) external pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(num_, 1 << 192, den_)));
    }
}

/// @notice IL-8789 / IL-8795: the oracle-implied sqrtPriceX96 must support the whole Q64.96 range
contract OracleSqrtPriceX96LibTest is Test {
    OracleSqrtPriceX96LibHarness private _harness;

    address private constant _TOKEN0 = address(0x1001);
    address private constant _TOKEN1 = address(0x1002);
    address private constant _ORACLE = address(0x2001);

    function setUp() public {
        _harness = new OracleSqrtPriceX96LibHarness();
    }

    function testFromRatio_exactAboveOldLimit() public {
        // P = 2^70 > 2^64: the old formula overflows uint256 in mulDiv
        vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        _harness.oldFromRatio(1 << 70, 1);

        // sqrt(2^70) * 2^96 = 2^35 * 2^96 = 2^131
        assertEq(_harness.fromRatio(1 << 70, 1), uint160(1) << 131, "exact sqrtPriceX96 for P = 2^70");
        // scaling both sides keeps the result exact
        assertEq(_harness.fromRatio(3 << 70, 3), uint160(1) << 131, "exact for non-trivial denominator");
    }

    function testFromRatio_branchBoundary() public view {
        // P = 2^64 takes the multiplication branch: sqrt(2^64) * 2^96 = 2^128
        assertEq(_harness.fromRatio(1 << 64, 1), uint160(1) << 128, "P = 2^64");

        // P just below 2^64 takes the division branch and equals the old formula
        uint160 below = _harness.fromRatio((1 << 64) - 1, 1);
        assertEq(below, _harness.oldFromRatio((1 << 64) - 1, 1), "division branch identical to old formula");

        assertLe(below, uint160(1) << 128, "monotonic across the branch boundary (below)");
        assertGe(
            _harness.fromRatio((1 << 64) + 1, 1),
            uint160(1) << 128,
            "monotonic across the branch boundary (above)"
        );
        assertLe(_harness.fromRatio(1 << 64, 1) - below, 1 << 64, "no jump across the boundary");
    }

    function testFromRatio_revertsOnlyAtQ64_96Limit() public {
        // P = 2^128 - 1 still fits Q64.96
        uint160 maxOk = _harness.fromRatio(type(uint128).max, 1);
        assertGt(maxOk, uint160(1) << 159, "close to the top of the range");
        assertLt(maxOk, type(uint160).max, "fits uint160");

        // P = 2^128 is out of range
        vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        _harness.fromRatio(uint256(1) << 128, 1);
    }

    function testFuzz_fromOracle_matchesOldFormulaBelow2pow64(
        uint256 price0_,
        uint256 price1_,
        uint8 priceDecimals0_,
        uint8 priceDecimals1_,
        uint8 tokenDecimals0_,
        uint8 tokenDecimals1_
    ) public {
        price0_ = bound(price0_, 1e3, 1e14);
        price1_ = bound(price1_, 1e3, 1e14);
        priceDecimals0_ = uint8(bound(priceDecimals0_, 0, 18));
        priceDecimals1_ = uint8(bound(priceDecimals1_, 0, 18));
        tokenDecimals0_ = uint8(bound(tokenDecimals0_, 0, 18));
        tokenDecimals1_ = uint8(bound(tokenDecimals1_, 0, 18));
        _mockOracle(price0_, price1_, priceDecimals0_, priceDecimals1_, tokenDecimals0_, tokenDecimals1_);

        // the full old two-step formula; cases where it reverts (P >= 2^64) are outside this comparison
        try _harness.oldFromOracle(_TOKEN0, _TOKEN1, _ORACLE) returns (uint160 oldValue) {
            uint160 newValue = _harness.fromOracle(_TOKEN0, _TOKEN1, _ORACLE);
            assertTrue(
                newValue == oldValue || newValue == oldValue + 1,
                "new result must equal the old one or exceed it by 1 unit when the old formula does not revert"
            );
        } catch {
            vm.assume(false);
        }
    }

    /// @notice Production domain: the oracle middleware returns 18-decimal prices (`QUOTE_CURRENCY_DECIMALS`), i.e.
    /// 1e15..1e25 for realistic assets. Unlike the test above, P >= 2^64 cases (where the old formula reverts) are
    /// asserted here, not skipped.
    function testFuzz_fromOracle_productionDomain(
        uint256 price0_,
        uint256 price1_,
        uint8 tokenDecimals0_,
        uint8 tokenDecimals1_
    ) public {
        price0_ = bound(price0_, 1e15, 1e25);
        price1_ = bound(price1_, 1e15, 1e25);
        tokenDecimals0_ = uint8(bound(tokenDecimals0_, 0, 24));
        tokenDecimals1_ = uint8(bound(tokenDecimals1_, 0, 24));
        _mockOracle(price0_, price1_, 18, 18, tokenDecimals0_, tokenDecimals1_);

        // num / den exactly as the library computes them (price decimals are equal, so only token decimals scale)
        uint256 num = price0_;
        uint256 den = price1_;
        if (tokenDecimals1_ >= tokenDecimals0_) {
            num *= 10 ** (tokenDecimals1_ - tokenDecimals0_);
        } else {
            den *= 10 ** (tokenDecimals0_ - tokenDecimals1_);
        }

        // P < 2^64 is the exact-floor branch; P >= 2^64 is where the old formula reverts
        bool aboveOldLimit = (num >> 64) >= den;

        uint256 result = _harness.fromOracle(_TOKEN0, _TOKEN1, _ORACLE);

        if (!aboveOldLimit) {
            // exact floor(sqrt(num * 2^192 / den)): r^2 <= X < (r + 1)^2
            uint256 x192 = Math.mulDiv(num, 1 << 192, den);
            assertLe(result * result, x192, "result^2 must not exceed the exact value");
            assertGt((result + 1) * (result + 1), x192, "result must be the exact floor");
            try _harness.oldFromOracle(_TOKEN0, _TOKEN1, _ORACLE) returns (uint160 oldValue) {
                assertTrue(
                    result == oldValue || result == uint256(oldValue) + 1,
                    "new result must equal the old one or exceed it by 1 unit below 2^64"
                );
            } catch {
                revert("old formula must not revert for P < 2^64");
            }
        } else {
            // the old formula reverts here; the new one must not and keeps at least 96 significant bits
            vm.expectRevert();
            _harness.oldFromOracle(_TOKEN0, _TOKEN1, _ORACLE);

            assertGe(result, uint256(1) << 128, "result must be >= 2^128 for P >= 2^64");
            assertEq(result % (1 << 32), 0, "result is a multiple of 2^32 for P >= 2^64");

            // r = floor(sqrt(x)) << 32 with x = floor(num * 2^128 / den): r^2 / 2^64 <= x < (r + 2^32)^2 / 2^64,
            // so r is at most 2^32 units below sqrt(num * 2^192 / den) (hence below its exact floor)
            uint256 x128 = Math.mulDiv(num, 1 << 128, den);
            assertLe(Math.mulDiv(result, result, 1 << 64), x128, "result must not exceed the exact value");
            assertGt(
                Math.mulDiv(result + (1 << 32), result + (1 << 32), 1 << 64),
                x128,
                "result is within 2^32 units of the exact value"
            );
        }
    }

    function _mockOracle(
        uint256 price0_,
        uint256 price1_,
        uint8 priceDecimals0_,
        uint8 priceDecimals1_,
        uint8 tokenDecimals0_,
        uint8 tokenDecimals1_
    ) private {
        vm.mockCall(_TOKEN0, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(tokenDecimals0_));
        vm.mockCall(_TOKEN1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(tokenDecimals1_));
        vm.mockCall(
            _ORACLE,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, _TOKEN0),
            abi.encode(price0_, uint256(priceDecimals0_))
        );
        vm.mockCall(
            _ORACLE,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, _TOKEN1),
            abi.encode(price1_, uint256(priceDecimals1_))
        );
    }

    function testFromOracle_decimalsCase() public {
        // token0: 6 decimals, 1 USD (8 price decimals); token1: 18 decimals, 1e-8 USD (8 price decimals)
        // raw P = (1 / 1e-8) * 10^(18-6) = 1e20 > 2^64: the old formula reverted
        vm.mockCall(_TOKEN0, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
        vm.mockCall(_TOKEN1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(18)));
        vm.mockCall(
            _ORACLE,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, _TOKEN0),
            abi.encode(uint256(1e8), uint256(8))
        );
        vm.mockCall(
            _ORACLE,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, _TOKEN1),
            abi.encode(uint256(1), uint256(8))
        );

        uint160 result = _harness.fromOracle(_TOKEN0, _TOKEN1, _ORACLE);

        // sqrt(1e20) * 2^96 = 1e10 * 2^96 (exact up to floor of the sqrt)
        uint256 expected = 1e10 * (uint256(1) << 96);
        assertApproxEqRel(uint256(result), expected, 1e-9 ether, "sqrtPriceX96 ~ sqrt(1e20) * 2^96");
    }
}
