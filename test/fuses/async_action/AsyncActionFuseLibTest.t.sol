// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AsyncActionFuseLib, AllowedAmountToOutside, AllowedTargets, AllowedSlippage, AsyncActionFuseSubstrate, AsyncActionFuseSubstrateType} from "../../../contracts/fuses/async_action/AsyncActionFuseLib.sol";

contract AsyncActionFuseLibTest is Test {
    function test_encodeAllowedAmountToOutsideRoundTrip() public {
        AllowedAmountToOutside memory input_ = AllowedAmountToOutside({asset: address(0x1234), amount: 1_000_000});

        bytes31 encoded_ = AsyncActionFuseLib.encodeAllowedAmountToOutside(input_);
        AllowedAmountToOutside memory decoded_ = AsyncActionFuseLib.decodeAllowedAmountToOutside(encoded_);

        assertEq(decoded_.asset, input_.asset, "asset");
        assertEq(decoded_.amount, input_.amount, "amount");
    }

    function test_encodeAllowedAmountToOutsideRevertsOnOverflow() public {
        AllowedAmountToOutside memory input_ = AllowedAmountToOutside({
            asset: address(0x1234),
            amount: uint256(type(uint88).max) + 1
        });

        vm.expectRevert(
            abi.encodeWithSelector(AsyncActionFuseLib.AllowedAmountToOutsideAmountTooLarge.selector, input_.amount)
        );
        this.callEncodeAllowedAmountToOutside(input_);
    }

    function test_encodeAllowedTargetsRoundTrip() public {
        AllowedTargets memory input_ = AllowedTargets({
            target: address(0x4567),
            selector: bytes4(keccak256("test(uint256)"))
        });

        bytes31 encoded_ = AsyncActionFuseLib.encodeAllowedTargets(input_);
        AllowedTargets memory decoded_ = AsyncActionFuseLib.decodeAllowedTargets(encoded_);

        assertEq(decoded_.target, input_.target, "target");
        assertEq(uint32(decoded_.selector), uint32(input_.selector), "selector");
    }

    function test_encodeAllowedTargetsUpperBytesAreZero() public {
        // Test that the 7 most significant bytes are always zero after encoding
        AllowedTargets memory input_ = AllowedTargets({
            target: address(0x1234567890AbcdEF1234567890aBcdef12345678),
            selector: bytes4(0xabcdef01)
        });

        bytes31 encoded_ = AsyncActionFuseLib.encodeAllowedTargets(input_);
        uint248 packed = uint248(encoded_);

        // Extract the 7 most significant bytes (bits 192-247) by shifting right 192 bits
        uint256 upperBytes = uint256(packed >> 192);

        // Assert that the upper 7 bytes are zero
        assertEq(upperBytes, 0, "Upper 7 bytes should be zero");

        // Verify round-trip still works correctly
        AllowedTargets memory decoded_ = AsyncActionFuseLib.decodeAllowedTargets(encoded_);
        assertEq(decoded_.target, input_.target, "target should match after round-trip");
        assertEq(uint32(decoded_.selector), uint32(input_.selector), "selector should match after round-trip");
    }

    function test_encodeAllowedSlippageRoundTrip() public {
        AllowedSlippage memory input_ = AllowedSlippage({slippage: 123456789});

        bytes31 encoded_ = AsyncActionFuseLib.encodeAllowedSlippage(input_);
        AllowedSlippage memory decoded_ = AsyncActionFuseLib.decodeAllowedSlippage(encoded_);

        assertEq(decoded_.slippage, input_.slippage, "slippage");
    }

    function test_encodeAllowedSlippageRevertsOnOverflow() public {
        AllowedSlippage memory input_ = AllowedSlippage({slippage: uint256(type(uint248).max) + 1});

        vm.expectRevert(abi.encodeWithSelector(AsyncActionFuseLib.AllowedSlippageTooLarge.selector, input_.slippage));
        this.callEncodeAllowedSlippage(input_);
    }

    function test_encodeAsyncActionFuseSubstrateRoundTrip() public {
        AllowedTargets memory targets_ = AllowedTargets({
            target: address(0x1111),
            selector: bytes4(keccak256("execute()"))
        });

        AsyncActionFuseSubstrate memory input_ = AsyncActionFuseSubstrate({
            substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
            data: AsyncActionFuseLib.encodeAllowedTargets(targets_)
        });

        bytes32 encoded_ = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(input_);
        AsyncActionFuseSubstrate memory decoded_ = AsyncActionFuseLib.decodeAsyncActionFuseSubstrate(encoded_);

        assertEq(uint8(decoded_.substrateType), uint8(input_.substrateType), "substrate type");
        AllowedTargets memory decodedTargets_ = AsyncActionFuseLib.decodeAllowedTargets(decoded_.data);
        assertEq(decodedTargets_.target, targets_.target, "target");
        assertEq(uint32(decodedTargets_.selector), uint32(targets_.selector), "selector");
    }

    function test_decodeAsyncActionFuseSubstratesEmpty() public {
        bytes32[] memory inputs_ = new bytes32[](0);

        (
            AllowedAmountToOutside[] memory amounts_,
            AllowedTargets[] memory targets_,
            AllowedSlippage memory slippage_
        ) = AsyncActionFuseLib.decodeAsyncActionFuseSubstrates(inputs_);

        assertEq(amounts_.length, 0);
        assertEq(targets_.length, 0);
        assertEq(slippage_.slippage, 0);
    }

    function test_decodeAsyncActionFuseSubstratesSingleType() public {
        AllowedAmountToOutside memory amount1_ = AllowedAmountToOutside({asset: address(0xAAA1), amount: 1});
        AllowedAmountToOutside memory amount2_ = AllowedAmountToOutside({asset: address(0xAAA2), amount: 2});

        bytes32[] memory inputs_ = new bytes32[](2);
        inputs_[0] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
                data: AsyncActionFuseLib.encodeAllowedAmountToOutside(amount1_)
            })
        );
        inputs_[1] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
                data: AsyncActionFuseLib.encodeAllowedAmountToOutside(amount2_)
            })
        );

        (
            AllowedAmountToOutside[] memory amounts_,
            AllowedTargets[] memory targets_,
            AllowedSlippage memory slippage_
        ) = AsyncActionFuseLib.decodeAsyncActionFuseSubstrates(inputs_);

        assertEq(amounts_.length, 2, "amount length");
        assertEq(targets_.length, 0, "targets length");
        assertEq(slippage_.slippage, 0, "slippage should be zero when not present");
        assertEq(amounts_[0].asset, amount1_.asset, "a1 asset");
        assertEq(amounts_[0].amount, amount1_.amount, "a1 amount");
        assertEq(amounts_[1].asset, amount2_.asset, "a2 asset");
        assertEq(amounts_[1].amount, amount2_.amount, "a2 amount");
    }

    function test_decodeAsyncActionFuseSubstratesMixed() public {
        AllowedAmountToOutside memory amount_ = AllowedAmountToOutside({asset: address(0xBEEF), amount: 42});
        AllowedTargets memory targets_ = AllowedTargets({
            target: address(0xC0FFEE),
            selector: bytes4(keccak256("swap(address,uint256)"))
        });
        AllowedSlippage memory slippage_ = AllowedSlippage({slippage: 5_000});

        bytes32[] memory inputs_ = new bytes32[](3);
        inputs_[0] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(targets_)
            })
        );
        inputs_[1] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
                data: AsyncActionFuseLib.encodeAllowedAmountToOutside(amount_)
            })
        );
        inputs_[2] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_EXIT_SLIPPAGE,
                data: AsyncActionFuseLib.encodeAllowedSlippage(slippage_)
            })
        );

        (
            AllowedAmountToOutside[] memory amounts_,
            AllowedTargets[] memory targetsArray_,
            AllowedSlippage memory decodedSlippage_
        ) = AsyncActionFuseLib.decodeAsyncActionFuseSubstrates(inputs_);

        assertEq(amounts_.length, 1, "amount length");
        assertEq(targetsArray_.length, 1, "targets length");

        assertEq(amounts_[0].asset, amount_.asset, "amount asset");
        assertEq(amounts_[0].amount, amount_.amount, "amount");

        assertEq(targetsArray_[0].target, targets_.target, "target address");
        assertEq(uint32(targetsArray_[0].selector), uint32(targets_.selector), "target selector");

        assertEq(decodedSlippage_.slippage, slippage_.slippage, "slippage");
    }

    function test_decodeAsyncActionFuseSubstratesIgnoresUnknownTypes() public {
        bytes32[] memory inputs_ = new bytes32[](1);

        bytes31 dummyData_ = bytes31(uint248(123));
        uint256 packed_ = (uint256(uint8(42)) << 248) | uint256(uint248(dummyData_));
        inputs_[0] = bytes32(packed_);

        (
            AllowedAmountToOutside[] memory amounts_,
            AllowedTargets[] memory targets_,
            AllowedSlippage memory slippage_
        ) = AsyncActionFuseLib.decodeAsyncActionFuseSubstrates(inputs_);

        assertEq(amounts_.length, 0);
        assertEq(targets_.length, 0);
        assertEq(slippage_.slippage, 0, "slippage should be zero for unknown types");
    }

    function callEncodeAllowedAmountToOutside(AllowedAmountToOutside memory input_) external pure {
        AsyncActionFuseLib.encodeAllowedAmountToOutside(input_);
    }

    function callEncodeAllowedSlippage(AllowedSlippage memory input_) external pure {
        AsyncActionFuseLib.encodeAllowedSlippage(input_);
    }
}
