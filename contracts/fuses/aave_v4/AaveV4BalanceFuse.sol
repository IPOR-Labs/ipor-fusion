// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {AaveV4SubstrateLib} from "./AaveV4SubstrateLib.sol";
import {IAaveV4Spoke} from "./ext/IAaveV4Spoke.sol";

/// @title AaveV4BalanceFuse
/// @author IPOR Labs
/// @notice Fuse for Aave V4 protocol responsible for calculating the balance of the Plasma Vault in USD
/// @dev Iterates over Spoke substrates and calculates the net value of all positions (supply - debt) in USD.
///      Uses getUserSuppliedAssets() and getUserTotalDebt() to get position values in asset units.
///      Prices are obtained from PlasmaVault's PriceOracleMiddleware.
///      Final balance is normalized to WAD (18 decimals).
///      Gas optimization: for each reserve, checks if the underlying asset is a granted Asset substrate
///      before querying position data. Since Supply/Borrow fuses validate asset substrates on enter/exit,
///      reserves with non-granted assets cannot have positions and are skipped.
contract AaveV4BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    uint256 public immutable MARKET_ID;

    /// @notice Thrown when market ID is zero or invalid
    /// @custom:error AaveV4BalanceFuseInvalidMarketId
    error AaveV4BalanceFuseInvalidMarketId();

    /// @notice Thrown when total debt exceeds total supply value (negative balance)
    /// @param balance The calculated negative balance value
    /// @custom:error AaveV4BalanceFuseNegativeBalance
    error AaveV4BalanceFuseNegativeBalance(int256 balance);

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketId_ The unique identifier for the market configuration
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert AaveV4BalanceFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Calculates the total balance of the Plasma Vault in Aave V4 protocol
    /// @dev Iterates over Spoke substrates, queries positions in each reserve,
    ///      prices via PriceOracleMiddleware, and returns the total net USD value in 18 decimals.
    ///      Reverts if total debt exceeds total supply value (negative balance).
    /// @return The total balance in USD, normalized to WAD (18 decimals)
    /// @custom:revert AaveV4BalanceFuseNegativeBalance When total debt exceeds total supply value
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;
        if (len == 0) {
            return 0;
        }

        int256 balanceTemp;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            if (AaveV4SubstrateLib.isSpokeSubstrate(substrates[i])) {
                balanceTemp += _calculateSpokeBalance(
                    IAaveV4Spoke(AaveV4SubstrateLib.decodeAddress(substrates[i])),
                    priceOracleMiddleware
                );
            }
        }

        if (balanceTemp < 0) {
            revert AaveV4BalanceFuseNegativeBalance(balanceTemp);
        }

        return balanceTemp.toUint256();
    }

    /// @notice Calculates the balance for all reserves in a single Spoke
    /// @dev Gas optimization: fetches reserve metadata first and skips reserves whose underlying
    ///      asset is not a granted Asset substrate. Since Supply/Borrow fuses validate asset substrates,
    ///      non-granted assets cannot have positions, saving 2+ external calls per skipped reserve.
    /// @param spoke_ The Aave V4 Spoke contract
    /// @param priceOracleMiddleware_ The price oracle middleware address
    /// @return The net balance in WAD for all reserves in the Spoke
    function _calculateSpokeBalance(
        IAaveV4Spoke spoke_,
        address priceOracleMiddleware_
    ) private view returns (int256) {
        int256 spokeBalance;
        uint256 reserveCount = spoke_.getReserveCount();
        address plasmaVault = address(this);

        // Reserves are indexed sequentially from 0 in Aave V4
        for (uint256 r; r < reserveCount; ++r) {
            IAaveV4Spoke.Reserve memory reserve = spoke_.getReserve(r);

            // Skip reserves whose underlying asset is not a granted substrate.
            // Supply/Borrow fuses enforce asset substrate validation, so the vault
            // cannot hold positions in reserves with non-granted assets.
            bytes32 assetSubstrate = AaveV4SubstrateLib.encodeAsset(reserve.underlying);
            if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, assetSubstrate)) {
                continue;
            }

            spokeBalance += _calculateReserveBalance(spoke_, r, reserve.underlying, plasmaVault, priceOracleMiddleware_);
        }

        return spokeBalance;
    }

    /// @notice Calculates the balance for a single reserve in a Spoke
    /// @param spoke_ The Aave V4 Spoke contract
    /// @param reserveId_ The reserve ID (sequential index starting from 0)
    /// @param underlying_ The underlying asset address (already fetched by caller)
    /// @param plasmaVault_ The PlasmaVault address
    /// @param priceOracleMiddleware_ The price oracle middleware address
    /// @return The net balance in WAD for the reserve (supply - debt)
    function _calculateReserveBalance(
        IAaveV4Spoke spoke_,
        uint256 reserveId_,
        address underlying_,
        address plasmaVault_,
        address priceOracleMiddleware_
    ) private view returns (int256) {
        uint256 supplyAssets = spoke_.getUserSuppliedAssets(reserveId_, plasmaVault_);
        uint256 debtAssets = spoke_.getUserTotalDebt(reserveId_, plasmaVault_);

        if (supplyAssets == 0 && debtAssets == 0) {
            return 0;
        }

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(underlying_);
        if (price == 0) {
            revert Errors.UnsupportedQuoteCurrencyFromOracle();
        }

        int256 netAmount = int256(supplyAssets) - int256(debtAssets);

        return IporMath.convertToWadInt(netAmount * int256(price), IERC20Metadata(underlying_).decimals() + priceDecimals);
    }
}
