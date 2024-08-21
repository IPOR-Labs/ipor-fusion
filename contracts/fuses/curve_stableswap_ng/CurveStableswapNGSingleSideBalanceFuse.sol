// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
import {IPriceOracleMiddleware} from "./../../priceOracle/IPriceOracleMiddleware.sol";

/// @notice This Balance Fuse can only be used for assets compaitble with the underlying of the Plasma Vault asset
contract CurveStableswapNGSingleSideBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IPriceOracleMiddleware public immutable PRICE_ORACLE;

    error AssetNotFoundInCurvePool(address curvePool, address asset);

    constructor(uint256 marketId_, address priceOracle_) {
        MARKET_ID = marketId_;
        PRICE_ORACLE = IPriceOracleMiddleware(priceOracle_);
    }

    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 withdrawTokenAmount;
        address lpTokenAddress; // Curve LP token
        address underlyingAsset = IERC4626(plasmaVault_).asset(); // Plasma Vault asset
        int128 indexCoin;

        for (uint256 i; i < len; ++i) {
            lpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            indexCoin = _getCoinIndex(ICurveStableswapNG(lpTokenAddress), underlyingAsset);
            withdrawTokenAmount = ICurveStableswapNG(lpTokenAddress).calc_withdraw_one_coin(
                ERC20(lpTokenAddress).balanceOf(plasmaVault_),
                indexCoin
            );
            balance += IporMath.convertToWad(
                withdrawTokenAmount * PRICE_ORACLE.getAssetPrice(underlyingAsset),
                ERC20(IERC4626(plasmaVault_).asset()).decimals() + PRICE_DECIMALS
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
