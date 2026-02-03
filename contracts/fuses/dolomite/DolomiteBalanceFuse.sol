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
    error DolomiteBalanceFuseNegativeBalance();

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
    /// @return The total balance in USD normalized to WAD
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        int256 balanceTemp;
        address plasmaVault = address(this);
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        DolomiteSubstrate memory substrate;
        uint256 dolomiteMarketId;
        IDolomiteMargin.Wei memory balance;

        for (uint256 i; i < len; ++i) {
            substrate = DolomiteFuseLib.bytes32ToSubstrate(substrates[i]);

            if (substrate.asset == address(0)) {
                revert DolomiteBalanceFuseInvalidSubstrateAsset();
            }

            dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(substrate.asset);

            IDolomiteMargin.AccountInfo memory accountInfo = IDolomiteMargin.AccountInfo({
                owner: plasmaVault,
                number: uint256(substrate.subAccountId)
            });

            balance = IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(accountInfo, dolomiteMarketId);

            if (balance.sign) {
                balanceTemp += _convertToUsd(priceOracleMiddleware, substrate.asset, balance.value).toInt256();
            } else if (balance.value > 0) {
                balanceTemp -= _convertToUsd(priceOracleMiddleware, substrate.asset, balance.value).toInt256();
            }
        }

        if (balanceTemp < 0) {
            revert DolomiteBalanceFuseNegativeBalance();
        }

        return uint256(balanceTemp);
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
