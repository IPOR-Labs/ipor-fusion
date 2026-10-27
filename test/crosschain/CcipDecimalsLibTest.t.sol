// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipDecimalsLib} from "../../contracts/crosschain/ccip/lib/CcipDecimalsLib.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

contract CcipDecimalsLibHarness {
    function toSDExact(uint256 amountLD_, uint256 rate_) external pure returns (uint256) {
        return CcipDecimalsLib.toSDExact(amountLD_, rate_);
    }

    function toSDFloor(uint256 amountLD_, uint256 rate_) external pure returns (uint256) {
        return CcipDecimalsLib.toSDFloor(amountLD_, rate_);
    }

    function toLD(uint256 amountSD_, uint256 rate_) external pure returns (uint256) {
        return CcipDecimalsLib.toLD(amountSD_, rate_);
    }

    function normalizeActionData(
        uint8 action_,
        bytes calldata data_,
        uint256 rate_
    ) external pure returns (bytes memory) {
        return CcipDecimalsLib.normalizeActionData(action_, data_, rate_);
    }
}

/// @title CcipDecimalsLibTest
/// @notice IL-9017: pins the local <-> shared decimal conversions of the CCIP transport and the per-action
///         normalization of command data (only the asset-denominated fields are scaled, share fields never).
contract CcipDecimalsLibTest is Test {
    uint256 internal constant RATE = 1e12;

    CcipDecimalsLibHarness internal h = new CcipDecimalsLibHarness();

    address internal constant VAULT = address(0xA1);
    address internal constant MANAGER = address(0xA2);
    address internal constant RECEIVER = address(0xA3);

    function testShouldConvertExactMultipleToSharedDecimals() public view {
        assertEq(h.toSDExact(50e18, RATE), 50e6);
        assertEq(h.toSDExact(0, RATE), 0);
        assertEq(h.toSDExact(RATE, RATE), 1);
        assertEq(h.toSDExact(7, 1), 7);
    }

    function testShouldRevertExactConversionWithAmountHasDust() public {
        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, 50e18 + 1));
        h.toSDExact(50e18 + 1, RATE);

        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, RATE - 1));
        h.toSDExact(RATE - 1, RATE);
    }

    function testShouldFloorWithoutReverting() public view {
        assertEq(h.toSDFloor(50e18 + 1, RATE), 50e6);
        assertEq(h.toSDFloor(50e18 - 1, RATE), 50e6 - 1);
        assertEq(h.toSDFloor(RATE - 1, RATE), 0);
        assertEq(h.toSDFloor(type(uint256).max, RATE), type(uint256).max / RATE);
    }

    function testShouldScaleSharedDecimalsToLocal() public view {
        assertEq(h.toLD(50e6, RATE), 50e18);
        assertEq(h.toLD(0, RATE), 0);
        assertEq(h.toLD(1, RATE), RATE);
        assertEq(h.toLD(h.toSDExact(123e18, RATE), RATE), 123e18, "exact round trip");
    }

    function testShouldScaleDepositAmountAndKeepMinShares() public view {
        bytes memory out = h.normalizeActionData(
            uint8(BusinessAction.DEPOSIT),
            abi.encode(VAULT, uint256(50e18), uint256(49e18)),
            RATE
        );
        assertEq(out, abi.encode(VAULT, uint256(50e6), uint256(49e18)), "amount scaled, minShares untouched");
    }

    function testShouldRevertDepositNormalizationOnDust() public {
        bytes memory data = abi.encode(VAULT, uint256(50e18 + 1), uint256(0));
        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, 50e18 + 1));
        h.normalizeActionData(uint8(BusinessAction.DEPOSIT), data, RATE);
    }

    function testShouldScaleRedeemMinAssetsAndKeepShares() public view {
        bytes memory out = h.normalizeActionData(
            uint8(BusinessAction.REDEEM),
            abi.encode(VAULT, uint256(50e18), uint256(49e18)),
            RATE
        );
        assertEq(out, abi.encode(VAULT, uint256(50e18), uint256(49e6)), "shares untouched, minAssets scaled");
    }

    function testShouldRevertRedeemNormalizationOnDustyMinAssets() public {
        bytes memory data = abi.encode(VAULT, uint256(50e18), uint256(49e18 + 1));
        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, 49e18 + 1));
        h.normalizeActionData(uint8(BusinessAction.REDEEM), data, RATE);
    }

    function testShouldScaleRedeemFromRequestMinAssetsAndKeepOtherFields() public view {
        bytes memory out = h.normalizeActionData(
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            abi.encode(MANAGER, VAULT, uint256(50e18), uint256(49e18), RECEIVER),
            RATE
        );
        assertEq(out, abi.encode(MANAGER, VAULT, uint256(50e18), uint256(49e6), RECEIVER), "only minAssets scaled");
    }

    function testShouldRevertRedeemFromRequestNormalizationOnDustyMinAssets() public {
        bytes memory data = abi.encode(MANAGER, VAULT, uint256(50e18), uint256(49e18 + 1), RECEIVER);
        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, 49e18 + 1));
        h.normalizeActionData(uint8(BusinessAction.REDEEM_FROM_REQUEST), data, RATE);
    }

    function testShouldLeaveRequestSharesDataUnchanged() public view {
        bytes memory data = abi.encode(MANAGER, VAULT, uint256(50e18), type(uint256).max);
        bytes memory out = h.normalizeActionData(uint8(BusinessAction.REQUEST_SHARES), data, RATE);
        assertEq(out, data, "share units are never converted");
    }
}
