// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IporMath} from "../../libraries/math/IporMath.sol";
import {ISavingsDai} from "./ext/ISavingsDai.sol";

import {IPriceOracleMiddleware} from "../../priceOracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

contract SparkBalanceFuse is IMarketBalanceFuse {
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address private constant USD = address(0x0000000000000000000000000000000000000348);

    uint256 public immutable MARKET_ID;
    IPriceOracleMiddleware public immutable PRICE_ORACLE;

    constructor(uint256 marketIdInput, address priceOracle) {
        MARKET_ID = marketIdInput;
        PRICE_ORACLE = IPriceOracleMiddleware(priceOracle);
        if (PRICE_ORACLE.BASE_CURRENCY() != USD) {
            revert Errors.UnsupportedBaseCurrencyFromOracle();
        }
    }

    function balanceOf(address plasmaVault) external view override returns (uint256) {
        return _convertToUsd(SDAI, ISavingsDai(SDAI).balanceOf(plasmaVault));
    }

    function _convertToUsd(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return IporMath.convertToWad(amount * PRICE_ORACLE.getAssetPrice(asset), 18 + 8);
    }
}
