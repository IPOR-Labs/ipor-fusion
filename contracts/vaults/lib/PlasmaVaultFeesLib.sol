// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {FeeManager, FeeManagerInitData} from "../../managers/fee/FeeManager.sol";
import {FeeAccount} from "../../managers/fee/FeeAccount.sol";
import {FeeManagerStorageLib} from "../../managers/fee/FeeManagerStorageLib.sol";
import {FeeConfig, FeeManagerData, FeeManagerFactory, RecipientFee} from "../../managers/fee/FeeManagerFactory.sol";

/// @title PlasmaVaultFeesLib
/// @notice Fee helpers of PlasmaVault
/// @dev Linked library (EIP-170 size round of IL-9590): `createFeeManager` and `pendingPerformanceFeeShares` are
///      public, so PlasmaVault calls them by DELEGATECALL and runs them in its own context (address(this) is the
///      vault, storage is the vault's ERC-7201 storage, external calls are made by the vault, events are emitted by
///      the vault). The library must be deployed and linked into PlasmaVault, like PlasmaVaultMarketsLib. The other
///      functions are internal and are compiled into PlasmaVault. PlasmaVault declares the errors and events of the
///      public functions again, so that its ABI still lists them.
library PlasmaVaultFeesLib {
    using SafeCast for uint256;

    uint256 private constant FEE_PERCENTAGE_DECIMALS_MULTIPLIER = 1e4; /// @dev 10000 = 100% (2 decimal places for fee percentage)

    /// @notice Thrown when the FeeManager created for a new vault does not report the performance fee rate scale of
    ///         this build
    /// @dev IL-9601 (D-068): the FeeManager has no `HIGH_WATER_MARK_SCALE()` (built before IL-9601), the call returns
    ///      no 32-byte word, or the scale differs from `FeeManagerStorageLib.HIGH_WATER_MARK_SCALE`
    /// @param feeManager The FeeManager address the factory returned
    error FeeManagerScaleMismatch(address feeManager);

    /// @notice Reverts unless the FeeManager reports the performance fee rate scale that this vault passes
    /// @dev IL-9601 (Olympix M11, D-068): a vault of this build passes the rate in the HIGH_WATER_MARK_SCALE (1e12)
    ///      unit. A FeeManager built before IL-9601 (an old FeeManagerFactory paired with a new vault by a deploy-order
    ///      mistake) has no `HIGH_WATER_MARK_SCALE()` and would compare the scaled rate with an unscaled high-water
    ///      mark, so its first crystallization would charge roughly a fifth to a quarter of the supply. Called once,
    ///      when the vault creates its FeeManager during initialization (`createFeeManager`); nothing runs on deposit,
    ///      withdraw, redeem or transfer. The call is a staticcall whose failure, short return data or wrong value
    ///      all revert with `FeeManagerScaleMismatch`. Checking `HIGH_WATER_MARK_SCALE()` is enough for the IL-9624
    ///      views too: every FeeManager of this release has both `HIGH_WATER_MARK_SCALE()` and
    ///      `pendingPerformanceFeeShares`.
    /// @param feeManager_ FeeManager address returned by the FeeManagerFactory
    function requireFeeManagerScale(address feeManager_) internal view {
        (bool success, bytes memory data) = feeManager_.staticcall(abi.encodeWithSignature("HIGH_WATER_MARK_SCALE()"));
        if (
            !success || data.length != 32 || abi.decode(data, (uint256)) != FeeManagerStorageLib.HIGH_WATER_MARK_SCALE
        ) {
            revert FeeManagerScaleMismatch(feeManager_);
        }
    }

    /// @notice Deploys the FeeManager of a new vault, checks its performance fee rate scale and stores the fee
    ///         accounts and rates the FeeManagerFactory returned
    /// @dev Called once, from PlasmaVault initialization (`proxyInitialize`), by DELEGATECALL: `address(this)` is the
    ///      vault, so the FeeManager is created for the vault and the fee data is written to the vault's storage.
    ///      Moved here from PlasmaVault unchanged (EIP-170 size round of IL-9590), in the same order: deploy the
    ///      FeeManager without extra recipients, `requireFeeManagerScale` (IL-9601, D-068), then the performance fee
    ///      and the management fee configuration (`PlasmaVaultLib.configurePerformanceFee`,
    ///      `PlasmaVaultLib.configureManagementFee`, which emit PerformanceFeeDataConfigured and
    ///      ManagementFeeDataConfigured). The caller starts the management fee clock afterwards.
    /// @param feeConfig_ Fee configuration of the vault initialization data
    /// @param accessManager_ Access manager of the vault, the initial authority of the FeeManager
    function createFeeManager(FeeConfig memory feeConfig_, address accessManager_) public {
        FeeManagerData memory feeManagerData = FeeManagerFactory(feeConfig_.feeFactory).deployFeeManager(
            FeeManagerInitData({
                initialAuthority: accessManager_,
                plasmaVault: address(this),
                iporDaoManagementFee: feeConfig_.iporDaoManagementFee,
                iporDaoPerformanceFee: feeConfig_.iporDaoPerformanceFee,
                iporDaoFeeRecipientAddress: feeConfig_.iporDaoFeeRecipientAddress,
                recipientManagementFees: new RecipientFee[](0),
                recipientPerformanceFees: new RecipientFee[](0)
            })
        );

        /// @dev IL-9601 (D-068): one-time pairing check, a FeeManager of an older build reverts here
        requireFeeManagerScale(feeManagerData.feeManager);

        PlasmaVaultLib.configurePerformanceFee(feeManagerData.performanceFeeAccount, feeManagerData.performanceFee);
        PlasmaVaultLib.configureManagementFee(feeManagerData.managementFeeAccount, feeManagerData.managementFee);
    }

    /// @notice Shares whose value is the performance fee rate: 10 ** decimals() times FeeManager.HIGH_WATER_MARK_SCALE
    /// @dev IL-9601 (Olympix M11): the vault converts this amount with its own net conversion, so the rate passed to
    ///      the FeeManager is one mulDiv of the same terms as the net share price, (10 ** decimals() * 1e12) *
    ///      (G + 1) / (S + V + scale), and carries 1e12 more precision than convertToAssets(10 ** decimals()) instead
    ///      of scaling that rounded value. The FeeManager stores the high-water mark in the same unit.
    /// @param decimals_ Vault share decimals
    /// @return Share amount converted to the performance fee rate
    function performanceFeeRateShares(uint256 decimals_) internal pure returns (uint256) {
        return 10 ** decimals_ * FeeManagerStorageLib.HIGH_WATER_MARK_SCALE;
    }

    /// @notice Calls the FeeManager to size the performance fee and store the high-water mark
    /// @param actualExchangeRate_ Net share rate in the HWM unit (`performanceFeeRateShares` converted by the vault),
    ///        at most type(uint128).max (the vault skips the fee above it)
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

    /// @notice Performance fee shares that withdraw and redeem would mint now, before they pay
    /// @dev IL-9624 (Olympix M34): read-only twin of `prepareForAddPerformanceFee` for previewRedeem, previewWithdraw,
    ///      maxWithdraw and, with released request shares (IL-9624 follow-up), maxRedeem. Takes the rate and the supply
    ///      the vault's `_addPerformanceFee` would pass after the management fee realization (supply with the virtual
    ///      management fee shares, rate converted on it) and asks the FeeManager for the shares without writing the
    ///      high-water mark. Returns 0 where `_addPerformanceFee` mints nothing: a rate above type(uint128).max (the
    ///      vault skips the fee) and a zero fee rate (the FeeManager sizes zero shares). A missing fee account (not
    ///      reachable after initialization) also prices no fee, so the views do not revert on it.
    /// @dev Public (EIP-170 size round of IL-9590): PlasmaVault calls it by DELEGATECALL, so the FeeManager is read
    ///      by the vault, as before. Reached only from the views, never from deposit, mint, withdraw or redeem.
    /// @param actualExchangeRate_ Net share rate in the high-water-mark unit (`performanceFeeRateShares` converted
    ///        by the vault on totalSupply_)
    /// @param totalSupply_ Minted supply plus the virtual management fee shares
    /// @return Performance fee shares the vault would mint on top of totalSupply_
    function pendingPerformanceFeeShares(
        uint256 actualExchangeRate_,
        uint256 totalSupply_
    ) public view returns (uint256) {
        if (actualExchangeRate_ > type(uint128).max) {
            return 0;
        }

        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = PlasmaVaultLib.getPerformanceFeeData();
        if (feeData.feeAccount == address(0) || feeData.feeInPercentage == 0) {
            return 0;
        }

        return
            FeeManager(FeeAccount(feeData.feeAccount).FEE_MANAGER()).pendingPerformanceFeeShares(
                uint128(actualExchangeRate_),
                totalSupply_,
                feeData.feeInPercentage
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
    /// @dev IL-8870 (gas): the vault calls this on every conversion, so the ManagementFeeData slot is read once
    ///      here (fee account, rate and fee clock in one storage word) and passed on, instead of being read again
    ///      by getUnrealizedManagementFee. Without a fee account it returns (address(0), 0) before reading the
    ///      pending fee, as before.
    /// @param totalAssetsBefore_ The total assets value before the operation
    /// @return recipient The address to receive management fees
    /// @return unrealizedFeeInUnderlying The unrealized fee amount in underlying tokens, including the pending fee
    function prepareForRealizeManagementFee(
        uint256 totalAssetsBefore_
    ) internal view returns (address recipient, uint256 unrealizedFeeInUnderlying) {
        PlasmaVaultStorageLib.ManagementFeeData storage feeData = PlasmaVaultStorageLib.getManagementFeeData();
        recipient = feeData.feeAccount;
        uint256 feeInPercentage = feeData.feeInPercentage;
        uint256 lastUpdateTimestamp = feeData.lastUpdateTimestamp;

        if (recipient != address(0)) {
            unrealizedFeeInUnderlying = _unrealizedManagementFee(
                feeInPercentage,
                lastUpdateTimestamp,
                totalAssetsBefore_
            );
        }
        // Note: Timestamp and pending fee updates are done by the caller (PlasmaVault._realizeManagementFee)
    }

    /// @notice Management fee shares whose value after the mint equals the accrued management fee (IL-8870, D-002)
    /// @dev V = floor(min(F, G) * (S + shareScale) / (G - min(F, G) + 1)). After V is minted on top of S the share
    ///      price is (G + 1) / (S + V + shareScale), so the V shares are worth F less the floored fraction of one
    ///      share, and the price before the mint, priced with the virtual supply S + V, equals the price after it.
    ///      The vault uses this one function both for the virtual fee shares in its views and for the mint in
    ///      `_realizeManagementFee`, so both sides use the same integers. F is clamped to G (a pending fee above the
    ///      assets after a loss), which keeps the denominator at least 1. Zero when there is no fee, no supply
    ///      (nobody to charge) or no assets.
    /// @param fee_ Accrued management fee F in underlying (pending fee plus the accrual since the fee clock)
    /// @param supply_ Minted share supply S before the fee mint
    /// @param grossTotalAssets_ Gross total assets G (the fee is not deducted)
    /// @param shareScale_ Vault share scale multiplier (10 ** decimals offset)
    /// @return Management fee shares V
    function managementFeeShares(
        uint256 fee_,
        uint256 supply_,
        uint256 grossTotalAssets_,
        uint256 shareScale_
    ) internal pure returns (uint256) {
        if (fee_ == 0 || supply_ == 0 || grossTotalAssets_ == 0) {
            return 0;
        }
        if (fee_ > grossTotalAssets_) {
            fee_ = grossTotalAssets_;
        }
        return Math.mulDiv(fee_, supply_ + shareScale_, grossTotalAssets_ - fee_ + 1);
    }

    /// @notice Returns the management fee accrued but not yet minted
    /// @dev Pending fee (accrued earlier on the base it accrued against) plus the fee accrued on
    ///      `totalAssets_` since the last fee clock update
    function getUnrealizedManagementFee(uint256 totalAssets_) internal view returns (uint256) {
        PlasmaVaultStorageLib.ManagementFeeData storage feeData = PlasmaVaultStorageLib.getManagementFeeData();
        return _unrealizedManagementFee(feeData.feeInPercentage, feeData.lastUpdateTimestamp, totalAssets_);
    }

    /// @notice Pending management fee plus the accrual on `totalAssets_` since the fee clock
    /// @dev IL-8870 (gas): takes the rate and the fee clock already read from the ManagementFeeData slot. With a
    ///      zero rate, an unset clock or the clock at the current block (right after a realization in the same
    ///      call) it returns the pending fee without the accrual math.
    /// @param feeInPercentage_ Management fee rate (10000 = 100%)
    /// @param lastUpdateTimestamp_ Fee clock (last realization timestamp)
    /// @param totalAssets_ Total assets the fee accrues on
    /// @return Pending fee plus the accrual since the fee clock
    function _unrealizedManagementFee(
        uint256 feeInPercentage_,
        uint256 lastUpdateTimestamp_,
        uint256 totalAssets_
    ) private view returns (uint256) {
        uint256 pendingFee = PlasmaVaultStorageLib.getPendingManagementFee();
        uint256 blockTimestamp = block.timestamp;

        if (feeInPercentage_ == 0 || lastUpdateTimestamp_ == 0 || blockTimestamp <= lastUpdateTimestamp_) {
            return pendingFee;
        }
        return
            pendingFee +
            Math.mulDiv(
                totalAssets_ * (blockTimestamp - lastUpdateTimestamp_),
                feeInPercentage_,
                365 days * FEE_PERCENTAGE_DECIMALS_MULTIPLIER
            );
    }
}
