// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IporMath} from "../../libraries/math/IporMath.sol";
import {ISavingsDai} from "./ISavingsDai.sol";

import {IIporPriceOracle} from "../../priceOracle/IIporPriceOracle.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

contract SparkBalanceFuse is IMarketBalanceFuse {
    error UnsupportedBaseCurrencyFromOracle(string errorCode);

    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address private constant USD = address(0x0000000000000000000000000000000000000348);

    IIporPriceOracle public immutable PRICE_ORACLE;
    uint256 public immutable MARKET_ID;

    constructor(address priceOracle, uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        PRICE_ORACLE = IIporPriceOracle(priceOracle);
        if (PRICE_ORACLE.BASE_CURRENCY() != USD) {
            revert UnsupportedBaseCurrencyFromOracle(Errors.UNSUPPORTED_BASE_CURRENCY);
        }
    }

    function balanceOf(address plazmaVault) external view override returns (uint256) {
        return _convertToUsd(SDAI, ISavingsDai(SDAI).balanceOf(plazmaVault));
    }

    function _convertToUsd(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return IporMath.convertToWad(amount * PRICE_ORACLE.getAssetPrice(asset), 18 + 8);
    }
}
