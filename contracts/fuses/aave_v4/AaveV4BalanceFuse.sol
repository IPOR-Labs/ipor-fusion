// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
/// @dev Values every Aave V4 Spoke of the Plasma Vault on its own, by what the vault keeps once its debt is settled,
///      and returns the sum over the Spokes in USD normalized to WAD (IL-9552, follow-up of the 3sigma audit finding #1).
///      Every Spoke is a separate account with limited liability: positions and the health factor are kept per Spoke,
///      and a liquidation of one Spoke never touches the positions of the vault on another Spoke. A liquidation seizes
///      only reserves that the vault enabled as collateral, and supply that is not collateral can be withdrawn even
///      below health factor 1. With C = supply enabled as collateral, F = every other supply and D = the debt of all
///      granted reserves of the Spoke, one Spoke is worth F + max(0, C - D):
///      - F survives a liquidation, so it counts in full;
///      - an underwater Spoke (C below D) contributes F only. Its shortfall is not charged to the other Spokes and the
///        sum is never negative, so the fuse does not revert and the market does not freeze;
///      - a liquidation of an underwater Spoke seizes C and books the debt it leaves as a deficit of the Hub (kept in
///        the added assets of the Hub, not charged to the supply of the vault when booked); the Spoke then keeps F,
///        which is what it was already valued at. The value is never above what the vault keeps after a liquidation,
///        so writing off the bad debt does not step NAV up beyond rounding.
///      Collateral enabled on a reserve whose collateral factor is 0 is counted as C: it may understate, never
///      overstate. Supply values are rounded down and debt values up, so a healthy Spoke is valued at most 2 wei WAD
///      per reserve below the nearest rounding of its net value and never above it.
///      The fuse does not signal bad debt: monitor the health factor of each Spoke off-chain (`getUserAccountData`).
///      Debt is always queried, regardless of the canBorrow flag, so revoking a borrow permission can never hide
///      existing debt. Substrates that decode to the same (spoke, reserveId) pair (e.g. two flag variants) are
///      counted once; non-canonical words and reserve ids not listed on the Spoke are skipped.
///      Prices are obtained from PlasmaVault's PriceOracleMiddleware. Final balance is normalized to WAD.
///      Positions on reserves whose grant was removed entirely are not visible until the reserve is re-granted
///      (grant changes are not validated against open positions - see the README for the atomist rules); when the
///      collateral reserve of a Spoke loses its grant while its debt reserve keeps one, the Spoke shows only the debt
///      and is valued at F (understated, never overstated).
contract AaveV4BalanceFuse is IMarketBalanceFuse {
    /// @dev Decimals of the WAD-normalized USD values
    uint256 private constant WAD_DECIMALS = 18;

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    uint256 public immutable MARKET_ID;

    /// @notice Thrown when market ID is zero or invalid
    /// @custom:error AaveV4BalanceFuseInvalidMarketId
    error AaveV4BalanceFuseInvalidMarketId();

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
    /// @dev Groups the granted Reserve substrates by Spoke and adds F + max(0, C - D) of every Spoke (see the contract
    ///      NatSpec), priced via PriceOracleMiddleware. Never negative and never reverts on an underwater Spoke; the
    ///      health of each Spoke is monitored off-chain.
    /// @return balance The total balance in USD, normalized to WAD (18 decimals)
    /// @custom:revert Errors.UnsupportedQuoteCurrencyFromOracle When the oracle returns a zero price for a reserve
    ///                with a position
    function balanceOf() external view override returns (uint256 balance) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;
        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address spoke;

        for (uint256 i; i < len; ++i) {
            if (!AaveV4SubstrateLib.isReserveSubstrate(substrates[i])) {
                continue;
            }

            spoke = AaveV4SubstrateLib.decode(substrates[i]).spoke;

            if (_isSpokeCounted(substrates, i, spoke)) {
                continue;
            }

            balance += _calculateSpokeBalance(substrates, i, spoke, priceOracleMiddleware);
        }
    }

    /// @notice Checks whether an earlier substrate already belongs to the same Spoke
    /// @dev The Spoke is valued once, at its first substrate, together with all its later substrates
    /// @param substrates_ All granted substrates of the market
    /// @param index_ Index of the substrate being evaluated; only earlier indices are compared
    /// @param spoke_ Spoke of the substrate being evaluated
    /// @return True if a Reserve substrate with a lower index has the same Spoke
    function _isSpokeCounted(bytes32[] memory substrates_, uint256 index_, address spoke_) private pure returns (bool) {
        for (uint256 j; j < index_; ++j) {
            if (
                AaveV4SubstrateLib.isReserveSubstrate(substrates_[j]) &&
                AaveV4SubstrateLib.decode(substrates_[j]).spoke == spoke_
            ) {
                return true;
            }
        }

        return false;
    }

    /// @notice Checks whether an earlier substrate already covers the same (spoke, reserveId) pair
    /// @param substrates_ All granted substrates of the market
    /// @param from_ First index to compare; earlier substrates belong to other Spokes
    /// @param index_ Index of the substrate being evaluated; only indices in [from_, index_) are compared
    /// @param spoke_ Spoke of the substrate being evaluated
    /// @param reserveId_ Reserve id of the substrate being evaluated
    /// @return True if a substrate in the compared range decodes to the same pair
    function _isDuplicate(
        bytes32[] memory substrates_,
        uint256 from_,
        uint256 index_,
        address spoke_,
        uint32 reserveId_
    ) private pure returns (bool) {
        AaveV4Substrate memory other;

        for (uint256 j = from_; j < index_; ++j) {
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

    /// @notice Calculates the value of one Spoke: F + max(0, C - D)
    /// @dev Walks the substrates from the first one of the Spoke and adds every granted reserve of the Spoke once.
    ///      An underwater Spoke (C below D) is worth F: its shortfall is written off by the Hub after a liquidation
    ///      and is not charged to the other Spokes of the vault (limited liability).
    /// @param substrates_ All granted substrates of the market
    /// @param firstIndex_ Index of the first Reserve substrate of the Spoke
    /// @param spoke_ The Aave V4 Spoke
    /// @param priceOracleMiddleware_ The price oracle middleware address
    /// @return The value of the Spoke in USD, normalized to WAD; never negative
    function _calculateSpokeBalance(
        bytes32[] memory substrates_,
        uint256 firstIndex_,
        address spoke_,
        address priceOracleMiddleware_
    ) private view returns (uint256) {
        uint256 len = substrates_.length;
        uint256 collateralValue;
        uint256 freeValue;
        uint256 debtValue;
        uint256 supplyValueOfReserve;
        uint256 debtValueOfReserve;
        bool usingAsCollateral;
        AaveV4Substrate memory substrate;

        for (uint256 j = firstIndex_; j < len; ++j) {
            if (!AaveV4SubstrateLib.isReserveSubstrate(substrates_[j])) {
                continue;
            }

            substrate = AaveV4SubstrateLib.decode(substrates_[j]);

            if (substrate.spoke != spoke_ || _isDuplicate(substrates_, firstIndex_, j, spoke_, substrate.reserveId)) {
                continue;
            }

            (supplyValueOfReserve, debtValueOfReserve, usingAsCollateral) = _calculateReserveValues(
                IAaveV4Spoke(spoke_),
                substrate.reserveId,
                priceOracleMiddleware_
            );

            if (usingAsCollateral) {
                collateralValue += supplyValueOfReserve;
            } else {
                freeValue += supplyValueOfReserve;
            }
            debtValue += debtValueOfReserve;
        }

        return collateralValue > debtValue ? freeValue + (collateralValue - debtValue) : freeValue;
    }

    /// @notice Calculates the supply value and the debt value of a single reserve of the Plasma Vault
    /// @dev The collateral flag (`getUserReserveStatus`) is read only for a reserve with supply. The supply value is
    ///      rounded down and the debt value up, so the value of a Spoke is never overstated by rounding.
    /// @param spoke_ The Aave V4 Spoke contract
    /// @param reserveId_ The reserve identifier within the Spoke
    /// @param priceOracleMiddleware_ The price oracle middleware address
    /// @return supplyValue The supplied assets in USD (WAD, rounded down); 0 when the reserve id is not listed on the
    ///         Spoke yet (a pre-granted id must not block balance updates of the whole vault)
    /// @return debtValue The total debt in USD (WAD, rounded up); 0 when the reserve id is not listed
    /// @return usingAsCollateral True when the supply of the reserve is enabled as collateral
    /// @custom:revert Errors.UnsupportedQuoteCurrencyFromOracle When the oracle returns a zero price
    function _calculateReserveValues(
        IAaveV4Spoke spoke_,
        uint256 reserveId_,
        address priceOracleMiddleware_
    ) private view returns (uint256 supplyValue, uint256 debtValue, bool usingAsCollateral) {
        if (reserveId_ >= spoke_.getReserveCount()) {
            return (0, 0, false);
        }

        uint256 supplyAssets = spoke_.getUserSuppliedAssets(reserveId_, address(this));
        uint256 debtAssets = spoke_.getUserTotalDebt(reserveId_, address(this));

        if (supplyAssets == 0 && debtAssets == 0) {
            return (0, 0, false);
        }

        address underlying = spoke_.getReserve(reserveId_).underlying;

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
            underlying
        );
        if (price == 0) {
            revert Errors.UnsupportedQuoteCurrencyFromOracle();
        }

        uint256 valueDecimals = IERC20Metadata(underlying).decimals() + priceDecimals;

        if (supplyAssets > 0) {
            (usingAsCollateral, ) = spoke_.getUserReserveStatus(reserveId_, address(this));
            supplyValue = IporMath.convertToWad(supplyAssets * price, valueDecimals);
        }

        debtValue = _convertToWadRoundUp(debtAssets * price, valueDecimals);
    }

    /// @notice Converts a value with `decimals_` decimals to WAD, rounding up
    /// @param value_ The value to convert
    /// @param decimals_ The decimals of the value
    /// @return The value in WAD, rounded up when decimals are dropped
    function _convertToWadRoundUp(uint256 value_, uint256 decimals_) private pure returns (uint256) {
        if (decimals_ > WAD_DECIMALS) {
            return Math.ceilDiv(value_, 10 ** (decimals_ - WAD_DECIMALS));
        }
        return value_ * 10 ** (WAD_DECIMALS - decimals_);
    }
}
