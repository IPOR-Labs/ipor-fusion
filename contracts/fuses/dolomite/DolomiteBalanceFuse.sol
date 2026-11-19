// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IDolomiteMargin} from "./ext/IDolomiteMargin.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "./DolomiteFuseLib.sol";

/// @title DolomiteBalanceFuse
/// @notice Balance fuse that calculates the PlasmaVault's total position value in Dolomite protocol
/// @author IPOR Labs
contract DolomiteBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeCast for int256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable DOLOMITE_MARGIN;

    error DolomiteBalanceFuseInvalidMarketId();
    error DolomiteBalanceFuseInvalidDolomiteMargin();
    error DolomiteBalanceFuseInvalidSubstrateAsset();

    constructor(uint256 marketId_, address dolomiteMargin_) {
        if (marketId_ == 0) {
            revert DolomiteBalanceFuseInvalidMarketId();
        }
        if (dolomiteMargin_ == address(0)) {
            revert DolomiteBalanceFuseInvalidDolomiteMargin();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        DOLOMITE_MARGIN = dolomiteMargin_;
    }

    /// @notice Calculates total value of PlasmaVault's Dolomite positions in USD (18 decimals)
    /// @dev Every Dolomite account number is a separate margin account: collateralization and liquidation are
    ///      evaluated per `(owner, number)`, and a liquidation of an account number can seize every positive balance
    ///      of that number. So each account number is valued as `max(0, sum(supply) - sum(debt))` and the account
    ///      numbers are added up: the shortfall of one underwater account number is never charged to another one,
    ///      and the result is never negative and never reverts.
    ///      The accounts are accumulated in one pass over the substrates, which are grouped by `subAccountId`
    ///      (up to 256 account numbers) and every account number is added once.
    /// @dev IMPORTANT: Substrates must not contain duplicates for the same (asset, subAccountId) pair
    ///      with different canBorrow values, e.g. (USDC, subAccount=0, canBorrow=false) and
    ///      (USDC, subAccount=0, canBorrow=true). This would cause double-counting of the balance.
    /// @return The total balance in USD normalized to WAD (sum over account numbers of the non-negative net value)
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        // net value of every account number (index = subAccountId), accumulated in one pass
        int256[256] memory accountNet;
        address plasmaVault = address(this);
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        IDolomiteMargin dolomiteMargin = IDolomiteMargin(DOLOMITE_MARGIN);

        DolomiteSubstrate memory substrate;
        uint256 dolomiteMarketId;
        IDolomiteMargin.Wei memory balance;
        IDolomiteMargin.AccountInfo memory accountInfo;

        for (uint256 i; i < len; ++i) {
            substrate = DolomiteFuseLib.bytes32ToSubstrate(substrates[i]);

            if (substrate.asset == address(0)) {
                revert DolomiteBalanceFuseInvalidSubstrateAsset();
            }

            dolomiteMarketId = dolomiteMargin.getMarketIdByTokenAddress(substrate.asset);

            accountInfo = IDolomiteMargin.AccountInfo({owner: plasmaVault, number: uint256(substrate.subAccountId)});

            balance = dolomiteMargin.getAccountWei(accountInfo, dolomiteMarketId);

            if (balance.sign) {
                accountNet[substrate.subAccountId] += _convertToUsd(
                    priceOracleMiddleware,
                    substrate.asset,
                    balance.value
                ).toInt256();
            } else if (balance.value > 0) {
                accountNet[substrate.subAccountId] -= _convertToUsd(
                    priceOracleMiddleware,
                    substrate.asset,
                    balance.value
                ).toInt256();
            }
        }

        // add every account number once: its slot is cleared after it is added
        int256 total;
        uint8 accountId;
        for (uint256 j; j < len; ++j) {
            accountId = DolomiteFuseLib.bytes32ToSubstrate(substrates[j]).subAccountId;
            if (accountNet[accountId] > 0) {
                total += accountNet[accountId];
            }
            accountNet[accountId] = 0;
        }

        return total.toUint256();
    }

    function _convertToUsd(
        address priceOracleMiddleware_,
        address asset_,
        uint256 amount_
    ) internal view returns (uint256) {
        if (amount_ == 0) return 0;

        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(asset_);

        return IporMath.convertToWad(amount_ * price, ERC20(asset_).decimals() + decimals);
    }
}
