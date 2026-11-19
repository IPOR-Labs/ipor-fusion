// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {FactoryTestBase} from "./FactoryTestBase.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";

/// @title CcipFactoryCreateExecutorMigrationGateTest
/// @notice IL-9641: `createExecutor` honours the same asset-migration gate as the ticket path (IL-8623).
contract CcipFactoryCreateExecutorMigrationGateTest is Test {
    bytes32 internal constant ASSET_ID = keccak256("USDC");

    CcipCrosschainFactory internal factory;
    MockERC20 internal token;
    MockERC20 internal newToken;

    function setUp() public {
        MockCcipRouter router = new MockCcipRouter();
        token = new MockERC20("USD Coin", "USDC", 6);
        newToken = new MockERC20("USD Coin 2", "USDC2", 6);
        factory = new CcipCrosschainFactory(address(router), address(this));
        factory.scheduleAsset(ASSET_ID, address(token), 6);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeAsset(ASSET_ID, address(token), 6);
        factory.configureCreationCodes(
            type(CcipCrosschainExecutor).creationCode,
            type(CcipCrosschainDispatcher).creationCode
        );
    }

    function testShouldRevertCreateExecutorWhileAssetMigrationScheduled() public {
        factory.scheduleAsset(ASSET_ID, address(newToken), 6);

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DestinationAssetMigrationScheduled.selector, ASSET_ID));
        factory.createExecutor(keccak256("a"), ASSET_ID, address(0xBEEF), _safety());
        assertFalse(factory.assetFrozen(ASSET_ID), "asset must stay mutable");
    }

    function testShouldCreateExecutorAfterMigrationExecuted() public {
        factory.scheduleAsset(ASSET_ID, address(newToken), 6);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeAsset(ASSET_ID, address(newToken), 6);

        address executor = factory.createExecutor(keccak256("a"), ASSET_ID, address(0xBEEF), _safety());
        assertTrue(factory.isExecutor(executor));
        assertTrue(factory.assetFrozen(ASSET_ID));
    }

    function testShouldCreateExecutorAfterMigrationCancelled() public {
        factory.scheduleAsset(ASSET_ID, address(newToken), 6);
        factory.cancelScheduledConfig(keccak256(abi.encode("ASSET", ASSET_ID, address(newToken), uint8(6))));

        address executor = factory.createExecutor(keccak256("a"), ASSET_ID, address(0xBEEF), _safety());
        assertTrue(factory.isExecutor(executor));
    }

    function testShouldNotGateFrozenAssetExecutorCreation() public {
        factory.createExecutor(keccak256("a"), ASSET_ID, address(0xBEEF), _safety());
        assertTrue(factory.assetFrozen(ASSET_ID));
        // A frozen asset cannot be migrated: scheduling is refused, and later creation is not blocked.
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.AssetConfigFrozen.selector, ASSET_ID));
        factory.scheduleAsset(ASSET_ID, address(newToken), 6);
        address second = factory.createExecutor(keccak256("b"), ASSET_ID, address(0xBEEF), _safety());
        assertTrue(factory.isExecutor(second));
    }

    function _safety() private pure returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                anchorBandBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }
}

/// @title StargateFactoryCreateExecutorMigrationGateTest
/// @notice IL-9641: `createExecutor` honours the same asset-migration gate as the ticket path (IL-8623).
contract StargateFactoryCreateExecutorMigrationGateTest is FactoryTestBase {
    function sf() internal view returns (StargateCrosschainFactory) {
        return StargateCrosschainFactory(payable(address(factory)));
    }

    function setUp() public {
        _factorySetUp(CrosschainConstants.MIN_CONFIG_DELAY);
        _enableUsdc();
    }

    function testShouldRevertCreateExecutorWhileAssetMigrationScheduled() public requiresFactory {
        factory.scheduleAssetConfig(ASSET_ID, address(usdc), address(pool));

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DestinationAssetMigrationScheduled.selector, ASSET_ID));
        factory.createExecutor(keccak256("a"), _params(address(this)));
        assertFalse(sf().assetFrozen(ASSET_ID), "asset must stay mutable");
    }

    function testShouldCreateExecutorAfterMigrationExecuted() public requiresFactory {
        factory.scheduleAssetConfig(ASSET_ID, address(usdc), address(pool));
        _warpConfigDelay();
        factory.executeAssetConfig(ASSET_ID);

        address executor = factory.createExecutor(keccak256("a"), _params(address(this)));
        assertTrue(sf().isExecutor(executor));
        assertTrue(sf().assetFrozen(ASSET_ID));
    }

    function testShouldNotGateFrozenAssetExecutorCreation() public requiresFactory {
        factory.createExecutor(keccak256("a"), _params(address(this)));
        assertTrue(sf().assetFrozen(ASSET_ID));
        address second = factory.createExecutor(keccak256("b"), _params(address(this)));
        assertTrue(sf().isExecutor(second));
    }
}
