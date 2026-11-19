// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PriceOracleMiddlewareManagerLib} from "../../contracts/managers/price/PriceOracleMiddlewareManagerLib.sol";
import {MutableValuePriceFeed} from "./MutableValuePriceFeed.sol";
import {QuoteCurrencyMiddlewareMock} from "./PriceOracleMiddlewareManagerQuoteCurrencyTest.t.sol";

/// @title PriceValidationAsymmetricBandTest
/// @notice IL-9606 (M16), pinning test of the D-059 design (IL-8681): the validation band is |price - baseline| / baseline,
///         so it is not symmetric in ratio terms. After a re-anchor DOWN by d with delta / (1 + delta) < d <= delta, a
///         return to the previous level is outside the band and validation keeps reverting until the ATOMIST recovers
///         (documented in the NatSpec of `validatePriceChange`). These tests pass on the base commit.
contract PriceValidationAsymmetricBandTest is Test {
    address private constant _AUTHORITY = address(0xA11CE);
    address private constant _ASSET = address(0x123);

    uint256 private constant _DELTA = 1e17; // 10%
    uint256 private constant _START = 1e18;
    uint256 private constant _DOWN = 9e17; // -10%: the deviation d equals delta, inside (delta / (1 + delta), delta]
    // d of the way back up from 0.9: 0.1 / 0.9 = 11.11%, rounded down by mulDiv
    uint256 private constant _BACK_UP_DEVIATION = 111111111111111111;

    PriceOracleMiddlewareManager private _manager;
    MutableValuePriceFeed private _feed;

    function setUp() public {
        vm.warp(1_000_000);
        // the authority only gates `restricted` calls; every caller is allowed here
        vm.mockCall(
            _AUTHORITY,
            abi.encodeWithSignature("canCall(address,address,bytes4)"),
            abi.encode(true, uint32(0))
        );
        _manager = new PriceOracleMiddlewareManager(
            _AUTHORITY,
            address(new QuoteCurrencyMiddlewareMock(address(0x348)))
        );
        _feed = new MutableValuePriceFeed(int256(_START));

        address[] memory assets = _assets();
        address[] memory sources = new address[](1);
        sources[0] = address(_feed);
        _manager.setAssetsPriceSources(assets, sources);
        _manager.updatePriceValidation(assets, _delta(_DELTA));

        _validateAt(_START); // first validation takes the price as the baseline
    }

    // ----------------------------------------------------------------------------------------------------------
    // 1. The documented case: down by d (in band) re-anchors, the return is outside the band and keeps reverting
    // ----------------------------------------------------------------------------------------------------------

    function testShouldFreezeAfterReanchorDownAndReturnToPreviousLevel() external {
        vm.warp(block.timestamp + 1);
        _validateAt(_DOWN); // exactly delta: accepted, and above delta / 2 so the baseline moves down
        assertEq(_baseline(), _DOWN, "baseline re-anchored down");

        // the return to the old level: 0.1 / 0.9 = 11.11% > 10%
        vm.warp(block.timestamp + 1);
        _validateExpectingExceeded(_DOWN, _START);

        // and it keeps reverting in later blocks: the baseline does not move on a reverting call
        vm.warp(block.timestamp + 1 days);
        _validateExpectingExceeded(_DOWN, _START);
        assertEq(_baseline(), _DOWN, "baseline unchanged by reverting calls");
    }

    function testShouldAcceptReturnWhenReanchoredUpInsteadOfDown() external {
        // contrast: the same 10% move UP then back is inside the band (0.1 / 1.1 = 9.09% <= 10%)
        vm.warp(block.timestamp + 1);
        _validateAt(11e17);
        assertEq(_baseline(), 11e17, "baseline re-anchored up");

        vm.warp(block.timestamp + 1);
        _validateAt(_START);
    }

    // ----------------------------------------------------------------------------------------------------------
    // 2. Both documented recovery paths work
    // ----------------------------------------------------------------------------------------------------------

    function testShouldRecoverByRemovingAndReaddingPriceValidation() external {
        _freeze();

        address[] memory assets = _assets();
        _manager.removePriceValidation(assets);
        _manager.updatePriceValidation(assets, _delta(_DELTA));

        // the next validation takes the current price as the baseline
        vm.warp(block.timestamp + 1);
        _validateAt(_START);
        assertEq(_baseline(), _START, "baseline = current price after re-adding");

        vm.warp(block.timestamp + 1);
        _validateAt(_START);
    }

    function testShouldRecoverByRaisingMaxPriceDeltaToDeviation() external {
        _freeze();

        // delta' = d re-anchors (in a later timestamp than the last baseline write)
        _setDelta(_BACK_UP_DEVIATION);
        vm.warp(block.timestamp + 1);
        _validateAt(_START);
        assertEq(_baseline(), _START, "baseline re-anchored to the old level");

        // the restored delta accepts the new baseline
        _setDelta(_DELTA);
        vm.warp(block.timestamp + 1);
        _validateAt(_START);
    }

    // ----------------------------------------------------------------------------------------------------------
    // 3. The trap: delta' >= 2d accepts the price without re-anchoring
    // ----------------------------------------------------------------------------------------------------------

    function testShouldNotReanchorWhenRaisedDeltaIsTwiceTheDeviation() external {
        _freeze();

        _setDelta(2 * _BACK_UP_DEVIATION);
        vm.warp(block.timestamp + 1);
        _validateAt(_START); // accepted, but not above delta' / 2, so the baseline stays
        assertEq(_baseline(), _DOWN, "baseline did not move");

        // restoring delta: validation reverts again
        _setDelta(_DELTA);
        vm.warp(block.timestamp + 1);
        _validateExpectingExceeded(_DOWN, _START);
    }

    // ----------------------------------------------------------------------------------------------------------
    // helpers
    // ----------------------------------------------------------------------------------------------------------

    /// @dev baseline 1.0 -> in-band drop to 0.9 -> baseline 0.9; the feed is back at 1.0 afterwards
    function _freeze() private {
        vm.warp(block.timestamp + 1);
        _validateAt(_DOWN);
        vm.warp(block.timestamp + 1);
        _validateExpectingExceeded(_DOWN, _START);
    }

    function _validateAt(uint256 price_) private {
        _feed.setPrice(int256(price_));
        _manager.validateAllAssetsPrices();
    }

    function _validateExpectingExceeded(uint256 baseline_, uint256 price_) private {
        _feed.setPrice(int256(price_));
        (uint256 delta, , ) = _manager.getPriceValidationInfo(_ASSET);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracleMiddlewareManagerLib.PriceChangeExceeded.selector,
                _ASSET,
                baseline_,
                price_,
                delta
            )
        );
        _manager.validateAllAssetsPrices();
    }

    function _baseline() private view returns (uint256 baseline) {
        (, baseline, ) = _manager.getPriceValidationInfo(_ASSET);
    }

    function _setDelta(uint256 delta_) private {
        _manager.updatePriceValidation(_assets(), _delta(delta_));
    }

    function _assets() private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = _ASSET;
    }

    function _delta(uint256 delta_) private pure returns (uint256[] memory deltas) {
        deltas = new uint256[](1);
        deltas[0] = delta_;
    }
}
