// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IMidasDataFeed} from "./ext/IMidasDataFeed.sol";
import {IMidasDepositVault} from "./ext/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "./ext/IMidasRedemptionVault.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {MidasPendingRequestsStorageLib} from "./lib/MidasPendingRequestsStorageLib.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "./lib/MidasSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @dev Midas request status constants
uint8 constant MIDAS_REQUEST_STATUS_PENDING = 0;

/// @title MidasBalanceFuse
/// @notice Balance fuse for Midas RWA integration, reporting NAV including held mTokens and pending requests
/// @dev Reports total balance in USD (18 decimals) across three components:
///      A) mTokens held by PlasmaVault (price read from deposit vault's mTokenDataFeed)
///      B) Pending deposit requests (USDC in transit to Midas)
///      C) Pending redemption requests (mTokens in transit to Midas)
///      All addresses (mTokens, depositVaults, redemptionVaults) are read from market substrates.
///      Pending request IDs are tracked via MidasPendingRequestsStorageLib.
contract MidasBalanceFuse is IMarketBalanceFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        MARKET_ID = marketId_;
        VERSION = address(this);
    }

    /// @notice Calculate total balance of Midas holdings in USD (18 decimals)
    /// @dev Sums three components:
    ///      A) For each unique mToken (resolved via deposit vaults): held balance * price
    ///      B) Sum of pending deposit USD amounts (status == Pending only)
    ///      C) Sum of pending redemption mToken amounts * mToken price (status == Pending only)
    ///      mToken addresses and prices are resolved from deposit vault substrates via
    ///      mToken() and mTokenDataFeed().getDataInBase18(). Each mToken is counted only once
    ///      even if multiple deposit vaults reference the same mToken.
    /// @return balanceValue Total balance in USD with 18 decimals
    function balanceOf() external view override returns (uint256 balanceValue) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 substratesLength = substrates.length;
        if (substratesLength == 0) {
            return 0;
        }

        // Parse substrates to extract depositVaults and redemptionVaults
        address[] memory depositVaults = new address[](substratesLength);
        address[] memory redemptionVaults = new address[](substratesLength);
        uint256 depositVaultsCount;
        uint256 redemptionVaultsCount;

        for (uint256 i; i < substratesLength; ++i) {
            MidasSubstrate memory substrate = MidasSubstrateLib.bytes32ToSubstrate(substrates[i]);

            if (substrate.substrateType == MidasSubstrateType.DEPOSIT_VAULT) {
                depositVaults[depositVaultsCount] = substrate.substrateAddress;
                unchecked {
                    ++depositVaultsCount;
                }
            } else if (substrate.substrateType == MidasSubstrateType.REDEMPTION_VAULT) {
                redemptionVaults[redemptionVaultsCount] = substrate.substrateAddress;
                unchecked {
                    ++redemptionVaultsCount;
                }
            }
        }

        // Build deduplicated (mToken, price) pairs from deposit vaults.
        // Each deposit vault knows its mToken via mToken() and its price feed via mTokenDataFeed().
        // Multiple deposit vaults may reference the same mToken — we only price it once.
        address[] memory mTokens = new address[](depositVaultsCount);
        uint256[] memory mTokenPrices = new uint256[](depositVaultsCount);
        uint256 uniqueMTokenCount;

        for (uint256 i; i < depositVaultsCount; ++i) {
            address mToken = IMidasDepositVault(depositVaults[i]).mToken();

            // Check if this mToken was already processed
            bool alreadySeen;
            for (uint256 k; k < uniqueMTokenCount; ++k) {
                if (mTokens[k] == mToken) {
                    alreadySeen = true;
                    break;
                }
            }

            if (!alreadySeen) {
                uint256 mTokenPrice = IMidasDataFeed(IMidasDepositVault(depositVaults[i]).mTokenDataFeed())
                    .getDataInBase18();
                mTokens[uniqueMTokenCount] = mToken;
                mTokenPrices[uniqueMTokenCount] = mTokenPrice;
                unchecked {
                    ++uniqueMTokenCount;
                }
            }
        }

        // Component A: mTokens held by PlasmaVault
        for (uint256 i; i < uniqueMTokenCount; ++i) {
            uint256 mTokenBalance = IERC20(mTokens[i]).balanceOf(address(this));
            if (mTokenBalance > 0 && mTokenPrices[i] > 0) {
                // mToken has 18 decimals, mTokenPrice has 18 decimals
                // mTokenBalance * mTokenPrice => 36 decimals, convert to 18
                balanceValue += IporMath.convertToWad(mTokenBalance * mTokenPrices[i], 36);
            }
        }

        // Component B: Pending deposit requests (from substrates + storage)
        balanceValue += _calculatePendingDepositValue(depositVaults, depositVaultsCount);

        // Component C: Pending redemption requests (from substrates + storage)
        balanceValue += _calculatePendingRedemptionValue(
            redemptionVaults, redemptionVaultsCount, mTokens, mTokenPrices, uniqueMTokenCount
        );
    }

    /// @dev Calculate total USD value of pending deposit requests
    ///      Only counts requests with status == Pending (0)
    /// @param depositVaults_ Array of deposit vault addresses from substrates
    /// @param count_ Number of valid deposit vaults in the array
    /// @return pendingValue Total pending deposit value in USD (18 decimals)
    function _calculatePendingDepositValue(
        address[] memory depositVaults_,
        uint256 count_
    ) private view returns (uint256 pendingValue) {
        for (uint256 i; i < count_; ++i) {
            address depositVault = depositVaults_[i];
            uint256[] memory requestIds = MidasPendingRequestsStorageLib.getPendingDepositsForVault(depositVault);

            uint256 idsLength = requestIds.length;
            for (uint256 j; j < idsLength; ++j) {
                IMidasDepositVault.Request memory req = IMidasDepositVault(depositVault).mintRequests(requestIds[j]);

                // Only count Pending requests
                if (req.status == MIDAS_REQUEST_STATUS_PENDING) {
                    // depositedUsdAmount is in 18 decimals
                    pendingValue += req.depositedUsdAmount;
                }
            }
        }
    }

    /// @dev Calculate total USD value of pending redemption requests
    ///      Only counts requests with status == Pending (0)
    ///      Uses pre-resolved mToken prices to avoid redundant external calls
    /// @param redemptionVaults_ Array of redemption vault addresses from substrates
    /// @param redemptionCount_ Number of valid redemption vaults in the array
    /// @param mTokens_ Array of unique mToken addresses (pre-resolved from deposit vaults)
    /// @param mTokenPrices_ Array of mToken prices corresponding to mTokens_ (18 decimals)
    /// @param mTokenCount_ Number of valid entries in mTokens_/mTokenPrices_
    /// @return pendingValue Total pending redemption value in USD (18 decimals)
    function _calculatePendingRedemptionValue(
        address[] memory redemptionVaults_,
        uint256 redemptionCount_,
        address[] memory mTokens_,
        uint256[] memory mTokenPrices_,
        uint256 mTokenCount_
    ) private view returns (uint256 pendingValue) {
        for (uint256 i; i < redemptionCount_; ++i) {
            address redemptionVault = redemptionVaults_[i];
            uint256[] memory requestIds = MidasPendingRequestsStorageLib.getPendingRedemptionsForVault(redemptionVault);

            uint256 idsLength = requestIds.length;
            if (idsLength > 0) {
                // Look up the mToken price from the pre-resolved arrays
                address redeemMToken = IMidasRedemptionVault(redemptionVault).mToken();
                uint256 mTokenPrice;
                for (uint256 k; k < mTokenCount_; ++k) {
                    if (mTokens_[k] == redeemMToken) {
                        mTokenPrice = mTokenPrices_[k];
                        break;
                    }
                }

                for (uint256 j; j < idsLength; ++j) {
                    IMidasRedemptionVault.Request memory req =
                        IMidasRedemptionVault(redemptionVault).redeemRequests(requestIds[j]);

                    // Only count Pending requests
                    if (req.status == MIDAS_REQUEST_STATUS_PENDING) {
                        // amountMToken is in 18 decimals, mTokenPrice is in 18 decimals
                        // amountMToken * mTokenPrice => 36 decimals, convert to 18
                        pendingValue += IporMath.convertToWad(req.amountMToken * mTokenPrice, 36);
                    }
                }
            }
        }
    }
}
