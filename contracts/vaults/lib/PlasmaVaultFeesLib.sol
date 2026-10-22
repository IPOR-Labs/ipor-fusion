// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {FeeManager} from "../../managers/fee/FeeManager.sol";
import {FeeAccount} from "../../managers/fee/FeeAccount.sol";

library PlasmaVaultFeesLib {
    using SafeCast for uint256;

    uint256 private constant FEE_PERCENTAGE_DECIMALS_MULTIPLIER = 1e4; /// @dev 10000 = 100% (2 decimal places for fee percentage)

    function prepareForAddPerformanceFee(
        uint256 totalSupply_,
        uint256 decimals_,
        uint256 decimalsOffset_,
        uint256 actualExchangeRate_
    ) internal returns (address recipient, uint256 feeShares) {
        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = PlasmaVaultLib.getPerformanceFeeData();

        (recipient, feeShares) = FeeManager(FeeAccount(feeData.feeAccount).FEE_MANAGER())
            .calculateAndUpdatePerformanceFee(
                actualExchangeRate_.toUint128(),
                totalSupply_,
                feeData.feeInPercentage,
                decimals_ - decimalsOffset_
            );
    }

    function prepareForRealizeDepositFee(
        uint256 mintedShares_
    ) internal view returns (address recipient, uint256 feeShares) {
        uint256 rate;
        (recipient, rate) = getDepositFeeRate();
        if (rate != 0) {
            /// @dev Same result as FeeManager.calculateDepositFee: mulDiv(shares, depositFee, 1e18)
            feeShares = Math.mulDiv(mintedShares_, rate, 1e18);
        }
    }

    /// @notice Returns the deposit fee recipient and the deposit fee rate (WAD, share of the gross shares)
    /// @dev Returns (address(0), 0) when no fee account is configured. FeeManager caps the rate at 10%.
    function getDepositFeeRate() internal view returns (address recipient, uint256 rate) {
        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = PlasmaVaultLib.getPerformanceFeeData();
        if (feeData.feeAccount == address(0)) {
            return (address(0), 0);
        }

        rate = FeeManager(FeeAccount(feeData.feeAccount).FEE_MANAGER()).getDepositFee();
        recipient = PlasmaVaultStorageLib.getWithdrawManager().manager;
    }

    /// @notice Deposit fee shares charged on top of `netShares_` so that the fee is a share of the gross amount
    /// @dev gross = net / (1 - rate), fee = gross - net, rounded up in the vault's favour (same base as deposit)
    function calculateMintDepositFee(uint256 netShares_) internal view returns (address recipient, uint256 feeShares) {
        uint256 rate;
        (recipient, rate) = getDepositFeeRate();
        if (rate != 0) {
            feeShares = Math.mulDiv(netShares_, rate, 1e18 - rate, Math.Rounding.Ceil);
        }
    }

    /// @notice Largest net share amount whose gross (net plus deposit fee) fits into `room_`
    function netSharesForRoom(uint256 room_) internal view returns (uint256) {
        (, uint256 rate) = getDepositFeeRate();
        if (rate == 0) {
            return room_;
        }
        /// @dev A rate of 100% or more (only possible with a FeeManager from before the 10% cap) cannot mint anything
        return rate >= 1e18 ? 0 : Math.mulDiv(room_, 1e18 - rate, 1e18);
    }

    /// @notice Gross amount that a withdraw fee of `withdrawFee_` (WAD) leaves as `net_`
    /// @dev Works for shares or assets: net / (1 - fee), rounded up. Same base as redeem: fee = gross * withdrawFee_.
    ///      A 100% fee leaves nothing to withdraw (max uint256), zero stays zero.
    function grossUpForWithdrawFee(uint256 net_, uint256 withdrawFee_) internal pure returns (uint256) {
        if (withdrawFee_ == 0 || net_ == 0) {
            return net_;
        }
        if (withdrawFee_ >= 1e18) {
            return type(uint256).max;
        }
        return Math.mulDiv(net_, 1e18, 1e18 - withdrawFee_, Math.Rounding.Ceil);
    }

    /// @notice Prepares data for management fee realization
    /// @dev Caller is responsible for advancing the fee clock (PlasmaVaultLib.updateManagementFeeData())
    ///      and for storing the unminted remainder in the pending management fee (IL-6959, IL-8318).
    /// @param totalAssetsBefore_ The total assets value before the operation
    /// @return recipient The address to receive management fees
    /// @return unrealizedFeeInUnderlying The unrealized fee amount in underlying tokens, including the pending fee
    function prepareForRealizeManagementFee(
        uint256 totalAssetsBefore_
    ) internal view returns (address recipient, uint256 unrealizedFeeInUnderlying) {
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultLib.getManagementFeeData();

        if (feeData.feeAccount == address(0)) {
            return (address(0), 0);
        }

        recipient = feeData.feeAccount;

        unrealizedFeeInUnderlying = getUnrealizedManagementFee(totalAssetsBefore_);
        // Note: Timestamp and pending fee updates are done by the caller (PlasmaVault._realizeManagementFee)
    }

    /// @notice Returns the management fee accrued but not yet minted
    /// @dev Pending fee (accrued earlier on the base it accrued against) plus the fee accrued on
    ///      `totalAssets_` since the last fee clock update
    function getUnrealizedManagementFee(uint256 totalAssets_) internal view returns (uint256) {
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultLib.getManagementFeeData();

        uint256 pendingFee = PlasmaVaultStorageLib.getPendingManagementFee();
        uint256 blockTimestamp = block.timestamp;

        if (
            feeData.feeInPercentage == 0 ||
            feeData.lastUpdateTimestamp == 0 ||
            blockTimestamp <= feeData.lastUpdateTimestamp
        ) {
            return pendingFee;
        }
        return
            pendingFee +
            Math.mulDiv(
                totalAssets_ * (blockTimestamp - feeData.lastUpdateTimestamp),
                feeData.feeInPercentage,
                365 days * FEE_PERCENTAGE_DECIMALS_MULTIPLIER
            );
    }
}
