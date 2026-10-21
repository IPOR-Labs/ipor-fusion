// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipDecimalsLib} from "../../contracts/crosschain/ccip/lib/CcipDecimalsLib.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

contract CcipDecimalsCeilHarness {
    function toSDCeil(uint256 amountLD_, uint256 rate_) external pure returns (uint256) {
        return CcipDecimalsLib.toSDCeil(amountLD_, rate_);
    }
}

/// @title CcipDecimalsCeilTest
/// @notice IL-8592: the ledger-debit ceiling must not wrap near 2^256, and the decimals gap is capped at 18.
contract CcipDecimalsCeilTest is Test {
    CcipDecimalsCeilHarness internal h = new CcipDecimalsCeilHarness();

    function testShouldCeilWithoutOverflowNearUint256Max() public view {
        uint256 rate = 1e12;
        for (uint256 k = 0; k < 5; k++) {
            uint256 amount = type(uint256).max - k;
            uint256 expected = amount / rate + (amount % rate == 0 ? 0 : 1);
            assertEq(h.toSDCeil(amount, rate), expected, "ceil must not wrap");
            uint256 floor = amount / rate;
            assertEq(h.toSDCeil(amount, rate), amount % rate == 0 ? floor : floor + 1, "ceil is floor or floor + 1");
        }
        assertEq(h.toSDCeil(type(uint256).max, 1e12), type(uint256).max / 1e12 + 1);
    }

    function testShouldCeilExactMultiple() public view {
        assertEq(h.toSDCeil(5e12, 1e12), 5);
        assertEq(h.toSDCeil(0, 1e12), 0);
        assertEq(h.toSDCeil(5e12 + 1, 1e12), 6);
        assertEq(h.toSDCeil(7, 1), 7);
    }

    function testShouldRejectDecimalsGapAbove18() public {
        MockCcipRouter router = new MockCcipRouter();
        MockERC20 token = new MockERC20("Wide", "WIDE", 36);
        // gap 36 - 17 = 19 -> rejected; gap 18 is accepted.
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.DecimalsGapTooLarge.selector, uint8(36), uint8(17)));
        new CcipCrosschainExecutor(
            address(router), address(1), address(this), address(token), keccak256("W"), 17, _safety()
        );

        CcipRouteConfig memory route = CcipRouteConfig({
            chainSelector: 1,
            peer: address(2),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainDispatcher.DecimalsGapTooLarge.selector, uint8(36), uint8(17))
        );
        new CcipCrosschainDispatcher(
            address(router),
            address(1),
            address(token),
            keccak256("W"),
            17,
            block.chainid,
            route,
            address(0xA11),
            address(0xB22),
            3 days
        );

        // Boundary: gap of exactly 18 deploys.
        new CcipCrosschainExecutor(
            address(router), address(1), address(this), address(token), keccak256("W"), 18, _safety()
        );
        new CcipCrosschainDispatcher(
            address(router),
            address(1),
            address(token),
            keccak256("W"),
            18,
            block.chainid,
            route,
            address(0xA11),
            address(0xB22),
            3 days
        );
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: address(0xA11),
            rescueGuardian: address(0xB22),
            balanceProposer: address(this),
            balanceApprover: address(0xA33),
            rescueDelay: 3 days,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000,
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }
}
