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
    /// @notice Can be either PriceOracleMiddleware or PriceOracleMiddlewareManager
    address public immutable fusionPriceManager;

    uint256 public immutable loanTokenDecimals;
    uint256 public immutable collateralTokenDecimals;

    error InvalidMorphoOraclePrice();
    error InvalidPriceOracleMiddleware();
    error InvalidTokenDecimals();
    error ZeroAddressMorphoOracle();
    error ZeroAddressCollateralToken();
    error ZeroAddressLoanToken();
    error ZeroAddressFusionPriceMiddleware();

    constructor(address _morphoOracle, address _collateralToken, address _loanToken, address _fusionPriceManager) {
        if (_morphoOracle == address(0)) revert ZeroAddressMorphoOracle();
        if (_collateralToken == address(0)) revert ZeroAddressCollateralToken();
        if (_loanToken == address(0)) revert ZeroAddressLoanToken();
        if (_fusionPriceManager == address(0)) revert ZeroAddressFusionPriceMiddleware();

        morphoOracle = _morphoOracle;
        collateralToken = _collateralToken;
        loanToken = _loanToken;
        fusionPriceManager = _fusionPriceManager;
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

        (uint256 loanTokenPrice, uint256 loanTokenPriceDecimals) = IPriceOracleMiddleware(fusionPriceManager)
            .getAssetPrice(loanToken);

        if (loanTokenPrice == 0 || loanTokenPriceDecimals == 0) {
            revert InvalidPriceOracleMiddleware();
        }

        return (
            0,
            IporMath
                .convertToWad(
                    morphoOraclePrice * loanTokenPrice,
                    MORPHO_PRICE_PRECISION + loanTokenDecimals + loanTokenPriceDecimals - collateralTokenDecimals
                )
                .toInt256(),
            0,
            0,
            0
        );
    }

    function decimals() external view override returns (uint8) {
        return 18;
    }
}
