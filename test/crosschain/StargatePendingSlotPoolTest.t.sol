// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MAX_PENDING_TRANSFERS_PER_CHAIN_SLOTS} from "../../contracts/crosschain/stargate/lib/StargateExecutorState.sol";

/// @title StargatePendingSlotPoolTest
/// @notice Pins the fixed-size staleness slot pool of the Stargate executor to the per-chain concurrent-record cap.
/// @dev The pool length is a file-level literal because a fixed array length must be a compile-time constant, so it
///      cannot be derived from `CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN`. The executor constructor also
///      checks the pair at runtime, but with a constant-false branch that reverts a misleading `ZeroAddress`; this
///      test is the intended drift guard (IL-9075).
contract StargatePendingSlotPoolTest is Test {
    function testShouldKeepTheSlotPoolSizeEqualToThePerChainCap() public pure {
        assertEq(
            MAX_PENDING_TRANSFERS_PER_CHAIN_SLOTS,
            CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN,
            "slot pool size must equal the per-chain pending transfer cap"
        );
    }
}
