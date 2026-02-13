// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PtPriceFeedFactory} from "../../../contracts/factory/price_feed/PtPriceFeedFactory.sol";
import {PtPriceFeed} from "../../../contracts/price_oracle/price_feed/PtPriceFeed.sol";

/// @title PtPriceFeed Chainlink Metadata Tests
/// @notice Tests for IL-6765: Verify latestRoundData returns Chainlink-compatible metadata
contract PtPriceFeedMetadataTest is Test {
    // Constants from existing tests
    address private constant PRICE_ORACLE = 0xC9F32d65a278b012371858fD3cdE315B12d664c6;
    uint256 private constant BLOCK_NUMBER = 22373579;
    address private constant PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;

    // Test market (PT-sUSDe from existing tests)
    address private constant TEST_MARKET = 0xB162B764044697cf03617C2EFbcB1f42e31E4766;

    // Test configuration
    uint32 private constant TWAP_WINDOW = 300; // 5 minutes
    address private constant ADMIN = address(0x1234);

    PtPriceFeedFactory private factoryProxy;
    PtPriceFeed private priceFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), BLOCK_NUMBER);

        // Deploy factory
        PtPriceFeedFactory factory = new PtPriceFeedFactory();
        factoryProxy = PtPriceFeedFactory(
            address(new ERC1967Proxy(address(factory), abi.encodeWithSignature("initialize(address)", ADMIN)))
        );

        // Calculate price at this block
        int256 calculatedPrice = factoryProxy.calculatePrice(TEST_MARKET, TWAP_WINDOW, PRICE_ORACLE, 0);

        // Create price feed
        vm.prank(ADMIN);
        address priceFeedAddress = factoryProxy.create(
            PENDLE_ORACLE,
            TEST_MARKET,
            TWAP_WINDOW,
            PRICE_ORACLE,
            0, // usePendleOracleMethod
            calculatedPrice
        );

        priceFeed = PtPriceFeed(priceFeedAddress);
    }

    // ============ Unit Tests for Chainlink Metadata ============

    /// @notice Verify roundId is not zero
    function testShouldReturnNonZeroRoundId() public view {
        // when
        (uint80 roundId, , , , ) = priceFeed.latestRoundData();

        // then
        assertTrue(roundId > 0, "roundId should not be zero");
    }

    /// @notice Verify startedAt is not zero
    function testShouldReturnNonZeroStartedAt() public view {
        // when
        (, , uint256 startedAt, , ) = priceFeed.latestRoundData();

        // then
        assertTrue(startedAt > 0, "startedAt should not be zero");
    }

    /// @notice Verify answeredInRound is not zero
    function testShouldReturnNonZeroAnsweredInRound() public view {
        // when
        (, , , , uint80 answeredInRound) = priceFeed.latestRoundData();

        // then
        assertTrue(answeredInRound > 0, "answeredInRound should not be zero");
    }

    /// @notice Verify answeredInRound equals roundId
    function testShouldReturnAnsweredInRoundEqualToRoundId() public view {
        // when
        (uint80 roundId, , , , uint80 answeredInRound) = priceFeed.latestRoundData();

        // then
        assertEq(answeredInRound, roundId, "answeredInRound should equal roundId");
    }

    /// @notice Verify startedAt is less than time
    function testShouldReturnStartedAtLessThanTime() public view {
        // when
        (, , uint256 startedAt, uint256 time, ) = priceFeed.latestRoundData();

        // then
        assertTrue(startedAt < time, "startedAt should be less than time");
    }

    /// @notice Verify startedAt equals time minus TWAP_WINDOW
    function testShouldReturnStartedAtEqualToTimeMinusTwapWindow() public view {
        // when
        (, , uint256 startedAt, uint256 time, ) = priceFeed.latestRoundData();

        // then
        assertEq(startedAt, time - TWAP_WINDOW, "startedAt should equal time - TWAP_WINDOW");
    }

    /// @notice Verify roundId is derived from block.number
    function testShouldReturnRoundIdDerivedFromBlockNumber() public view {
        // when
        (uint80 roundId, , , , ) = priceFeed.latestRoundData();

        // then
        assertEq(roundId, uint80(block.number), "roundId should equal uint80(block.number)");
    }

    /// @notice Verify standard Chainlink consumer check: require(startedAt > 0)
    function testShouldPassChainlinkStartedAtCheck() public view {
        // when
        (, , uint256 startedAt, , ) = priceFeed.latestRoundData();

        // then - simulate consumer check
        require(startedAt > 0, "Stale price");
        // If we reach here, check passed
    }

    /// @notice Verify standard Chainlink consumer check: require(answeredInRound >= roundId)
    function testShouldPassChainlinkAnsweredInRoundCheck() public view {
        // when
        (uint80 roundId, , , , uint80 answeredInRound) = priceFeed.latestRoundData();

        // then - simulate consumer check
        require(answeredInRound >= roundId, "Stale price");
        // If we reach here, check passed
    }

    /// @notice Verify repeated calls within same block return consistent metadata
    function testShouldReturnConsistentMetadataWithinSameBlock() public view {
        // when - first call
        (uint80 roundId1, int256 price1, uint256 startedAt1, uint256 time1, uint80 answeredInRound1) = priceFeed
            .latestRoundData();

        // when - second call
        (uint80 roundId2, int256 price2, uint256 startedAt2, uint256 time2, uint80 answeredInRound2) = priceFeed
            .latestRoundData();

        // then
        assertEq(roundId1, roundId2, "roundId should be consistent within same block");
        assertEq(price1, price2, "price should be consistent within same block");
        assertEq(startedAt1, startedAt2, "startedAt should be consistent within same block");
        assertEq(time1, time2, "time should be consistent within same block");
        assertEq(answeredInRound1, answeredInRound2, "answeredInRound should be consistent within same block");
    }

    /// @notice Verify roundId increases across blocks
    function testShouldReturnIncreasingRoundIdAcrossBlocks() public {
        // given - first call
        (uint80 roundId1, , , , ) = priceFeed.latestRoundData();

        // when - advance blocks
        vm.roll(block.number + 10);

        // then
        (uint80 roundId2, , , , ) = priceFeed.latestRoundData();
        assertTrue(roundId2 > roundId1, "roundId should increase with block.number");
        assertEq(roundId2, roundId1 + 10, "roundId should increase by the number of blocks advanced");
    }

    // ============ Fork Integration Tests ============

    /// @notice Test metadata fields on forked Ethereum
    function testShouldReturnValidMetadataOnMainnetFork() public view {
        // when
        (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = priceFeed
            .latestRoundData();

        // then - all metadata fields should be valid
        assertTrue(roundId > 0, "roundId should be positive on mainnet fork");
        assertTrue(price > 0, "price should be positive");
        assertTrue(startedAt > 0, "startedAt should be positive");
        assertTrue(time > 0, "time should be positive");
        assertTrue(answeredInRound > 0, "answeredInRound should be positive");

        // Verify relationships
        assertEq(answeredInRound, roundId, "answeredInRound should equal roundId");
        assertTrue(startedAt < time, "startedAt should be less than time");
    }

    /// @notice Verify standard consumer checks pass on mainnet fork
    function testShouldPassChainlinkConsumerChecksOnMainnetFork() public view {
        // when
        (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = priceFeed
            .latestRoundData();

        // then - all standard Chainlink consumer checks should pass
        require(roundId > 0, "Round not complete");
        require(price > 0, "Invalid price");
        require(startedAt > 0, "Stale price: startedAt");
        require(time > 0, "Stale price: updatedAt");
        require(answeredInRound >= roundId, "Stale price: answeredInRound");

        // Additional staleness check (price should be fresh)
        require(block.timestamp - time < 1 hours, "Price too old");
    }

    /// @notice Verify startedAt with real TWAP window
    function testShouldReturnCorrectStartedAtForRealTwapWindow() public view {
        // given
        uint32 expectedTwapWindow = priceFeed.TWAP_WINDOW();

        // when
        (, , uint256 startedAt, uint256 time, ) = priceFeed.latestRoundData();

        // then
        assertEq(time - startedAt, expectedTwapWindow, "Time difference should equal TWAP_WINDOW");
    }

    /// @notice Test metadata consistency across multiple blocks
    function testShouldReturnConsistentMetadataAcrossMultipleBlocks() public {
        // given
        uint256 startBlock = block.number;

        for (uint256 i = 0; i < 5; i++) {
            // when
            (uint80 roundId, , uint256 startedAt, uint256 time, uint80 answeredInRound) = priceFeed.latestRoundData();

            // then - verify metadata consistency
            assertEq(roundId, uint80(block.number), "roundId should match current block.number");
            assertEq(answeredInRound, roundId, "answeredInRound should equal roundId");
            assertEq(startedAt, time - TWAP_WINDOW, "startedAt should equal time - TWAP_WINDOW");
            assertEq(time, block.timestamp, "time should equal block.timestamp");

            // advance to next block
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12); // ~12 seconds per block
        }

        // verify we advanced blocks
        assertEq(block.number, startBlock + 5, "Should have advanced 5 blocks");
    }
}
