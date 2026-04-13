// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {VeloraSwapperFuse} from "contracts/fuses/velora/VeloraSwapperFuse.sol";

/// @dev Target contract: contracts/fuses/velora/VeloraSwapperFuse.sol

import {VeloraSwapperEnterData} from "contracts/fuses/velora/VeloraSwapperFuse.sol";
import {VeloraSwapperEnterData, VeloraSwapperFuse} from "contracts/fuses/velora/VeloraSwapperFuse.sol";
contract VeloraSwapperFuseTest is OlympixUnitTest("VeloraSwapperFuse") {
    VeloraSwapperFuse public veloraSwapperFuse;


    function setUp() public override {
        veloraSwapperFuse = new VeloraSwapperFuse(1);
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(veloraSwapperFuse) != address(0), "Contract should be deployed");
    }

    function test_enter_RevertWhenAmountInZero_HitsTrueBranch() public {
            VeloraSwapperEnterData memory data_ = VeloraSwapperEnterData({
                tokenIn: address(0x1),
                tokenOut: address(0x2),
                amountIn: 0,
                minAmountOut: 0,
                swapCallData: bytes("")
            });
    
            vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseZeroAmount.selector);
            veloraSwapperFuse.enter(data_);
        }

    function test_enter_AmountInNonZeroHitsElseBranch() public {
            VeloraSwapperEnterData memory data_ = VeloraSwapperEnterData({
                tokenIn: address(0x1),
                tokenOut: address(0x2),
                amountIn: 1,
                minAmountOut: 0,
                swapCallData: bytes("")
            });
    
            // Expect revert due to unsupported asset when checking substrates,
            // but this comes after the amountIn == 0 check, so the
            // opix-target-branch-145 else-branch is executed.
            vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, address(0x1)));
            veloraSwapperFuse.enter(data_);
        }

    function test_enter_RevertWhenTokenInEqualsTokenOut_HitsTrueBranch() public {
            VeloraSwapperEnterData memory data_ = VeloraSwapperEnterData({
                tokenIn: address(0x1),
                tokenOut: address(0x1),
                amountIn: 1,
                minAmountOut: 0,
                swapCallData: bytes("")
            });
    
            vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSameTokens.selector);
            veloraSwapperFuse.enter(data_);
        }

    function test_checkSubstrates_RevertWhenTokenInIsZero_HitsTrueBranch() public {
            // When tokenIn_ is address(0), the first if in _checkSubstrates
            // (tokenIn_ == address(0)) evaluates to true and reverts with
            // VeloraSwapperFuseUnsupportedAsset(address(0)), hitting
            // opix-target-branch-338-True.
    
            vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, address(0)));
            VeloraSwapperEnterData memory data_ = VeloraSwapperEnterData({
                tokenIn: address(0),
                tokenOut: address(0x2),
                amountIn: 1,
                minAmountOut: 0,
                swapCallData: bytes("")
            });
    
            veloraSwapperFuse.enter(data_);
        }

    function test_checkSubstrates_RevertWhenTokenOutIsZero_HitsTrueBranch() public {
            // Arrange: non-zero tokenIn and zero tokenOut to hit `if (tokenOut_ == address(0))` true branch
            VeloraSwapperEnterData memory data_ = VeloraSwapperEnterData({
                tokenIn: address(0x1),
                tokenOut: address(0),
                amountIn: 1,
                minAmountOut: 0,
                swapCallData: bytes("")
            });
    
            // Expect revert from _checkSubstrates with VeloraSwapperFuseUnsupportedAsset(address(0))
            vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, address(0)));

            // Act
            veloraSwapperFuse.enter(data_);
        }
}