// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MErc20} from "./ext/MErc20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title MoonwellBalanceFuse
 * @notice A fuse contract that calculates the net USD balance of the Plasma Vault in the Moonwell protocol
 * @dev This contract implements the IMarketBalanceFuse interface and calculates the balance by:
 *      - Summing all supplied asset values (mToken underlying balances)
 *      - Subtracting all borrowed asset values (mToken borrow balances)
 *      - Converting all values to USD using the price oracle middleware
 *      - Normalizing to WAD (18 decimals)
 *      - Returning zero if the net balance is negative
 *
 * Key Features:
 * - Calculates net balance (supplied - borrowed) for all mTokens in a market
 * - Supports multiple substrates (mTokens) per market
 * - Uses price oracle middleware for accurate USD conversions
 * - Handles negative balances by returning zero
 *
 * Architecture:
 * - Each fuse is tied to a specific market ID
 * - Retrieves granted substrates (mToken addresses) from the vault configuration
 * - For each mToken, calculates supplied and borrowed balances
 * - Converts balances to USD and aggregates the net result
 *
 * Security Considerations:
 * - Immutable market ID prevents configuration changes
 * - Validates that price is not zero before calculations
 * - Uses SafeCast for type conversions to prevent overflow
 *
 * @author IPOR Labs
 */
contract MoonwellBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    using SafeCast for uint256;
    using Address for address;

    /// @notice The address of this fuse version for tracking purposes
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev This ID is used to retrieve the list of substrates (mToken addresses) configured for this market
    uint256 public immutable MARKET_ID;

    /// @notice Thrown when price oracle returns zero price for an asset
    /// @custom:error MoonwellBalanceFuseInvalidPrice
    error MoonwellBalanceFuseInvalidPrice();

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketId_ The unique identifier for the market configuration
    /// @dev The market ID is used to retrieve the list of substrates (mToken addresses) that this fuse will track.
    ///      VERSION is set to the address of this contract instance for tracking purposes.
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Calculates the total net balance of the Plasma Vault in the Moonwell protocol
     * @dev This function retrieves all substrates (mToken addresses) configured for the MARKET_ID
     *      and calculates the net balance by summing supplied assets and subtracting borrowed assets.
     *      The balance is calculated for the contract itself (address(this)) which should be the Plasma Vault.
     * @return The net balance of the Plasma Vault in USD, normalized to WAD (18 decimals).
     *         Returns zero if the net balance is negative.
     */
    function balanceOf() external override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        return _calculateBalance(assetsRaw, address(this));
    }

    /**
     * @notice Calculates the net balance for specific substrates and plasma vault address
     * @param substrates_ Array of substrate addresses (mToken addresses) encoded as bytes32
     * @param plasmaVault_ Address of the plasma vault to calculate balance for
     * @return The net balance in USD, normalized to WAD (18 decimals).
     *         Returns zero if the net balance is negative.
     * @dev This function allows calculating balance for a specific vault address and set of substrates,
     *      which is useful for testing or querying balances for different vault instances.
     */
    function balanceOf(bytes32[] memory substrates_, address plasmaVault_) external returns (uint256) {
        return _calculateBalance(substrates_, plasmaVault_);
    }

    /**
     * @notice Internal function to calculate the net balance for given substrates and plasma vault
     * @param substrates_ Array of substrate addresses (mToken addresses) encoded as bytes32
     * @param plasmaVault_ Address of the plasma vault to calculate balance for
     * @return The net balance in USD, normalized to WAD (18 decimals). Returns zero if empty substrates or negative balance.
     * @dev This function performs the following steps for each mToken substrate:
     *      1. Converts bytes32 substrate to mToken address
     *      2. Retrieves the underlying asset address from the mToken
     *      3. Gets the underlying asset decimals
     *      4. Retrieves the asset price and price decimals from the price oracle middleware
     *      5. Validates that price is not zero (reverts if zero)
     *      6. Calculates supplied value: mToken.balanceOfUnderlying() * price, converted to WAD
     *      7. Calculates borrowed value: mToken.borrowBalanceStored() * price, converted to WAD
     *      8. Adds supplied value and subtracts borrowed value from running balance
     *      9. Returns zero if final balance is negative, otherwise returns the positive balance
     */
    function _calculateBalance(bytes32[] memory substrates_, address plasmaVault_) internal returns (uint256) {
        if (substrates_.length == 0) {
            return 0;
        }

        int256 balanceTemp;
        uint256 decimals;
        /// @dev Price from oracle middleware, typically has 8 decimals
        uint256 price;
        uint256 priceDecimals;
        MErc20 mToken;
        address underlying;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < substrates_.length; ++i) {
            mToken = MErc20(PlasmaVaultConfigLib.bytes32ToAddress(substrates_[i]));
            underlying = mToken.underlying();
            decimals = ERC20(underlying).decimals();

            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(underlying);
            if (price == 0) {
                revert MoonwellBalanceFuseInvalidPrice();
            }
            // Calculate supplied value in USD
            balanceTemp += IporMath.convertToWadInt(
                mToken.balanceOfUnderlying(plasmaVault_).toInt256() * int256(price),
                decimals + priceDecimals
            );

            // Subtract borrowed value in USD using borrowBalanceStored
            balanceTemp -= IporMath.convertToWadInt(
                (mToken.borrowBalanceStored(plasmaVault_) * price).toInt256(),
                decimals + priceDecimals
            );
        }

        // If balance is negative, return 0
        return balanceTemp < 0 ? 0 : balanceTemp.toUint256();
    }
}
