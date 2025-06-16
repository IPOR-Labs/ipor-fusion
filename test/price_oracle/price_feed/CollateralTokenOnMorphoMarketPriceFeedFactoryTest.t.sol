// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CollateralTokenOnMorphoMarketPriceFeedFactory} from "../../../contracts/price_oracle/price_feed/CollateralTokenOnMorphoMarketPriceFeedFactory.sol";
import {CollateralTokenOnMorphoMarketPriceFeed} from "../../../contracts/price_oracle/price_feed/CollateralTokenOnMorphoMarketPriceFeed.sol";
import {IMorphoOracle} from "../../../contracts/price_oracle/price_feed/ext/IMorphoOracle.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract CollateralTokenOnMorphoMarketPriceFeedFactoryTest is Test {
    address constant MORPHO_ORACLE = 0x1376913337ceC523B4DDEAD8a60eDb1fA43fF1E3;
    address constant COLLATERAL_TOKEN = 0x3b3fB9C57858EF816833dC91565EFcd85D96f634;
    address constant LOAN_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FUSION_PRICE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;

    CollateralTokenOnMorphoMarketPriceFeedFactory public factory;
    IMorphoOracle public morphoOracle;
    IPriceOracleMiddleware public fusionPriceMiddleware;
    IERC20Metadata public collateralToken;
    IERC20Metadata public loanToken;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22715912);

        factory = new CollateralTokenOnMorphoMarketPriceFeedFactory();

        morphoOracle = IMorphoOracle(MORPHO_ORACLE);
        fusionPriceMiddleware = IPriceOracleMiddleware(FUSION_PRICE_MIDDLEWARE);
        collateralToken = IERC20Metadata(COLLATERAL_TOKEN);
        loanToken = IERC20Metadata(LOAN_TOKEN);
    }

    function testShouldCreatePriceFeed() public {
        address priceFeed = factory.createPriceFeed(
            MORPHO_ORACLE,
            COLLATERAL_TOKEN,
            LOAN_TOKEN,
            FUSION_PRICE_MIDDLEWARE
        );

        assertTrue(priceFeed != address(0));
        assertTrue(factory.isCreator(address(this)));
        assertEq(factory.creators(0), address(this));
        assertEq(factory.priceFeeds(0), priceFeed);

        CollateralTokenOnMorphoMarketPriceFeed feed = CollateralTokenOnMorphoMarketPriceFeed(priceFeed);
        assertEq(address(feed.morphoOracle()), MORPHO_ORACLE);
        assertEq(address(feed.collateralToken()), COLLATERAL_TOKEN);
        assertEq(address(feed.loanToken()), LOAN_TOKEN);
        assertEq(address(feed.fusionPriceMiddleware()), FUSION_PRICE_MIDDLEWARE);
    }

    function testShouldRevertWhenCreatingPriceFeedWithZeroAddress() public {
        vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.ZeroAddress.selector);
        factory.createPriceFeed(address(0), COLLATERAL_TOKEN, LOAN_TOKEN, FUSION_PRICE_MIDDLEWARE);

        vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.ZeroAddress.selector);
        factory.createPriceFeed(MORPHO_ORACLE, address(0), LOAN_TOKEN, FUSION_PRICE_MIDDLEWARE);

        vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.ZeroAddress.selector);
        factory.createPriceFeed(MORPHO_ORACLE, COLLATERAL_TOKEN, address(0), FUSION_PRICE_MIDDLEWARE);

        vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.ZeroAddress.selector);
        factory.createPriceFeed(MORPHO_ORACLE, COLLATERAL_TOKEN, LOAN_TOKEN, address(0));
    }

    function testShouldRevertWhenCreatingDuplicatePriceFeed() public {
        factory.createPriceFeed(MORPHO_ORACLE, COLLATERAL_TOKEN, LOAN_TOKEN, FUSION_PRICE_MIDDLEWARE);

        vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeedFactory.PriceFeedAlreadyExists.selector);
        factory.createPriceFeed(MORPHO_ORACLE, COLLATERAL_TOKEN, LOAN_TOKEN, FUSION_PRICE_MIDDLEWARE);
    }

    function testShouldGetPriceFeedAddress() public {
        address priceFeed = factory.createPriceFeed(
            MORPHO_ORACLE,
            COLLATERAL_TOKEN,
            LOAN_TOKEN,
            FUSION_PRICE_MIDDLEWARE
        );

        address retrievedPriceFeed = factory.getPriceFeedAddress(
            address(this),
            MORPHO_ORACLE,
            COLLATERAL_TOKEN,
            LOAN_TOKEN,
            FUSION_PRICE_MIDDLEWARE
        );

        assertEq(retrievedPriceFeed, priceFeed);
    }

    function testShouldGenerateCorrectKey() public {
        bytes32 key = factory.generateKey(
            address(this),
            MORPHO_ORACLE,
            COLLATERAL_TOKEN,
            LOAN_TOKEN,
            FUSION_PRICE_MIDDLEWARE
        );

        assertTrue(key != bytes32(0));
    }

    function testShouldTrackMultipleCreators() public {
        address creator1 = address(0x1);
        address creator2 = address(0x2);

        vm.prank(creator1);
        factory.createPriceFeed(MORPHO_ORACLE, COLLATERAL_TOKEN, LOAN_TOKEN, FUSION_PRICE_MIDDLEWARE);

        vm.prank(creator2);
        factory.createPriceFeed(MORPHO_ORACLE, COLLATERAL_TOKEN, LOAN_TOKEN, FUSION_PRICE_MIDDLEWARE);

        assertTrue(factory.isCreator(creator1));
        assertTrue(factory.isCreator(creator2));
        assertEq(factory.creators(0), creator1);
        assertEq(factory.creators(1), creator2);
    }
}
