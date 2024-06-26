// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
import {IPriceOracleMiddleware} from "./../../priceOracle/IPriceOracleMiddleware.sol";

contract CurveStableswapNGSingleSideBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IPriceOracleMiddleware public immutable PRICE_ORACLE;

    constructor(uint256 marketIdInput, address priceOracle) {
        MARKET_ID = marketIdInput;
        PRICE_ORACLE = IPriceOracleMiddleware(priceOracle);
    }

    function balanceOf(address plasmaVault) external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 withdrawTokenAmount;
        address lpTokenAddress; // Curve LP token
        int128 indexCoin;

        for (uint256 i; i < len; ++i) {
            lpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            indexCoin = _getCoinIndex(ICurveStableswapNG(lpTokenAddress), IERC4626(plasmaVault).asset());
            withdrawTokenAmount = ICurveStableswapNG(lpTokenAddress).calc_withdraw_one_coin(
                ERC20(lpTokenAddress).balanceOf(plasmaVault),
                indexCoin
            );
            balance += IporMath.convertToWad(
                withdrawTokenAmount * PRICE_ORACLE.getAssetPrice(IERC4626(plasmaVault).asset()),
                ERC20(IERC4626(plasmaVault).asset()).decimals() + PRICE_DECIMALS
            );
        }
        return balance;
    }

    function _getCoinIndex(ICurveStableswapNG curvePool, address asset) internal view returns (int128) {
        for (uint256 j = 0; j < curvePool.N_COINS(); ++j) {
            if (curvePool.coins(j) == asset) {
                require(j < 2 ** 127, "Index exceeds int128 range");
                return int128(int256(j));
            }
        }
        revert("Asset not found in curve pool");
    }
}
