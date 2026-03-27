// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {CollateralTokenOnMorphoMarketPriceFeedFactory} from "../../../../contracts/factory/price_feed/CollateralTokenOnMorphoMarketPriceFeedFactory.sol";

import {CollateralTokenOnMorphoMarketPriceFeedFactory} from "contracts/factory/price_feed/CollateralTokenOnMorphoMarketPriceFeedFactory.sol";
import {CollateralTokenOnMorphoMarketPriceFeed} from "contracts/price_oracle/price_feed/CollateralTokenOnMorphoMarketPriceFeed.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
contract CollateralTokenOnMorphoMarketPriceFeedFactoryTest is OlympixUnitTest("CollateralTokenOnMorphoMarketPriceFeedFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_createPriceFeed_RevertWhenMorphoOracleZero() public {
            CollateralTokenOnMorphoMarketPriceFeedFactory factory = new CollateralTokenOnMorphoMarketPriceFeedFactory();
    
            // Factory is already initialized in proxy context in Olympix setup,
            // calling initialize here causes InvalidInitialization revert.
            // We only need to test the ZeroAddress branch in createPriceFeed.
    
            vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.ZeroAddress.selector);
            factory.createPriceFeed(address(0), address(1), address(2), address(3));
        }

    function test_createPriceFeed_RevertWhenCollateralTokenZero_opixBranch56True() public {
            CollateralTokenOnMorphoMarketPriceFeedFactory factory = new CollateralTokenOnMorphoMarketPriceFeedFactory();
    
            // Factory is already initialized in proxy context in Olympix setup,
            // so calling initialize here would revert with InvalidInitialization.
            // We just need to hit the ZeroAddress branch for collateralToken_.
    
            vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.ZeroAddress.selector);
            factory.createPriceFeed(address(1), address(0), address(2), address(3));
        }

    function test_createPriceFeed_RevertWhenLoanTokenZero_opixBranch57True() public {
            CollateralTokenOnMorphoMarketPriceFeedFactory factory = new CollateralTokenOnMorphoMarketPriceFeedFactory();
    
            vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.ZeroAddress.selector);
            factory.createPriceFeed(address(1), address(2), address(0), address(3));
        }

    function test_createPriceFeed_RevertWhenPriceOracleMiddlewareZero_opixBranch58True() public {
            CollateralTokenOnMorphoMarketPriceFeedFactory factory = new CollateralTokenOnMorphoMarketPriceFeedFactory();
    
            vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.ZeroAddress.selector);
            factory.createPriceFeed(address(1), address(2), address(3), address(0));
        }

    function test_getPriceFeedAddress_ReturnsCreatedFeed_opixBranch93True() public {
            // Arrange: deploy factory and supporting mock contracts
            CollateralTokenOnMorphoMarketPriceFeedFactory factory = new CollateralTokenOnMorphoMarketPriceFeedFactory();
    
            address morphoOracle = address(0x1001);
            MockERC20 collateralToken = new MockERC20("Collateral", "COL", 18);
            MockERC20 loanToken = new MockERC20("Loan", "LOAN", 18);
            MockPriceOracle priceOracleMiddleware = new MockPriceOracle();
    
            // Act: create a new price feed
            address created = factory.createPriceFeed(
                morphoOracle,
                address(collateralToken),
                address(loanToken),
                address(priceOracleMiddleware)
            );
    
            // Assert: getPriceFeedAddress returns the same address, exercising opix-target-branch-93-True
            address fetched = factory.getPriceFeedAddress(
                address(this),
                morphoOracle,
                address(collateralToken),
                address(loanToken),
                address(priceOracleMiddleware)
            );
    
            assertEq(fetched, created, "getPriceFeedAddress should return created price feed");
    
            // Additional sanity check that the created address is a valid price feed contract
            CollateralTokenOnMorphoMarketPriceFeed feed = CollateralTokenOnMorphoMarketPriceFeed(fetched);
            // Configure mocks so latestRoundData does not revert
            priceOracleMiddleware.setAssetPrice(address(loanToken), 1e8);
            // Note: morphoOracle is just a dummy address without code, so calling price() would revert.
            // We only ensure that the factory wiring works and the returned address is non-zero and typed.
            assertEq(address(feed.fusionPriceManager()), address(priceOracleMiddleware), "fusionPriceManager mismatch");
        }

    function test_createPriceFeed_RevertWhenPriceFeedAlreadyExists_opixBranch106True() public {
            CollateralTokenOnMorphoMarketPriceFeedFactory factory = new CollateralTokenOnMorphoMarketPriceFeedFactory();

            address morphoOracle = address(0x1001);
            MockERC20 collateralToken = new MockERC20("Collateral", "COL", 18);
            MockERC20 loanToken = new MockERC20("Loan", "LOAN", 18);
            MockPriceOracle priceOracleMiddleware = new MockPriceOracle();

            // First creation should succeed and store the price feed
            address first = factory.createPriceFeed(morphoOracle, address(collateralToken), address(loanToken), address(priceOracleMiddleware));
            assertTrue(first != address(0));

            // Second creation with same params and msg.sender should revert with PriceFeedAlreadyExists
            vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.PriceFeedAlreadyExists.selector);
            factory.createPriceFeed(morphoOracle, address(collateralToken), address(loanToken), address(priceOracleMiddleware));

            // Also verify that getPriceFeed (branch guarded by `if (true)`) returns the stored address
            address stored = factory.getPriceFeed(
                address(this),
                morphoOracle,
                address(collateralToken),
                address(loanToken),
                address(priceOracleMiddleware)
            );
            assertEq(stored, first);
        }

    function test_generateKey_opixBranch119True() public {
            CollateralTokenOnMorphoMarketPriceFeedFactory factory = new CollateralTokenOnMorphoMarketPriceFeedFactory();
    
            address creator = address(0x1);
            address morphoOracle = address(0x2);
            address collateralToken = address(0x3);
            address loanToken = address(0x4);
            address fusionPriceMiddleware = address(0x5);
    
            bytes32 expected = keccak256(
                abi.encode(creator, morphoOracle, collateralToken, loanToken, fusionPriceMiddleware)
            );
    
            bytes32 actual = factory.generateKey(
                creator,
                morphoOracle,
                collateralToken,
                loanToken,
                fusionPriceMiddleware
            );
    
            assertEq(actual, expected, "generateKey should hash all parameters as expected");
        }
}