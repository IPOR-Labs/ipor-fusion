// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

import {PendleMarketV3} from "@pendle/core-v2/contracts/core/Market/v3/PendleMarketV3.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {SYUtils} from "@pendle/core-v2/contracts/core/StandardizedYield/SYUtils.sol";
struct TokensBalances {
    uint256 syTokenBalance;
    uint256 syTokenInAssetBalance;
    uint256 ptTokenBalance;
    uint256 ptTokenInAssetBalance;
    uint256 ytTokenBalance;
    uint256 ytTokenInAssetBalance;
}

// node_modules/@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol
/// @title Fuse Pendle Balance protocol responsible for calculating the balance of the Plasma Vault in the Pendle protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the Pendle Market IDs that are used in the Pendle protocol for a given MARKET_ID
contract PendleMarketsBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @return The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        // bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        // return balanceOf(substrates, address(this));
        return 0;
    }

    // function balanceOf(bytes32[] memory substrates_, address plasmaVault_) internal view returns (uint256) {
    // uint256 len = substrates_.length;

    // if (len == 0) {
    //     return 0;
    // }
    // IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
    //     PlasmaVaultLib.getPriceOracleMiddleware()
    // );

    // PendleMarketV3 marketAddress;
    // address asset;
    // uint8 assetDecimals;

    // IStandardizedYield syToken;
    // IPPrincipalToken ptToken;
    // IPYieldToken ytToken;
    // uint256 price;
    // uint256 decimals;

    // TokensBalances memory tokensBalances;
    // uint256 exchangeRate;

    // for (uint256 i; i < len; ++i) {
    //     marketAddress = PendleMarketV3(PlasmaVaultConfigLib.bytes32ToAddress(substrates_[i]));
    //     (syToken, ptToken, ytToken) = marketAddress.readTokens();
    //     (, asset, assetDecimals) = syToken.assetInfo();
    //     (price, decimals) = priceOracleMiddleware.getAssetPrice(asset);
    //     exchangeRate = syToken.exchangeRate();
    //     tokensBalances.syTokenBalance = syToken.balanceOf(plasmaVault_);
    //     tokensBalances.ptTokenBalance = ptToken.balanceOf(plasmaVault_);
    //     tokensBalances.ytTokenBalance = ytToken.balanceOf(plasmaVault_);

    //     tokensBalances.syTokenInAssetBalance = SYUtils.syToAsset(exchangeRate, tokensBalances.ytTokenBalance);
    //     tokensBalances.ptTokenInAssetBalance = 0;
    // }

    //     return 0;
    // }

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
