// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPriceFeed} from "./IPriceFeed.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {ICurveStableSwapNG} from "./ext/ICurveStableSwapNG.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CurveStableSwapNGPriceFeed is IPriceFeed {
    using SafeCast for uint256;

    error ZeroAddress();
    error PriceOracleMiddleware_InvalidPrice();
    error CurveStableSwapNG_InvalidTotalSupply();
    error CurveStableSwapNG_InvalidBalance();

    address public immutable CURVE_STABLE_SWAP_NG;
    address public immutable PRICE_ORACLE_MIDDLEWARE;
    uint256 public immutable N_COINS;
    uint256 public immutable DECIMALS_LP;
    address[] public coins;

    constructor(address _curveStableSwapNG, address _priceOracleMiddleware) {
        if (_curveStableSwapNG == address(0) || _priceOracleMiddleware == address(0)) {
            revert ZeroAddress();
        }

        CURVE_STABLE_SWAP_NG = _curveStableSwapNG;
        PRICE_ORACLE_MIDDLEWARE = _priceOracleMiddleware;
        N_COINS = ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).N_COINS();
        DECIMALS_LP = ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).decimals();
        for (uint256 i = 0; i < N_COINS; i++) {
            coins.push(ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).coins(i));
        }
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        uint256 totalSupply = ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).totalSupply();
        if (totalSupply == 0) {
            revert CurveStableSwapNG_InvalidTotalSupply();
        }
        uint256 coinBalance;
        uint256[] memory coinAmountForOneShareArray = new uint256[](N_COINS);
        for (uint256 i; i < N_COINS; i++) {
            coinAmountForOneShareArray[i] = Math.mulDiv(
                ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).balances(i),
                10 ** DECIMALS_LP, /// @dev DECIMALS_LP is the decimals of the LP token, which is 18 and this is value of one share
                totalSupply
            );
        }

        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE);

        uint256 totalPrice;
        uint256 coinPrice;
        uint256 coinPriceDecimals;
        for (uint256 i; i < N_COINS; i++) {
            (coinPrice, coinPriceDecimals) = priceOracleMiddleware.getAssetPrice(coins[i]);
            if (coinPrice == 0) {
                revert PriceOracleMiddleware_InvalidPrice();
            }
            totalPrice += IporMath.convertToWad(
                coinAmountForOneShareArray[i] * coinPrice,
                coinPriceDecimals + ERC20(coins[i]).decimals()
            );
        }

        return (0, totalPrice.toInt256(), 0, 0, 0);
    }

    function decimals() external view override returns (uint8) {
        return 18;
    }
}
