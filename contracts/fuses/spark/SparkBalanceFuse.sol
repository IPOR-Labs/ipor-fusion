// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {IporMath} from "../../libraries/math/IporMath.sol";
import {ISavingsDai} from "./ext/ISavingsDai.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceOracleMiddleware} from "../../priceOracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

contract SparkBalanceFuse is IMarketBalanceFuse {
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address private constant USD = address(0x0000000000000000000000000000000000000348);
    uint256 private constant PRICE_ORACLE_MIDDLEWARE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IPriceOracleMiddleware public immutable PRICE_ORACLE_MIDDLEWARE;

    constructor(uint256 marketIdInput, address priceOracle) {
        MARKET_ID = marketIdInput;
        PRICE_ORACLE_MIDDLEWARE = IPriceOracleMiddleware(priceOracle);
        if (PRICE_ORACLE_MIDDLEWARE.QUOTE_CURRENCY() != USD) {
            revert Errors.UnsupportedBaseCurrencyFromOracle();
        }
        if (PRICE_ORACLE_MIDDLEWARE.QUOTE_CURRENCY_DECIMALS() != PRICE_ORACLE_MIDDLEWARE_DECIMALS) {
            revert IPriceOracleMiddleware.WrongDecimals();
        }
    }

    function balanceOf(address plasmaVault) external view override returns (uint256) {
        return _convertToUsd(SDAI, ISavingsDai(SDAI).balanceOf(plasmaVault));
    }

    function _convertToUsd(address asset_, uint256 amount_) internal view returns (uint256) {
        if (amount_ == 0) return 0;
        return
            IporMath.convertToWad(
                amount_ * PRICE_ORACLE_MIDDLEWARE.getAssetPrice(asset_),
                IERC20Metadata(asset_).decimals() + PRICE_ORACLE_MIDDLEWARE_DECIMALS
            );
    }
}
