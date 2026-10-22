// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

/// @title ProductionTimelockConstantsTest
/// @notice Release gate for the reviewed governance and rescue timelocks (IL-8444). Test deployments shorten
///         these constants to minutes in a local working tree; this suite fails if such values are ever
///         committed, so CI blocks a merge that would ship them in production bytecode. IL-8538 adds the
///         factory configuration-delay floor.
contract ProductionTimelockConstantsTest is Test {
    function testShouldKeepCcipFactoryConfigDelayAt24Hours() public {
        CcipCrosschainFactory factory = new CcipCrosschainFactory(address(new MockCcipRouter()), address(this));
        assertEq(factory.CONFIG_DELAY(), 24 hours, "CcipCrosschainFactory.CONFIG_DELAY");
    }

    function testShouldKeepMinRescueDelayAt24Hours() public pure {
        assertEq(CrosschainConstants.MIN_RESCUE_DELAY, 24 hours, "CrosschainConstants.MIN_RESCUE_DELAY");
    }

    function testShouldKeepFrontierRepairDelayAt6Hours() public pure {
        assertEq(CrosschainConstants.FRONTIER_REPAIR_DELAY, 6 hours, "CrosschainConstants.FRONTIER_REPAIR_DELAY");
    }

    function testShouldKeepMinConfigDelayAt24Hours() public pure {
        assertEq(CrosschainConstants.MIN_CONFIG_DELAY, 24 hours, "CrosschainConstants.MIN_CONFIG_DELAY");
    }

    /// @dev Destination clocks may lag the source by up to a day (Arbitrum SequencerInbox delaySeconds = 86 400),
    ///      so a shorter margin lets ABANDON free a slot while the command is still executable (IL-8591).
    function testShouldKeepCommandExpiryMarginAtLeastOneDay() public pure {
        assertGe(CrosschainConstants.COMMAND_EXPIRY_MARGIN, 24 hours, "CrosschainConstants.COMMAND_EXPIRY_MARGIN");
    }
}
