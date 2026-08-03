// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ChainlinkGuardedPriceFeedFactory} from "../../../contracts/factory/price_feed/ChainlinkGuardedPriceFeedFactory.sol";
import {ChainlinkGuardedPriceFeed} from "../../../contracts/price_oracle/price_feed/ChainlinkGuardedPriceFeed.sol";
import {AggregatorV3Interface} from "../../../contracts/price_oracle/ext/AggregatorV3Interface.sol";

contract ChainlinkGuardedPriceFeedFactoryTest is Test {
    ChainlinkGuardedPriceFeedFactory public factory;

    address public constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant CHAINLINK_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    uint32 public constant MAX_STALE = 1 days + 1 hours;
    uint256 public constant MAX_DEV = 5e16; // 5%
    uint256 public constant ROUNDS = 5;
    uint256 public constant MIN_ROUNDS = 1;
    address public constant ADMIN = address(0x1);
    address public constant CREATOR_1 = address(0x11);
    address public constant CREATOR_2 = address(0x22);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22773442);
        address implementation = address(new ChainlinkGuardedPriceFeedFactory());
        factory = ChainlinkGuardedPriceFeedFactory(
            address(new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", ADMIN)))
        );
    }

    function test_Initialize() public view {
        assertEq(factory.owner(), ADMIN, "Owner should be set correctly");
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        address implementation = address(new ChainlinkGuardedPriceFeedFactory());
        vm.expectRevert(ChainlinkGuardedPriceFeedFactory.InvalidAddress.selector);
        new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", address(0)));
    }

    function test_Initialize_CannotCallTwice() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        factory.initialize(ADMIN);
    }

    function test_CreatePriceFeed() public {
        address priceFeed = factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);

        assertTrue(priceFeed != address(0), "Price feed should be created");

        ChainlinkGuardedPriceFeed feed = ChainlinkGuardedPriceFeed(priceFeed);
        assertEq(feed.AGGREGATOR(), CHAINLINK_ETH_USD, "AGGREGATOR should be set correctly");
        assertEq(feed.MAX_STALE_PERIOD(), MAX_STALE, "MAX_STALE_PERIOD should be set correctly");
        assertEq(feed.MAX_DEVIATION(), MAX_DEV, "MAX_DEVIATION should be set correctly");
        assertEq(feed.ROUNDS_TO_CHECK(), ROUNDS, "ROUNDS_TO_CHECK should be set correctly");
        assertEq(feed.MIN_VALID_ROUNDS(), MIN_ROUNDS, "MIN_VALID_ROUNDS should be set correctly");
        assertEq(feed.PRICE_FEED_DECIMALS(), 8, "PRICE_FEED_DECIMALS should be cached from aggregator");
    }

    function test_CreatePriceFeed_EmitsEvent() public {
        vm.recordLogs();
        vm.prank(CREATOR_1);
        address priceFeed = factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        bytes32 expectedSig = keccak256(
            "ChainlinkGuardedPriceFeedCreated(address,address,uint32,uint256,uint256,uint256,address)"
        );
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == expectedSig && logs[i].emitter == address(factory)) {
                (
                    address emittedFeed,
                    address emittedAggregator,
                    uint32 emittedStale,
                    uint256 emittedDeviation,
                    uint256 emittedRounds,
                    uint256 emittedMinRounds,
                    address emittedCreator
                ) = abi.decode(logs[i].data, (address, address, uint32, uint256, uint256, uint256, address));
                assertEq(emittedFeed, priceFeed, "event priceFeed mismatch");
                assertEq(emittedAggregator, CHAINLINK_ETH_USD, "event aggregator mismatch");
                assertEq(emittedStale, MAX_STALE, "event stale period mismatch");
                assertEq(emittedDeviation, MAX_DEV, "event max deviation mismatch");
                assertEq(emittedRounds, ROUNDS, "event rounds mismatch");
                assertEq(emittedMinRounds, MIN_ROUNDS, "event min valid rounds mismatch");
                assertEq(emittedCreator, CREATOR_1, "event creator mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "ChainlinkGuardedPriceFeedCreated event not found");
    }

    function test_CreatePriceFeed_RevertsOnZeroAggregator() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.ZeroAddress.selector);
        factory.create(address(0), MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);
    }

    function test_CreatePriceFeed_RevertsOnZeroStalePeriod() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.ZeroStalePeriod.selector);
        factory.create(CHAINLINK_ETH_USD, 0, MAX_DEV, ROUNDS, MIN_ROUNDS);
    }

    function test_CreatePriceFeed_RevertsOnInvalidRounds() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidRoundsToCheck.selector);
        factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, 11, MIN_ROUNDS);
    }

    function test_CreatePriceFeed_RevertsOnZeroMinValidRounds() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidMinValidRounds.selector);
        factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, 0);
    }

    function test_CreatePriceFeed_RevertsWhenMinValidRoundsAboveRoundsToCheck() public {
        vm.expectRevert(ChainlinkGuardedPriceFeed.InvalidMinValidRounds.selector);
        factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, ROUNDS + 1);
    }

    function test_CreatePriceFeed_AcceptsMinValidRoundsEqualToRoundsToCheck() public {
        address priceFeed = factory.create(CHAINLINK_ETH_USD, MAX_STALE, 5e17, ROUNDS, ROUNDS);
        assertEq(
            ChainlinkGuardedPriceFeed(priceFeed).MIN_VALID_ROUNDS(),
            ROUNDS,
            "MIN_VALID_ROUNDS should accept the full window"
        );
    }

    function test_CreatePriceFeed_SanityCallReverts_WhenAggregatorStale() public {
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(ChainlinkGuardedPriceFeed.StalePrice.selector);
        factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);
    }

    function test_TracksPriceFeedsByCreator_MultipleCreates() public {
        vm.prank(CREATOR_1);
        address feed1 = factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);
        vm.prank(CREATOR_1);
        address feed2 = factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, 3, MIN_ROUNDS);
        vm.prank(CREATOR_2);
        address feed3 = factory.create(CHAINLINK_BTC_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);

        address[] memory creator1Feeds = factory.getPriceFeedsByCreator(CREATOR_1);
        assertEq(creator1Feeds.length, 2, "creator1 should have 2 feeds");
        assertEq(creator1Feeds[0], feed1, "creator1 feed order mismatch at 0");
        assertEq(creator1Feeds[1], feed2, "creator1 feed order mismatch at 1");
        assertEq(factory.getPriceFeedsByCreatorCount(CREATOR_1), 2, "creator1 count mismatch");

        address[] memory creator2Feeds = factory.getPriceFeedsByCreator(CREATOR_2);
        assertEq(creator2Feeds.length, 1, "creator2 should have 1 feed");
        assertEq(creator2Feeds[0], feed3, "creator2 feed mismatch");
        assertEq(factory.getPriceFeedsByCreatorCount(CREATOR_2), 1, "creator2 count mismatch");
    }

    function test_TracksPriceFeedsByAggregator() public {
        vm.prank(CREATOR_1);
        address feed1 = factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);
        vm.prank(CREATOR_2);
        address feed2 = factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, 3, MIN_ROUNDS);
        vm.prank(CREATOR_2);
        address feed3 = factory.create(CHAINLINK_BTC_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);

        address[] memory ethFeeds = factory.getPriceFeedsByAggregator(CHAINLINK_ETH_USD);
        assertEq(ethFeeds.length, 2, "ETH/USD aggregator should accumulate feeds across creators");
        assertEq(ethFeeds[0], feed1, "aggregator feed order mismatch at 0");
        assertEq(ethFeeds[1], feed2, "aggregator feed order mismatch at 1");
        assertEq(factory.getPriceFeedsByAggregatorCount(CHAINLINK_ETH_USD), 2, "ETH/USD count mismatch");

        address[] memory btcFeeds = factory.getPriceFeedsByAggregator(CHAINLINK_BTC_USD);
        assertEq(btcFeeds.length, 1, "BTC/USD aggregator should have 1 feed");
        assertEq(btcFeeds[0], feed3, "BTC/USD feed mismatch");
    }

    function test_GettersReturnEmptyForUnknownAddress() public view {
        assertEq(factory.getPriceFeedsByCreator(address(0xdead)).length, 0, "unknown creator should be empty");
        assertEq(factory.getPriceFeedsByAggregator(address(0xdead)).length, 0, "unknown aggregator should be empty");
        assertEq(factory.getPriceFeedsByCreatorCount(address(0xdead)), 0, "unknown creator count should be 0");
        assertEq(factory.getPriceFeedsByAggregatorCount(address(0xdead)), 0, "unknown aggregator count should be 0");
    }

    function test_Upgrade_NotOwner() public {
        address caller = address(0x2);
        address newImplementation = address(new ChainlinkGuardedPriceFeedFactory());

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        vm.prank(caller);
        factory.upgradeToAndCall(newImplementation, "");
    }

    function test_Upgrade_Owner() public {
        address newImplementation = address(new ChainlinkGuardedPriceFeedFactory());
        vm.prank(ADMIN);
        factory.upgradeToAndCall(newImplementation, "");

        assertEq(factory.owner(), ADMIN, "Owner should remain after upgrade");
        bytes32 storedImpl = vm.load(address(factory), ERC1967Utils.IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(storedImpl))), newImplementation, "ERC1967 impl slot mismatch");
    }

    function test_Upgrade_PreservesTracking() public {
        vm.prank(CREATOR_1);
        address feed1 = factory.create(CHAINLINK_ETH_USD, MAX_STALE, MAX_DEV, ROUNDS, MIN_ROUNDS);

        address newImplementation = address(new ChainlinkGuardedPriceFeedFactory());
        vm.prank(ADMIN);
        factory.upgradeToAndCall(newImplementation, "");

        address[] memory creatorFeeds = factory.getPriceFeedsByCreator(CREATOR_1);
        assertEq(creatorFeeds.length, 1, "creator tracking should survive upgrade");
        assertEq(creatorFeeds[0], feed1, "creator feed should survive upgrade");

        address[] memory aggregatorFeeds = factory.getPriceFeedsByAggregator(CHAINLINK_ETH_USD);
        assertEq(aggregatorFeeds.length, 1, "aggregator tracking should survive upgrade");
        assertEq(aggregatorFeeds[0], feed1, "aggregator feed should survive upgrade");
    }
}
