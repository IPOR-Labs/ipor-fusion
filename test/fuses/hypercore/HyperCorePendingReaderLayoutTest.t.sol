// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";

/// @notice IL-9529: wire layout of `HyperCorePendingReader.pendingState()`. Deliberately written against raw storage
///         slots and raw return words (no struct field names added by IL-9529), so the file also compiles on the
///         audited base, where the length test fails (23 words instead of 29).
/// @dev The reader is called directly, so it reads its own storage at the ERC-7201 pending slot. The
///      `PendingAction` slots used here: slot 9 = `lastOrderL1Block` (uint64 @ byte 0) + `effectRewardsManager`
///      (address @ byte 8) + `effectRewardsUpdateBalanceTimestamp` (uint32 @ byte 28), slot 10 =
///      `expectedRewardsRawSum`, slot 11 = `expectedRewardsVestedSum`, slot 12 = `effectRewardsTransferredTokens`
///      (uint128 @ byte 0) + `effectRewardsLastUpdateBalance` (uint128 @ byte 16).
contract HyperCorePendingReaderLayoutTest is Test {
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;
    address private constant L1_BLOCK_NUMBER_PRECOMPILE = address(0x809);

    HyperCorePendingReader private _reader;

    function setUp() public {
        vm.etch(L1_BLOCK_NUMBER_PRECOMPILE, "");
        _reader = new HyperCorePendingReader();
    }

    function testPendingStateReturnsTwentyNineWords() public view {
        bytes memory data = _rawPendingState();
        assertEq(data.length, 29 * 32, "24 PendingAction words + 5 scalars");
    }

    function testPendingStateWordPositions() public {
        address rewardsManager = makeAddr("rewardsManager");
        _storeSlot(9, bytes32((uint256(0xBEEF) << 224) | (uint256(uint160(rewardsManager)) << 64) | uint256(0xA11CE)));
        _storeSlot(10, bytes32(uint256(1111)));
        _storeSlot(11, bytes32(uint256(2222)));
        _storeSlot(12, bytes32((uint256(4444) << 128) | uint256(3333)));
        vm.warp(1_700_000_000);

        bytes memory data = _rawPendingState();
        assertEq(data.length, 29 * 32);

        assertEq(_word(data, 17), 0xA11CE, "word 17 = lastOrderL1Block");
        assertEq(_word(data, 18), uint256(uint160(rewardsManager)), "word 18 = effectRewardsManager");
        assertEq(_word(data, 19), 0xBEEF, "word 19 = effectRewardsUpdateBalanceTimestamp");
        assertEq(_word(data, 20), 1111, "word 20 = expectedRewardsRawSum");
        assertEq(_word(data, 21), 2222, "word 21 = expectedRewardsVestedSum");
        assertEq(_word(data, 22), 3333, "word 22 = effectRewardsTransferredTokens");
        assertEq(_word(data, 23), 4444, "word 23 = effectRewardsLastUpdateBalance");
        assertEq(_word(data, 24), 0, "word 24 = actionPending (no record)");
        assertEq(_word(data, 25), 1, "word 25 = actionSettled (no record)");
        assertEq(_word(data, 26), 0, "word 26 = currentL1Block (precompile absent)");
        assertEq(_word(data, 27), 1_700_000_000, "word 27 = currentTimestamp");
        assertEq(_word(data, 28), 0, "word 28 = l1BlockAvailable");
    }

    function _rawPendingState() private view returns (bytes memory data) {
        bool ok;
        (ok, data) = address(_reader).staticcall(abi.encodeWithSelector(HyperCorePendingReader.pendingState.selector));
        assertTrue(ok, "pendingState reverted");
    }

    function _storeSlot(uint256 offset_, bytes32 value_) private {
        vm.store(address(_reader), bytes32(uint256(PENDING_SLOT) + offset_), value_);
    }

    function _word(bytes memory data_, uint256 index_) private pure returns (uint256 word) {
        assembly {
            word := mload(add(add(data_, 0x20), mul(index_, 0x20)))
        }
    }
}
