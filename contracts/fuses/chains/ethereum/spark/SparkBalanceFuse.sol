// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {IMarketBalanceFuse} from "../../../IMarketBalanceFuse.sol";
import {ISavingsDai} from "./ext/ISavingsDai.sol";

/**
 * @title SparkBalanceFuse
 * @notice A fuse contract that calculates the balance of the Plasma Vault in the Spark protocol
 * @dev This contract implements the IMarketBalanceFuse interface and is designed to work with
 *      Spark protocol's Savings DAI (sDAI) token. It calculates the USD value of sDAI holdings
 *      by converting the sDAI balance to USD using the price oracle middleware.
 *
 * Key Features:
 * - Calculates the total USD value of sDAI holdings for a specific market
 * - Uses price oracle middleware for accurate USD conversions
 * - Validates that sDAI is granted as a substrate for the market
 * - Returns balance normalized to WAD (18 decimals) precision
 *
 * Architecture:
 * - Each fuse is tied to a specific market ID
 * - Uses hardcoded sDAI address (Spark Savings DAI token on Ethereum mainnet)
 * - Retrieves sDAI balance from the Spark protocol
 * - Converts balance to USD using price oracle middleware
 * - Returns total USD value in WAD precision
 *
 * Security Considerations:
 * - Immutable market ID prevents configuration changes
 * - Input validation ensures market ID is not zero
 * - Validates that sDAI is granted as a substrate before use
 * - Uses view functions for balance calculations to prevent state changes
 * - Relies on trusted price oracle middleware for accurate pricing
 */
contract SparkBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when market ID is zero
    error SparkBalanceFuseInvalidMarketId();

    /// @notice Thrown when sDAI token is not granted as a substrate for the market
    /// @param sdai The sDAI token address that is not granted
    error SparkBalanceFuseSdaiNotGranted(address sdai);

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates
    uint256 public immutable MARKET_ID;

    /// @notice Address of Spark Savings DAI (sDAI) token on Ethereum mainnet
    /// @dev Hardcoded address: 0x83F20F44975D03b1b09e64809B757c47f942BEeA
    ///      This is the official sDAI token address used for Spark protocol interactions
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    /// @notice Address representing USD currency identifier
    /// @dev Hardcoded address: 0x0000000000000000000000000000000000000348
    ///      This is a standard address used to represent USD in price oracle systems
    ///      Not directly used in this contract but kept for consistency with price oracle patterns
    address private constant USD = address(0x0000000000000000000000000000000000000348);

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketId_ The unique identifier for the market configuration
    /// @dev The market ID is used to retrieve the list of substrates configured for this market.
    ///      VERSION is set to the address of this contract instance for tracking purposes.
    ///      Reverts if marketId_ is zero.
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert SparkBalanceFuseInvalidMarketId();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Calculates the balance of the Plasma Vault in Spark protocol
    /// @dev This function:
    ///      1. Validates that sDAI is granted as a substrate for the market
    ///      2. Retrieves the sDAI balance held by the vault from Spark protocol
    ///      3. Converts the sDAI balance to USD using the price oracle middleware
    ///      4. Returns the total USD value normalized to WAD (18 decimals) precision
    ///      The calculation methodology ensures that:
    ///      - Only granted substrates are processed (security validation)
    ///      - sDAI balance is retrieved directly from Spark protocol
    ///      - All balances are converted to a common USD-denominated value using oracle prices
    ///      - Final result is normalized to WAD precision (18 decimals) for consistency
    /// @return The balance of the Plasma Vault in Spark protocol, normalized to WAD (18 decimals)
    function balanceOf() external view override returns (uint256) {
        return _convertToUsd(SDAI, ISavingsDai(SDAI).balanceOf(address(this)));
    }

    /// @notice Converts a token amount to its USD value using the price oracle
    /// @dev Uses the price oracle middleware to get the token price and converts the amount
    ///      accounting for token decimals and oracle decimals. Returns zero if amount is zero.
    /// @param asset_ The address of the token to convert
    /// @param amount_ The amount of tokens to convert, in token decimals
    /// @return The USD value of the tokens normalized to WAD (18 decimals)
    function _convertToUsd(address asset_, uint256 amount_) internal view returns (uint256) {
        if (amount_ == 0) {
            return 0;
        }
        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware())
            .getAssetPrice(asset_);
        return IporMath.convertToWad(amount_ * price, IERC20Metadata(asset_).decimals() + decimals);
    }
}
