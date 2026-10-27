// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {ICrosschainFactory} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title FactoryConfigDelayFloorTest
/// @notice IL-8538: the Stargate factory constructor floors `configDelay_` at `MIN_CONFIG_DELAY`, so a
///         deployment with a short (or zero) configuration timelock is rejected instead of silently
///         shipping a factory whose asset/path configuration can be changed almost instantly.
/// @dev Requires the real factory; a failed deploy in `setUp` makes the suite red (no try/catch, no skip).
contract FactoryConfigDelayFloorTest is FactoryTestBase {
    function setUp() public {
        vm.chainId(LOCAL_CHAIN);
        endpoint = new MockLzEndpoint();
        // A floor-compliant deployment must succeed; a failure here reverts setUp.
        factory = ICrosschainFactory(this.deployFactoryExt(CrosschainConstants.MIN_CONFIG_DELAY));
        factoryReady = true;
    }

    function testShouldRejectConfigDelayOneSecondBelowFloor() public requiresFactory {
        uint256 minimum = CrosschainConstants.MIN_CONFIG_DELAY;
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidConfigDelay.selector, minimum - 1, minimum));
        this.deployFactoryExt(minimum - 1);
    }

    function testShouldRejectFiveMinuteConfigDelay() public requiresFactory {
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidConfigDelay.selector,
                uint256(5 minutes),
                CrosschainConstants.MIN_CONFIG_DELAY
            )
        );
        this.deployFactoryExt(5 minutes);
    }

    function testShouldRejectZeroConfigDelay() public requiresFactory {
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidConfigDelay.selector,
                uint256(0),
                CrosschainConstants.MIN_CONFIG_DELAY
            )
        );
        this.deployFactoryExt(0);
    }

    function testShouldDeployWithConfigDelayAtFloor() public requiresFactory {
        address deployed = this.deployFactoryExt(CrosschainConstants.MIN_CONFIG_DELAY);
        assertEq(StargateCrosschainFactory(payable(deployed)).CONFIG_DELAY(), 24 hours, "CONFIG_DELAY at the floor");
    }
}
