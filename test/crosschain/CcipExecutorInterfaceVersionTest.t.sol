// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICrosschainExecutorMetadata} from "../../contracts/crosschain/common/ICrosschainExecutorMetadata.sol";
import {CcipMessages} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";

/// @title CcipExecutorInterfaceVersionTest
/// @notice Pins `CcipCrosschainExecutor.executorInterfaceVersion()` for the release that adds the `anchorBandBps`
///         constructor field and `attestationAnchorBandBps()` (IL-9720; 8 was the release with
///         `updateVaultsWithSweepFloors` and the CCIP message / codec bump, IL-9629): tooling tells executor
///         surfaces apart by this value, so it has to move with the interface and the wire versions.
contract CcipExecutorInterfaceVersionTest is CcipExecutorFixture {
    function setUp() public {
        _fixtureSetUp();
    }

    function testShouldReportInterfaceVersionNine() public view {
        assertEq(executor.executorInterfaceVersion(), 9, "executor interface revision of this release");
        assertEq(
            ICrosschainExecutorMetadata(address(executor)).executorInterfaceVersion(),
            9,
            "same value through the metadata interface"
        );
    }

    function testShouldPinTheWireVersionsThatTheInterfaceRevisionAccompanies() public pure {
        assertEq(uint256(CcipMessages.VERSION), 4, "CCIP message version");
        assertEq(uint256(CrosschainConstants.CODEC_VERSION), 5, "codec version");
    }
}
