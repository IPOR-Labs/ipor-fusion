// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientStorageLib} from "../../../transient_storage/TransientStorageLib.sol";

/// @title ReserveVaultBoostLib
/// @notice Boost of a member vault during a reserve vault exit: the transient slot that carries it, the formula that
///         sizes it and the USD conversion, rounded up, used by the reserve vault balance fuses
/// @dev Mechanism. When the reserve vault's shares in a member vault are worth less than its principal, the reserve vault
///      stores a temporary boost X for that member vault in its own transient storage, refreshes the member vault's boost
///      market, withdraws the principal, clears X and refreshes the boost market again. The member vault's boost balance
///      fuse reads X through the reserve vault's UniversalReader, which runs the read by delegatecall in the reserve vault,
///      so both the write and the read touch the reserve vault's transient storage.
/// @dev Slot derivation is immutable: the writer (code run for the reserve vault) and the reader (code run for the member
///      vault, delegated back into the reserve vault) must derive the same slot. Changing `BOOST_SLOT` or `boostSlot`
///      breaks every deployed pair of fuses, so a new derivation needs a new deployment of both sides together.
/// @dev One slot per member vault keeps every other member vault at zero while one of them is boosted. Reads and writes
///      go through `TransientStorageLib.tstore` and `TransientStorageLib.tload`; the value lives only for the current
///      transaction, and the writer clears it explicitly before the transaction ends.
/// @author IPOR Labs
library ReserveVaultBoostLib {
    /// @notice Thrown when the boost is computed for zero shares: no boost makes zero shares worth the principal
    error ReserveVaultBoostZeroShares();

    /// @notice Thrown when a non-zero amount is converted to USD with a zero price
    error ReserveVaultUsdConversionZeroPrice();

    /// @dev Base of the per member vault boost slots (transient storage)
    /// @dev Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.reserveVault.Boost")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant BOOST_SLOT = 0xc97b8eb9dc5c7a7eff86aa8aa6982f94f8d388267f2d547353bbfd09312d9e00;

    /// @dev Decimals of the USD values returned by balance fuses (WAD)
    uint256 private constant WAD_DECIMALS = 18;

    /// @notice Returns the transient slot that carries the boost of a member vault
    /// @dev `keccak256(abi.encode(memberVault_, BOOST_SLOT))`. Immutable, see the library notes.
    /// @param memberVault_ The member vault
    /// @return The transient storage slot of the boost for `memberVault_`
    function boostSlot(address memberVault_) internal pure returns (bytes32) {
        return keccak256(abi.encode(memberVault_, BOOST_SLOT));
    }

    /// @notice Stores the boost of a member vault in the transient storage of the current context
    /// @dev Called only by the reserve vault's supply fuse, which must clear the value with `clearBoost` in the same
    ///      exit.
    /// @param memberVault_ The member vault
    /// @param boost_ The boost, in the member vault's asset
    function setBoost(address memberVault_, uint256 boost_) internal {
        TransientStorageLib.tstore(boostSlot(memberVault_), bytes32(boost_));
    }

    /// @notice Clears the boost of a member vault in the transient storage of the current context
    /// @param memberVault_ The member vault
    function clearBoost(address memberVault_) internal {
        TransientStorageLib.tstore(boostSlot(memberVault_), bytes32(0));
    }

    /// @notice Returns the boost of a member vault from the transient storage of the current context
    /// @dev Returns the reserve vault's value only when run in the reserve vault's context (directly or through its
    ///      UniversalReader); in any other context it reads that context's own transient storage, normally zero.
    /// @param memberVault_ The member vault
    /// @return The boost, in the member vault's asset; zero outside an exit
    function getBoost(address memberVault_) internal view returns (uint256) {
        return uint256(TransientStorageLib.tload(boostSlot(memberVault_)));
    }

    /// @notice Computes the smallest boost that makes the reserve vault's shares in a member vault worth its principal
    /// @dev Let P = `principal_`, s = `shares_`, G = `totalAssets_`, D = `virtualSupply_`. The member vault values the
    ///      shares at floor(s * (G + 1) / D) (ERC-4626 conversion with one virtual asset and D = supply plus virtual
    ///      shares). The function returns the smallest X >= 0 with floor(s * (G + X + 1) / D) >= P, that is the smallest
    ///      amount the member vault has to add to its total assets, with its supply unchanged, so that all s shares can
    ///      withdraw P:
    ///      X = max(0, ceil(P * D / s) - (G + 1)), with `Math.mulDiv` rounding up.
    ///      Properties:
    ///      - X == 0 exactly when floor(s * (G + 1) / D) >= P (the position already covers the principal);
    ///      - X >= 1 whenever the position is worth less than the principal;
    ///      - with X - 1 instead of X the shares are worth less than P (the boost is tight).
    ///      Preconditions: `shares_` > 0 (reverts with `ReserveVaultBoostZeroShares` otherwise); `virtualSupply_` is
    ///      `IERC4626(memberVault).convertToShares(totalAssets_ + 1)` read from the member vault, which equals its supply
    ///      plus its virtual shares without assuming the decimals offset; all inputs come from the same state of the
    ///      member vault. The result is meaningful only for a position worth less than the principal; otherwise it is 0.
    ///      Reverts on arithmetic overflow.
    /// @param principal_ The principal P recorded for the member vault, in the member vault's asset
    /// @param shares_ The reserve vault's shares s in the member vault
    /// @param totalAssets_ The member vault's total assets G
    /// @param virtualSupply_ D = `convertToShares(totalAssets_ + 1)` of the member vault
    /// @return boost The boost X, in the member vault's asset
    function computeBoost(
        uint256 principal_,
        uint256 shares_,
        uint256 totalAssets_,
        uint256 virtualSupply_
    ) internal pure returns (uint256 boost) {
        if (shares_ == 0) {
            revert ReserveVaultBoostZeroShares();
        }

        uint256 requiredTotalAssetsPlusOne = Math.mulDiv(principal_, virtualSupply_, shares_, Math.Rounding.Ceil);
        uint256 totalAssetsPlusOne = totalAssets_ + 1;

        if (requiredTotalAssetsPlusOne > totalAssetsPlusOne) {
            unchecked {
                boost = requiredTotalAssetsPlusOne - totalAssetsPlusOne;
            }
        }
    }

    /// @notice Converts an asset amount to a USD value in WAD (18 decimals), rounded up, so that the vault books back
    ///         at least the amount
    /// @dev Computes ceil(amount * price * 10^18 / 10^(assetDecimals + priceDecimals)) with `Math.mulDiv` rounding up.
    ///      Why up: `PlasmaVaultMarketsLib.updateMarketsBalances` converts the USD value of a balance fuse back to the
    ///      underlying with floor divisions, booked = floor(floor(usd * 10^priceDecimals / price) / 10^(18 - assetDecimals)),
    ///      and for assetDecimals > 18 it multiplies floor(usd * 10^priceDecimals / price) by 10^(assetDecimals - 18).
    ///      A floor here would book one wei less than the amount whenever the price is not on the asset's grid.
    /// @dev Bounds for assetDecimals <= 18. Let q = price * 10^(18 - assetDecimals), the value of one asset wei in USD
    ///      WAD units multiplied by 10^priceDecimals. Then:
    ///      - booked >= amount, always;
    ///      - booked <= amount + ceil(10^priceDecimals / q) - 1, so the excess is below the asset value of one USD WAD
    ///        unit;
    ///      - precision domain: when q >= 10^priceDecimals (one asset wei is worth at least one USD WAD unit) the result
    ///        is exact, booked == amount. A 6-decimal asset is inside the domain at any price of at least 1e-12 USD.
    ///      Outside the domain no exact representation exists: an 18-decimal asset, amount 1 wei and price 0.1 USD book
    ///      10 wei.
    /// @dev Bounds for assetDecimals > 18. The vault books only multiples of g = 10^(assetDecimals - 18) wei, so the
    ///      amount is first rounded up to that grain, which adds a second quantisation step:
    ///      usd = ceil(ceil(amount / g) * price / 10^priceDecimals). Then:
    ///      - booked >= amount, always;
    ///      - booked <= ceil(amount / g) * g + (ceil(10^priceDecimals / price) - 1) * g;
    ///      - when price >= 10^priceDecimals the result is exact to the grain, booked == ceil(amount / g) * g.
    ///      A single rounding of the unscaled amount would not be enough: 24 decimals, amount 1.5e6 wei, price 3 USD
    ///      (8 decimals) would book 1e6 wei.
    /// @dev Sum amounts of the same asset before converting them: one conversion of the sum keeps the exactness inside
    ///      the precision domain, while a sum of separately rounded-up values can exceed the summed amount.
    /// @dev Returns 0 for a zero amount without checking the price; reverts with `ReserveVaultUsdConversionZeroPrice`
    ///      for a non-zero amount and a zero price, and on arithmetic overflow.
    /// @param amount_ The amount of the asset, in the asset's decimals
    /// @param price_ The USD price of one whole asset unit, in `priceDecimals_` decimals
    /// @param priceDecimals_ The decimals of `price_`
    /// @param assetDecimals_ The decimals of the asset
    /// @return The USD value in WAD, rounded up
    function convertToUsdWadRoundUp(
        uint256 amount_,
        uint256 price_,
        uint256 priceDecimals_,
        uint256 assetDecimals_
    ) internal pure returns (uint256) {
        if (amount_ == 0) {
            return 0;
        }

        if (price_ == 0) {
            revert ReserveVaultUsdConversionZeroPrice();
        }

        if (assetDecimals_ > WAD_DECIMALS) {
            uint256 amountInWad = Math.ceilDiv(amount_, 10 ** (assetDecimals_ - WAD_DECIMALS));
            return Math.mulDiv(amountInWad, price_, 10 ** priceDecimals_, Math.Rounding.Ceil);
        }

        return
            Math.mulDiv(
                amount_,
                price_ * 10 ** (WAD_DECIMALS - assetDecimals_),
                10 ** priceDecimals_,
                Math.Rounding.Ceil
            );
    }
}
