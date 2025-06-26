// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {IMorphoOracle} from "./ext/IMorphoOracle.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

/**
 * @title CollateralTokenOnMorphoMarketPriceFeed
 * @notice A price feed contract that calculates the USD price of a collateral token
 *         by combining Morpho's oracle price (collateral/loan token ratio) with
 *         the loan token's USD price from the Fusion price oracle middleware.
 *
 * @dev This contract implements the IPriceFeed interface and provides price data
 *      for collateral tokens in Morpho markets. It works by:
 *      1. Getting the collateral token price in terms of loan token from Morpho's oracle
 *      2. Getting the loan token's USD price from the Fusion Price Manager
 *      3. Combining these prices to calculate the collateral token's USD price
 *
 * @dev The price calculation follows this formula:
 *      collateralPriceUSD = (collateralPriceInLoanToken * loanTokenPriceUSD) / (10^decimals_adjustment)
 *
 * @dev This contract is immutable and cannot be upgraded after deployment.
 *
 */
contract CollateralTokenOnMorphoMarketPriceFeed is IPriceFeed {
    using SafeCast for uint256;

    uint256 private constant MORPHO_PRICE_PRECISION = 36;

    /// @notice The Morpho oracle contract that provides collateral/loan token price
    address public immutable morphoOracle;
    /// @notice The collateral token address
    address public immutable collateralToken;
    /// @notice The loan token address
    address public immutable loanToken;
    /// @notice The Fusion price manager (can be PriceOracleMiddleware or PriceOracleMiddlewareManager)
    address public immutable fusionPriceManager;

    /// @notice The number of decimals for the loan token
    uint256 public immutable loanTokenDecimals;
    /// @notice The number of decimals for the collateral token
    uint256 public immutable collateralTokenDecimals;

    error InvalidMorphoOraclePrice();
    error InvalidPriceOracleMiddleware();
    error InvalidTokenDecimals();
    error ZeroAddressMorphoOracle();
    error ZeroAddressCollateralToken();
    error ZeroAddressLoanToken();
    error ZeroAddressFusionPriceMiddleware();

    /**
     * @notice Constructor to initialize the price feed
     * @param _morphoOracle The address of the Morpho oracle contract
     * @param _collateralToken The address of the collateral token
     * @param _loanToken The address of the loan token
     * @param _fusionPriceManager The address of the Fusion price manager
     */
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

    /**
     * @notice Returns the latest price data for the collateral token in USD
     * @dev Calculates the USD price by combining Morpho's collateral/loan token price
     *      with the loan token's USD price from the Fusion price manager
     * @return roundId Always returns 0 (not used in this implementation)
     * @return price The USD price of the collateral token with 18 decimals
     * @return startedAt Always returns 0 (not used in this implementation)
     * @return time Always returns 0 (not used in this implementation)
     * @return answeredInRound Always returns 0 (not used in this implementation)
     */
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        ///@dev the price of 1 asset of collateral token quoted in 1 asset of loan token
        uint256 collateralPriceInLoanToken = IMorphoOracle(morphoOracle).price();

        if (collateralPriceInLoanToken == 0) {
            revert InvalidMorphoOraclePrice();
        }

        (uint256 loanTokenPriceInUsd, uint256 loanTokenPriceInUsdDecimals) = IPriceOracleMiddleware(fusionPriceManager)
            .getAssetPrice(loanToken);

        if (loanTokenPriceInUsd == 0 || loanTokenPriceInUsdDecimals == 0) {
            revert InvalidPriceOracleMiddleware();
        }

        return (
            0,
            IporMath
                .convertToWad(
                    collateralPriceInLoanToken * loanTokenPriceInUsd,
                    MORPHO_PRICE_PRECISION + loanTokenDecimals + loanTokenPriceInUsdDecimals - collateralTokenDecimals
                )
                .toInt256(),
            0,
            0,
            0
        );
    }

    /**
     * @notice Returns the number of decimals used by the price feed
     * @return The number of decimals (always 18 for this implementation)
     */
    function decimals() external view override returns (uint8) {
        return 18;
    }
}
