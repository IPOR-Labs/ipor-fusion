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
import {AaveV4SubstrateLib, AaveV4Substrate} from "./AaveV4SubstrateLib.sol";
import {IAaveV4Spoke} from "./ext/IAaveV4Spoke.sol";

/// @title AaveV4BalanceFuse
/// @author IPOR Labs
/// @notice Fuse for Aave V4 protocol responsible for calculating the balance of the Plasma Vault in USD
/// @dev Iterates over the granted Reserve substrates (spoke, reserveId) and sums the net value
///      (supplied - total debt) of every reserve. Debt is always queried, regardless of the canBorrow flag,
///      so revoking a borrow permission can never hide existing debt.
///      Substrates that decode to the same (spoke, reserveId) pair (e.g. two flag variants) are counted once;
///      non-canonical words and reserve ids not listed on the Spoke are skipped.
///      Prices are obtained from PlasmaVault's PriceOracleMiddleware. Final balance is normalized to WAD.
///      Positions on reserves whose grant was removed entirely are not visible until the reserve is re-granted
///      (grant changes are not validated against open positions - see the README for the atomist rules).
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
    /// @dev Iterates over granted Reserve substrates, queries supplied assets and total debt of each reserve,
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
        address plasmaVault = address(this);
        AaveV4Substrate memory substrate;

        for (uint256 i; i < len; ++i) {
            if (!AaveV4SubstrateLib.isReserveSubstrate(substrates[i])) {
                continue;
            }

            substrate = AaveV4SubstrateLib.decode(substrates[i]);

            if (_isDuplicate(substrates, i, substrate.spoke, substrate.reserveId)) {
                continue;
            }

            balanceTemp += _calculateReserveBalance(
                IAaveV4Spoke(substrate.spoke),
                substrate.reserveId,
                plasmaVault,
                priceOracleMiddleware
            );
        }

        if (balanceTemp < 0) {
            revert AaveV4BalanceFuseNegativeBalance(balanceTemp);
        }

        return balanceTemp.toUint256();
    }

    /// @notice Checks whether an earlier substrate already covers the same (spoke, reserveId) pair
    /// @param substrates_ All granted substrates of the market
    /// @param index_ Index of the substrate being evaluated; only earlier indices are compared
    /// @param spoke_ Spoke of the substrate being evaluated
    /// @param reserveId_ Reserve id of the substrate being evaluated
    /// @return True if a substrate with a lower index decodes to the same pair
    function _isDuplicate(
        bytes32[] memory substrates_,
        uint256 index_,
        address spoke_,
        uint32 reserveId_
    ) private pure returns (bool) {
        AaveV4Substrate memory other;

        for (uint256 j; j < index_; ++j) {
            if (!AaveV4SubstrateLib.isReserveSubstrate(substrates_[j])) {
                continue;
            }
            other = AaveV4SubstrateLib.decode(substrates_[j]);
            if (other.spoke == spoke_ && other.reserveId == reserveId_) {
                return true;
            }
        }

        return false;
    }

    /// @notice Calculates the net balance of a single reserve
    /// @param spoke_ The Aave V4 Spoke contract
    /// @param reserveId_ The reserve identifier within the Spoke
    /// @param plasmaVault_ The PlasmaVault address
    /// @param priceOracleMiddleware_ The price oracle middleware address
    /// @return The net balance in WAD for the reserve (supplied - total debt); 0 when the reserve id is not listed
    ///         on the Spoke yet (a pre-granted id must not block balance updates of the whole vault)
    /// @custom:revert Errors.UnsupportedQuoteCurrencyFromOracle When the oracle returns a zero price
    function _calculateReserveBalance(
        IAaveV4Spoke spoke_,
        uint256 reserveId_,
        address plasmaVault_,
        address priceOracleMiddleware_
    ) private view returns (int256) {
        if (reserveId_ >= spoke_.getReserveCount()) {
            return 0;
        }

        uint256 supplyAssets = spoke_.getUserSuppliedAssets(reserveId_, plasmaVault_);
        uint256 debtAssets = spoke_.getUserTotalDebt(reserveId_, plasmaVault_);

        if (supplyAssets == 0 && debtAssets == 0) {
            return 0;
        }

        address underlying = spoke_.getReserve(reserveId_).underlying;

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
            underlying
        );
        if (price == 0) {
            revert Errors.UnsupportedQuoteCurrencyFromOracle();
        }

        int256 netAmount = int256(supplyAssets) - int256(debtAssets);

        return
            IporMath.convertToWadInt(netAmount * int256(price), IERC20Metadata(underlying).decimals() + priceDecimals);
    }
}
