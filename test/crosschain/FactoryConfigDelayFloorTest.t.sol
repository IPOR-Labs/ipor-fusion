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
/// @dev Requires the oversized real factory. Under the mandated `--code-size-limit 60000` the deploy probe
///      cannot tell a size-limit failure from the floor revert, so the suite skips there (see
///      `FactoryTestBase`); run at `--code-size-limit 200000` for full coverage.
contract FactoryConfigDelayFloorTest is FactoryTestBase {
    function setUp() public {
        vm.chainId(LOCAL_CHAIN);
        endpoint = new MockLzEndpoint();
        // Probe: a floor-compliant deployment must succeed when the size limit allows the factory.
        try this.deployFactoryExt(CrosschainConstants.MIN_CONFIG_DELAY) returns (address f) {
            factory = ICrosschainFactory(f);
            factoryReady = true;
        } catch {
            factoryReady = false;
        }
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
