// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IMidasDataFeed} from "./ext/IMidasDataFeed.sol";
import {IMidasDepositVault} from "./ext/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "./ext/IMidasRedemptionVault.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {MidasExecutorStorageLib} from "./lib/MidasExecutorStorageLib.sol";
import {MidasPendingRequestsStorageLib} from "./lib/MidasPendingRequestsStorageLib.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "./lib/MidasSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {MIDAS_REQUEST_STATUS_PENDING} from "./lib/MidasConstants.sol";

/// @title MidasBalanceFuse
/// @notice Balance fuse for Midas RWA integration, reporting NAV including held mTokens and pending requests
/// @dev Reports total balance in USD (18 decimals) across four components:
///      A) mTokens held by PlasmaVault (price read from deposit vault's mTokenDataFeed)
///      B) Pending deposit requests (USDC in transit to Midas)
///      C) Pending redemption requests (mTokens in transit to Midas)
///      D) Executor balance (mTokens and assets held by executor during async operations)
///      All addresses (mTokens, depositVaults, redemptionVaults) are read from market substrates.
///      Pending request IDs are tracked via MidasPendingRequestsStorageLib.
contract MidasBalanceFuse is IMarketBalanceFuse {
    error MTokenPriceIsZero(address mToken);
    error MidasBalanceFusePriceOracleNotSet();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        MARKET_ID = marketId_;
        VERSION = address(this);
    }

    /// @notice Calculate total balance of Midas holdings in USD (18 decimals)
    /// @dev Sums four components:
    ///      A) For each unique mToken (resolved via deposit vaults): held balance * price
    ///      B) Sum of pending deposit USD amounts (status == Pending only)
    ///      C) Sum of pending redemption mToken amounts * mToken price (status == Pending only)
    ///      D) Executor balance: mTokens and assets held by executor during async operations
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

        // Parse substrates to extract depositVaults, redemptionVaults, and assets
        address[] memory depositVaults = new address[](substratesLength);
        address[] memory redemptionVaults = new address[](substratesLength);
        address[] memory assets = new address[](substratesLength);
        uint256 depositVaultsCount;
        uint256 redemptionVaultsCount;
        uint256 assetsCount;

        MidasSubstrate memory substrate;
        for (uint256 i; i < substratesLength; ++i) {
            substrate = MidasSubstrateLib.bytes32ToSubstrate(substrates[i]);

            if (substrate.substrateType == MidasSubstrateType.DEPOSIT_VAULT) {
                depositVaults[depositVaultsCount] = substrate.substrateAddress;
                ++depositVaultsCount;
            } else if (substrate.substrateType == MidasSubstrateType.REDEMPTION_VAULT) {
                redemptionVaults[redemptionVaultsCount] = substrate.substrateAddress;
                ++redemptionVaultsCount;
            } else if (substrate.substrateType == MidasSubstrateType.ASSET) {
                assets[assetsCount] = substrate.substrateAddress;
                ++assetsCount;
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
                if (mTokenPrice == 0) revert MTokenPriceIsZero(mToken);
                mTokens[uniqueMTokenCount] = mToken;
                mTokenPrices[uniqueMTokenCount] = mTokenPrice;
                ++uniqueMTokenCount;
            }
        }

        // Component A: mTokens held by PlasmaVault
        uint256 mTokenBalance;
        for (uint256 i; i < uniqueMTokenCount; ++i) {
            mTokenBalance = IERC20(mTokens[i]).balanceOf(address(this));
            if (mTokenBalance > 0) {
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

        // Component D: Executor balance (mTokens and assets held during async operations)
        balanceValue += _calculateExecutorBalance(mTokens, mTokenPrices, uniqueMTokenCount, assets, assetsCount);
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
        uint256[] memory requestIds;
        uint256 idsLength;
        IMidasDepositVault.Request memory req;
        address depositVault;
        for (uint256 i; i < count_; ++i) {
            depositVault = depositVaults_[i];
            requestIds = MidasPendingRequestsStorageLib.getPendingDepositsForVault(depositVault);

            idsLength = requestIds.length;
            for (uint256 j; j < idsLength; ++j) {
                req = IMidasDepositVault(depositVault).mintRequests(requestIds[j]);

                // Only count Pending requests
                if (req.status == MIDAS_REQUEST_STATUS_PENDING) {
                    // depositedUsdAmount is in 18 decimals
                    pendingValue += req.depositedUsdAmount;
                }
            }
        }
    }

    /// @dev Calculate total USD value of assets held by the MidasExecutor
    ///      Counts two sub-components:
    ///      D.a) mTokens on executor (from approved deposits) — valued using pre-resolved mToken prices
    ///      D.b) Assets on executor (from approved redemptions, e.g. USDC) — valued using PriceOracleMiddleware
    /// @param mTokens_ Array of unique mToken addresses (pre-resolved from deposit vaults)
    /// @param mTokenPrices_ Array of mToken prices corresponding to mTokens_ (18 decimals)
    /// @param mTokenCount_ Number of valid entries in mTokens_/mTokenPrices_
    /// @param assets_ Array of asset addresses from ASSET substrates (e.g., USDC)
    /// @param assetsCount_ Number of valid entries in assets_
    /// @return executorValue Total executor balance value in USD (18 decimals)
    function _calculateExecutorBalance(
        address[] memory mTokens_,
        uint256[] memory mTokenPrices_,
        uint256 mTokenCount_,
        address[] memory assets_,
        uint256 assetsCount_
    ) private view returns (uint256 executorValue) {
        address executor = MidasExecutorStorageLib.getExecutor();
        if (executor == address(0)) {
            return 0;
        }

        // D.a) mTokens on executor (from approved deposits)
        uint256 mTokenBalance;
        for (uint256 i; i < mTokenCount_; ++i) {
            mTokenBalance = IERC20(mTokens_[i]).balanceOf(executor);
            if (mTokenBalance > 0) {
                // mToken has 18 decimals, mTokenPrice has 18 decimals
                // mTokenBalance * mTokenPrice => 36 decimals, convert to 18
                executorValue += IporMath.convertToWad(mTokenBalance * mTokenPrices_[i], 36);
            }
        }

        // D.b) Assets on executor (from approved redemptions, e.g. USDC)
        // Uses PriceOracleMiddleware for proper USD valuation
        if (assetsCount_ > 0) {
            address priceOracle = PlasmaVaultLib.getPriceOracleMiddleware();
            if (priceOracle == address(0)) revert MidasBalanceFusePriceOracleNotSet();
            uint256 assetBalance;
            for (uint256 i; i < assetsCount_; ++i) {
                assetBalance = IERC20(assets_[i]).balanceOf(executor);
                if (assetBalance > 0) {
                    (uint256 assetPrice, uint256 assetPriceDecimals) =
                        IPriceOracleMiddleware(priceOracle).getAssetPrice(assets_[i]);
                    // balance (asset decimals) * price (oracle decimals) → convert combined decimals to WAD (18)
                    uint256 assetDecimals = IERC20Metadata(assets_[i]).decimals();
                    executorValue += IporMath.convertToWad(assetBalance * assetPrice, assetDecimals + assetPriceDecimals);
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
        uint256[] memory requestIds;
        uint256 idsLength;
        address redemptionVault;
        address redeemMToken;
        uint256 mTokenPrice;
        IMidasRedemptionVault.Request memory req;
        for (uint256 i; i < redemptionCount_; ++i) {
            redemptionVault = redemptionVaults_[i];
            requestIds = MidasPendingRequestsStorageLib.getPendingRedemptionsForVault(redemptionVault);

            idsLength = requestIds.length;
            if (idsLength > 0) {
                // Look up the mToken price from the pre-resolved arrays
                redeemMToken = IMidasRedemptionVault(redemptionVault).mToken();
                mTokenPrice = 0;
                for (uint256 k; k < mTokenCount_; ++k) {
                    if (mTokens_[k] == redeemMToken) {
                        mTokenPrice = mTokenPrices_[k];
                        break;
                    }
                }
                if (mTokenPrice == 0) revert MTokenPriceIsZero(redeemMToken);

                for (uint256 j; j < idsLength; ++j) {
                    req = IMidasRedemptionVault(redemptionVault).redeemRequests(requestIds[j]);

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
