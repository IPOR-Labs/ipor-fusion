// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipForkBase, CcipForkMessage} from "./CcipForkBase.sol";

/// @title CcipForkRoundTripTest
/// @notice IL-8458 / Codex O-14: the full CCIP executor <-> dispatcher lifecycle across two pinned mainnet forks,
///         Ethereum and Arbitrum, over the real Router 1.2.0 and the live CCIP 2.0 OnRamp / OffRamp. Every
///         data-only message is executed by the destination's real `OffRamp.execute` (CCV signatures mocked, see
///         `CcipForkBase`); token messages go through the real `Router.routeMessage` after the tokens are dealt.
contract CcipForkRoundTripTest is CcipForkBase {
    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 1, ARBITRUM_FORK_BLOCK + 1);
    }

    function setUp() public {
        _deployStack();
    }

    function _deliver(CcipForkMessage memory m_, address destRouter_, string memory label_) internal override {
        if (m_.tokenAmount != 0) {
            (bool success, bytes memory ret,) = _routeViaRouter(m_, destRouter_, m_.ccipReceiveGasLimit);
            if (!success) {
                emit log_named_bytes(label_, ret);
                fail();
            }
            return;
        }
        uint8 state = _executeOnOffRamp(m_, destRouter_, 0);
        assertEq(state, 2, string.concat(label_, ": OffRamp execution state SUCCESS"));
    }

    function testShouldRunTheFullLifecycleOverTheRealCcipTransport() public {
        _runLifecycle();
    }
}
