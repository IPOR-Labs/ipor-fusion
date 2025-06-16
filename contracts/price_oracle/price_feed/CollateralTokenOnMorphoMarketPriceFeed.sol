// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {IMorphoOracle} from "./ext/IMorphoOracle.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

contract CollateralTokenOnMorphoMarketPriceFeed is IPriceFeed {
    using SafeCast for uint256;

    uint256 private constant MORPHO_PRICE_PRECISION = 36;

    address public immutable morphoOracle;
    address public immutable collateralToken;
    address public immutable loanToken;
    address public immutable fusionPriceMiddleware;

    uint256 public immutable loanTokenDecimals;
    uint256 public immutable collateralTokenDecimals;

    error InvalidMorphoOraclePrice();
    error InvalidPriceOracleMiddleware();
    error InvalidTokenDecimals();

    constructor(address _morphoOracle, address _collateralToken, address _loanToken, address _fusionPriceMiddleware) {
        require(_morphoOracle != address(0), "MorphoOracle is zero address");
        require(_collateralToken != address(0), "CollateralToken is zero address");
        require(_loanToken != address(0), "LoanToken is zero address");
        require(_fusionPriceMiddleware != address(0), "FusionPriceMiddleware is zero address");

        morphoOracle = _morphoOracle;
        collateralToken = _collateralToken;
        loanToken = _loanToken;
        fusionPriceMiddleware = _fusionPriceMiddleware;
        loanTokenDecimals = IERC20Metadata(loanToken).decimals();
        collateralTokenDecimals = IERC20Metadata(collateralToken).decimals();
        if (loanTokenDecimals == 0 || collateralTokenDecimals == 0) {
            revert InvalidTokenDecimals();
        }
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        uint256 morphoOraclePrice = IMorphoOracle(morphoOracle).price();

        if (morphoOraclePrice == 0) {
            revert InvalidMorphoOraclePrice();
        }

        (
            uint256 loanTokenPriceFromFusionPriceMiddleware,
            uint256 loanTokenDecimalsFromFusionPriceMiddleware
        ) = IPriceOracleMiddleware(fusionPriceMiddleware).getAssetPrice(loanToken);

        if (loanTokenDecimalsFromFusionPriceMiddleware == 0 || loanTokenDecimalsFromFusionPriceMiddleware == 0) {
            revert InvalidPriceOracleMiddleware();
        }

        uint256 price = IporMath.convertToWad(
            morphoOraclePrice * loanTokenPriceFromFusionPriceMiddleware,
            MORPHO_PRICE_PRECISION +
                loanTokenDecimals +
                loanTokenDecimalsFromFusionPriceMiddleware -
                collateralTokenDecimals
        );

        return (0, price.toInt256(), 0, 0, 0);
    }

    function decimals() external view override returns (uint8) {
        return 18;
    }
}
