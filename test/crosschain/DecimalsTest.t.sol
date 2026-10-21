// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {StargateBaseHarness} from "./mocks/StargateBaseHarness.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title DecimalsTest
/// @notice Exercises `StargateOAppBase._toSD`/`_toLD` via a tiny concrete harness: 18-dec asset with
///         shared=6 (round-trips + dust truncation on send) and the equal-decimals identity case, plus the
///         constructor's decimals/asset validations (spec §5, plan §4.5).
contract DecimalsTest is Test {
    MockLzEndpoint internal endpoint;
    address internal admin = address(0xA11CE);
    address internal guardian = address(0x6047D1A2);

    function setUp() public {
        endpoint = new MockLzEndpoint();
    }

    function _deployHarness(uint8 assetDecimals_, uint8 sharedDecimals_) internal returns (StargateBaseHarness) {
        MockERC20 asset = new MockERC20("Asset", "AST", assetDecimals_);
        MockStargatePool pool = new MockStargatePool(address(asset), sharedDecimals_);
        return new StargateBaseHarness(
            address(endpoint), address(this), admin, guardian, 1 days, address(asset), address(pool)
        );
    }

    // ---------------------------------------------------------------------
    // 18-dec local, 6 shared
    // ---------------------------------------------------------------------

    function testShouldConvertLocalToSharedForEighteenDecAsset() public {
        StargateBaseHarness h = _deployHarness(18, 6);
        assertEq(h.toSD(1e18), 1e6, "1.0 in 18-dec -> 1.0 in 6-dec");
        assertEq(h.toSD(123_456789 * 1e12), 123_456789, "scaled down by 1e12");
        assertEq(h.LOCAL_DECIMALS(), 18);
        assertEq(h.SHARED_DECIMALS(), 6);
    }

    function testShouldConvertSharedToLocalForEighteenDecAsset() public {
        StargateBaseHarness h = _deployHarness(18, 6);
        assertEq(h.toLD(1e6), 1e18, "1.0 in 6-dec -> 1.0 in 18-dec");
        assertEq(h.toLD(999_999), 999_999 * 1e12);
    }

    function testShouldRoundTripLocalSharedLocalWhenNoDust() public {
        StargateBaseHarness h = _deployHarness(18, 6);
        uint256 amount = 7_000000 * 1e12; // exactly representable at 6 shared decimals
        assertEq(h.toLD(h.toSD(amount)), amount, "clean round-trip");
    }

    function testShouldTruncateDustBelowSharedPrecisionOnToSD() public {
        StargateBaseHarness h = _deployHarness(18, 6);
        // 1.000000_000000000005 units: the trailing 5 (below 1e-6) is dust and must be dropped on send.
        uint256 amountWithDust = 1e18 + 5;
        assertEq(h.toSD(amountWithDust), 1e6, "dust truncated to 6-dec");
        assertEq(h.toLD(h.toSD(amountWithDust)), 1e18, "round-trip drops the sub-precision dust");
        assertLt(h.toLD(h.toSD(amountWithDust)), amountWithDust, "never bridges more than the truncated amount");
    }

    function testShouldTruncateFullSubPrecisionToZero() public {
        StargateBaseHarness h = _deployHarness(18, 6);
        assertEq(h.toSD(1e12 - 1), 0, "less than one shared unit truncates to zero");
    }

    // ---------------------------------------------------------------------
    // Equal decimals -> identity
    // ---------------------------------------------------------------------

    function testShouldBeIdentityWhenLocalEqualsShared() public {
        StargateBaseHarness h = _deployHarness(6, 6);
        assertEq(h.toSD(123456), 123456, "toSD identity");
        assertEq(h.toLD(123456), 123456, "toLD identity");
        assertEq(h.toLD(h.toSD(987654)), 987654, "identity round-trip");
    }

    // ---------------------------------------------------------------------
    // Constructor validations
    // ---------------------------------------------------------------------

    function testShouldRevertWhenLocalDecimalsBelowShared() public {
        MockERC20 asset = new MockERC20("Asset", "AST", 6);
        MockStargatePool pool = new MockStargatePool(address(asset), 8);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidDecimals.selector, uint8(6), uint8(8)));
        new StargateBaseHarness(
            address(endpoint), address(this), admin, guardian, 1 days, address(asset), address(pool)
        );
    }

    function testShouldRevertWhenPoolTokenMismatchesAsset() public {
        MockERC20 asset = new MockERC20("Asset", "AST", 6);
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        MockStargatePool pool = new MockStargatePool(address(other), 6);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.StargatePoolAssetMismatch.selector, address(asset), address(other))
        );
        new StargateBaseHarness(
            address(endpoint), address(this), admin, guardian, 1 days, address(asset), address(pool)
        );
    }
}
