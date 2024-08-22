// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
import {IPriceOracleMiddleware} from "./../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "./../../libraries/PlasmaVaultLib.sol";

/// @title Fuse for Curve Stableswap NG protocol responsible for calculating the balance of the Plasma Vault in the Curve Stableswap NG protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the Curve LP Tokens that are used in the Curve Stableswap NG protocol for a given MARKET_ID
contract CurveStableswapNGSingleSideBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;

    error AssetNotFoundInCurvePool(address curvePool, address asset);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }
    /// @param plasmaVault_ The address of the Plasma Vault
    /// @return The balance of the given input plasmaVault_ in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 withdrawTokenAmount;
        address lpTokenAddress; /// @dev Curve LP token
        uint256 price;
        uint256 priceDecimals;
        address underlyingAsset = IERC4626(plasmaVault_).asset();
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            lpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);

            withdrawTokenAmount = ICurveStableswapNG(lpTokenAddress).calc_withdraw_one_coin(
                ERC20(lpTokenAddress).balanceOf(plasmaVault_),
                _getCoinIndex(ICurveStableswapNG(lpTokenAddress), underlyingAsset)
            );
            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(underlyingAsset);

            balance += IporMath.convertToWad(
                withdrawTokenAmount * price,
                ERC20(IERC4626(plasmaVault_).asset()).decimals() + priceDecimals
            );
        }
        return balance;
    }

    function _getCoinIndex(ICurveStableswapNG curvePool_, address asset_) internal view returns (int128) {
        uint256 len = curvePool_.N_COINS();
        for (uint256 j; j < len; ++j) {
            if (curvePool_.coins(j) == asset_) {
                return SafeCast.toInt128(int256(j));
            }
        }
        revert AssetNotFoundInCurvePool(address(curvePool_), asset_);
    }
}
