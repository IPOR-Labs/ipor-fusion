// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";

/// @title CcipPendingTransferCapTest
/// @notice IL-9028: the CCIP executor holds at most 16 unresolved outbound transfers per chain; the 17th send reverts
///         `PendingTransferCapReached(chain, 16)`. The router does not auto-deliver, so no transfer settles.
contract CcipPendingTransferCapTest is CcipExecutorFixture {
    uint256 internal constant CAP = 16;

    function setUp() public {
        _fixtureSetUp();
        router.setAutoDeliver(false);
    }

    function testCapConstantIsSixteen() public pure {
        assertEq(CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN, CAP);
    }

    function testSeventeenthOutboundTransferRevertsAtCap() public {
        for (uint256 i; i < CAP; ++i) {
            assertEq(executor.pendingTransferCount(REMOTE_CHAIN), i);
            _bridge(1e18);
        }
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), CAP, "16 sends are accepted");

        token.mint(address(executor), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.PendingTransferCapReached.selector, REMOTE_CHAIN, CAP)
        );
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1e18, 0, address(0), 500_000);
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), CAP, "the rejected send opens no record");
    }
}
