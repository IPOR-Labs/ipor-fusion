// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CollateralTokenOnMorphoMarketPriceFeed} from "../../../contracts/price_oracle/price_feed/CollateralTokenOnMorphoMarketPriceFeed.sol";
import {IMorphoOracle} from "../../../contracts/price_oracle/price_feed/ext/IMorphoOracle.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract CollateralTokenOnMorphoMarketPriceFeedTest is Test {
    address constant MORPHO_ORACLE = 0x1376913337ceC523B4DDEAD8a60eDb1fA43fF1E3;
    address constant COLLATERAL_TOKEN = 0x3b3fB9C57858EF816833dC91565EFcd85D96f634;
    address constant LOAN_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FUSION_PRICE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;

    CollateralTokenOnMorphoMarketPriceFeed public priceFeed;
    IMorphoOracle public morphoOracle;
    IPriceOracleMiddleware public fusionPriceMiddleware;
    IERC20Metadata public collateralToken;
    IERC20Metadata public loanToken;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22715912);

        priceFeed = new CollateralTokenOnMorphoMarketPriceFeed(
            MORPHO_ORACLE,
            COLLATERAL_TOKEN,
            LOAN_TOKEN,
            FUSION_PRICE_MIDDLEWARE
        );

        morphoOracle = IMorphoOracle(MORPHO_ORACLE);
        fusionPriceMiddleware = IPriceOracleMiddleware(FUSION_PRICE_MIDDLEWARE);
        collateralToken = IERC20Metadata(COLLATERAL_TOKEN);
        loanToken = IERC20Metadata(LOAN_TOKEN);
    }

    function testShouldInitializeWithCorrectParameters() public {
        assertEq(address(priceFeed.morphoOracle()), MORPHO_ORACLE);
        assertEq(address(priceFeed.collateralToken()), COLLATERAL_TOKEN);
        assertEq(address(priceFeed.loanToken()), LOAN_TOKEN);
        assertEq(address(priceFeed.fusionPriceMiddleware()), FUSION_PRICE_MIDDLEWARE);
        assertEq(priceFeed.loanTokenDecimals(), loanToken.decimals());
        assertEq(priceFeed.collateralTokenDecimals(), collateralToken.decimals());
    }

    function testShouldRevertWhenMorphoOracleIsZeroAddress() public {
        vm.expectRevert("MorphoOracle is zero address");
        new CollateralTokenOnMorphoMarketPriceFeed(address(0), COLLATERAL_TOKEN, LOAN_TOKEN, FUSION_PRICE_MIDDLEWARE);
    }

    function testShouldRevertWhenCollateralTokenIsZeroAddress() public {
        vm.expectRevert("CollateralToken is zero address");
        new CollateralTokenOnMorphoMarketPriceFeed(MORPHO_ORACLE, address(0), LOAN_TOKEN, FUSION_PRICE_MIDDLEWARE);
    }

    function testShouldRevertWhenLoanTokenIsZeroAddress() public {
        vm.expectRevert("LoanToken is zero address");
        new CollateralTokenOnMorphoMarketPriceFeed(
            MORPHO_ORACLE,
            COLLATERAL_TOKEN,
            address(0),
            FUSION_PRICE_MIDDLEWARE
        );
    }

    function testShouldRevertWhenFusionPriceMiddlewareIsZeroAddress() public {
        vm.expectRevert("FusionPriceMiddleware is zero address");
        new CollateralTokenOnMorphoMarketPriceFeed(MORPHO_ORACLE, COLLATERAL_TOKEN, LOAN_TOKEN, address(0));
    }

    function testShouldReturnLatestRoundData() public {
        (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = priceFeed
            .latestRoundData();

        assertEq(roundId, 0);
        assertGt(price, 0);
        assertEq(startedAt, 0);
        assertEq(time, 0);
        assertEq(answeredInRound, 0);
    }

    function testShouldRevertWhenMorphoOraclePriceIsInvalid() public {
        // Mock morpho oracle to return 0 price
        vm.mockCall(MORPHO_ORACLE, abi.encodeWithSelector(IMorphoOracle.price.selector), abi.encode(0));

        vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeed.InvalidMorphoOraclePrice.selector);
        priceFeed.latestRoundData();
    }

    function testShouldRevertWhenPriceOracleMiddlewareIsInvalid() public {
        // Mock fusion price middleware to return 0 decimals
        vm.mockCall(
            FUSION_PRICE_MIDDLEWARE,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, LOAN_TOKEN),
            abi.encode(0, 0)
        );

        vm.expectRevert(CollateralTokenOnMorphoMarketPriceFeed.InvalidPriceOracleMiddleware.selector);
        priceFeed.latestRoundData();
    }
}
