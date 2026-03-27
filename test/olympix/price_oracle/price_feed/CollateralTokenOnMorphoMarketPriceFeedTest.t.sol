// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {CollateralTokenOnMorphoMarketPriceFeed} from "../../../../contracts/price_oracle/price_feed/CollateralTokenOnMorphoMarketPriceFeed.sol";

import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
import {IMorphoOracle} from "contracts/price_oracle/price_feed/ext/IMorphoOracle.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {CollateralTokenOnMorphoMarketPriceFeed} from "contracts/price_oracle/price_feed/CollateralTokenOnMorphoMarketPriceFeed.sol";
contract CollateralTokenOnMorphoMarketPriceFeedTest is OlympixUnitTest("CollateralTokenOnMorphoMarketPriceFeed") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_latestRoundData_RevertOnZeroMorphoPrice() public {
            // Deploy mock tokens with non-zero decimals
            MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
            MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
    
            // Deploy mock price oracle middleware and set valid loan token price
            MockPriceOracle priceOracle = new MockPriceOracle();
            priceOracle.setAssetPriceWithDecimals(address(loan), 1e8, 8);
    
            // Deploy a Morpho oracle stub via Foundry's mocked calls: price() will return 0
            address morphoOracle = address(0x1234);
            vm.mockCall(
                morphoOracle,
                abi.encodeWithSelector(IMorphoOracle.price.selector),
                abi.encode(uint256(0))
            );
    
            // Deploy the price feed under test
            CollateralTokenOnMorphoMarketPriceFeed feed = new CollateralTokenOnMorphoMarketPriceFeed(
                morphoOracle,
                address(collateral),
                address(loan),
                address(priceOracle)
            );
    
            // Expect revert due to zero price from Morpho oracle hitting opix-target-branch-101-True
            vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeed.InvalidMorphoOraclePrice.selector);
            feed.latestRoundData();
        }

    function test_latestRoundData_SuccessPath_MorphoPriceNonZero() public {
            // given: deploy collateral and loan tokens with standard 18 decimals
            MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
            MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
    
            // Morpho oracle address (stubbed via mockCall)
            address morphoOracle = address(0x1235);
    
            // Set Morpho oracle price to 1e36 (price() scaled by 1e36)
            uint256 collateralPriceInLoanToken = 1e36;
            vm.mockCall(
                morphoOracle,
                abi.encodeWithSelector(IMorphoOracle.price.selector),
                abi.encode(collateralPriceInLoanToken)
            );
    
            // Deploy mock price oracle middleware and set loan token price
            // Use 1e8 with 8 decimals to represent price = 1
            MockPriceOracle priceOracle = new MockPriceOracle();
            priceOracle.setAssetPriceWithDecimals(address(loan), 1e8, 8);
    
            // when: deploy the price feed and call latestRoundData
            CollateralTokenOnMorphoMarketPriceFeed feed = new CollateralTokenOnMorphoMarketPriceFeed(
                morphoOracle,
                address(collateral),
                address(loan),
                address(priceOracle)
            );
    
            // then: latestRoundData should succeed and return expected price
            (uint80 roundId, int256 price,, uint256 time, uint80 answeredInRound) = feed.latestRoundData();
    
            // Expected price: convertToWad( collateralPriceInLoanToken * loanTokenPriceUsd, precision )
            // collateralPriceInLoanToken = 1e36, loanTokenPriceUsd = 1e8
            // precision = 36 + 18 + 8 - 18 = 44
            // raw = 1e44, convertToWad(1e44, 44) = 1e18
            uint256 expected = IporMath.convertToWad(
                collateralPriceInLoanToken * 1e8,
                36 + 18 + 8 - 18
            );
    
            assertEq(roundId, 0, "roundId should be 0");
            assertEq(uint256(price), expected, "price should equal expected WAD value");
            assertEq(time, 0, "time should be 0");
            assertEq(answeredInRound, 0, "answeredInRound should be 0");
        }

    function test_latestRoundData_RevertOnInvalidPriceOracleMiddleware_zeroLoanPriceOrDecimals() public {
            // given: collateral & loan tokens with non‑zero decimals
            MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
            MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
    
            // Morpho oracle returning non‑zero price so we pass the first require
            address morphoOracle = address(0x9999);
            uint256 collateralPriceInLoanToken = 1e36;
            vm.mockCall(
                morphoOracle,
                abi.encodeWithSelector(IMorphoOracle.price.selector),
                abi.encode(collateralPriceInLoanToken)
            );
    
            // Case 1: loan token price is zero (loanTokenPriceInUsd == 0)
            MockPriceOracle priceOracleZeroPrice = new MockPriceOracle();
            priceOracleZeroPrice.setAssetPriceWithDecimals(address(loan), 0, 8);
    
            CollateralTokenOnMorphoMarketPriceFeed feedZeroPrice = new CollateralTokenOnMorphoMarketPriceFeed(
                morphoOracle,
                address(collateral),
                address(loan),
                address(priceOracleZeroPrice)
            );
    
            vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeed.InvalidPriceOracleMiddleware.selector);
            feedZeroPrice.latestRoundData();
    
            // Case 2: decimals returned as zero (loanTokenPriceInUsdDecimals == 0)
            // Use a fresh oracle and mock getAssetPrice to return non-zero price but zero decimals
            MockPriceOracle priceOracleZeroDecimals = new MockPriceOracle();
            priceOracleZeroDecimals.setAssetPriceWithDecimals(address(loan), 1e8, 0);
            // Override the mock's getAssetPrice to return decimals=0 (bypassing the default fallback)
            vm.mockCall(
                address(priceOracleZeroDecimals),
                abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, address(loan)),
                abi.encode(uint256(1e8), uint256(0))
            );

            CollateralTokenOnMorphoMarketPriceFeed feedZeroDecimals = new CollateralTokenOnMorphoMarketPriceFeed(
                morphoOracle,
                address(collateral),
                address(loan),
                address(priceOracleZeroDecimals)
            );

            vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeed.InvalidPriceOracleMiddleware.selector);
            feedZeroDecimals.latestRoundData();
        }

    function test_decimals_Returns18() public {
            // Deploy mock tokens with non-zero decimals so constructor does not revert
            MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
            MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
    
            // Deploy mock price oracle to satisfy fusionPriceManager argument
            MockPriceOracle priceOracle = new MockPriceOracle();
            priceOracle.setAssetPriceWithDecimals(address(loan), 1e8, 8);
    
            // Use a dummy morpho oracle address and mock its price() call so latestRoundData would work if called
            address morphoOracle = address(0x123456);
            vm.mockCall(
                morphoOracle,
                abi.encodeWithSelector(IMorphoOracle.price.selector),
                abi.encode(uint256(1e36))
            );
    
            // Construct the feed under test
            CollateralTokenOnMorphoMarketPriceFeed feed = new CollateralTokenOnMorphoMarketPriceFeed(
                morphoOracle,
                address(collateral),
                address(loan),
                address(priceOracle)
            );
    
            // when
            uint8 result = feed.decimals();
    
            // then: hit opix-target-branch-133-True and ensure 18 is returned
            assertEq(result, 18, "decimals should always return 18");
        }
}