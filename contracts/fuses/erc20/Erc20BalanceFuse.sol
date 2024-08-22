// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../priceOracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

contract ERC20BalanceFuse is IMarketBalanceFuse {
    uint256 private constant PRICE_ORACLE_MIDDLEWARE_DECIMALS = 8;
    uint256 public immutable MARKET_ID;

    IPriceOracleMiddleware public immutable PRICE_ORACLE_MIDDLEWARE;

    constructor(uint256 marketId_, address priceOracle_) {
        MARKET_ID = marketId_;
        PRICE_ORACLE_MIDDLEWARE = IPriceOracleMiddleware(priceOracle_);
        //TODO add validation after merge https://github.com/IPOR-Labs/ipor-fusion/pull/72
        //        PRICE_ORACLE_MIDDLEWARE = IPriceOracleMiddleware(priceOracle_);
        //        if (PRICE_ORACLE_MIDDLEWARE.QUOTE_CURRENCY_DECIMALS() != PRICE_ORACLE_MIDDLEWARE_DECIMALS) {
        //            revert IPriceOracleMiddleware.WrongDecimals();
        //        }
    }

    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        bytes32[] memory vaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = vaults.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address token;
        address underlineAsset = IERC4626(address(this)).asset();
        for (uint256 i; i < len; ++i) {
            token = PlasmaVaultConfigLib.bytes32ToAddress(vaults[i]);
            if (address(token) == underlineAsset) {
                continue;
            }
            balance += IporMath.convertToWad(
                IERC20(token).balanceOf(plasmaVault_) * PRICE_ORACLE_MIDDLEWARE.getAssetPrice(token),
                IERC20Metadata(token).decimals() + PRICE_ORACLE_MIDDLEWARE_DECIMALS
            );
        }

        return balance;
    }
}
