// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {CErc20} from "./ext/CErc20.sol";
import {IPriceOracleMiddleware} from "../../priceOracle/IPriceOracleMiddleware.sol";

contract CompoundV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    using SafeCast for uint256;
    using Address for address;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IPriceOracleMiddleware public immutable PRICE_ORACLE;

    constructor(uint256 marketId_, address priceOracle_) {
        MARKET_ID = marketId_;
        PRICE_ORACLE = IPriceOracleMiddleware(priceOracle_);
    }

    function balanceOf(address plasmaVault_) external override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;
        if (len == 0) {
            return 0;
        }

        int256 balanceTemp;
        int256 balanceInLoop;
        uint256 decimals;
        // @dev this value has 8 decimals
        uint256 price;
        CErc20 cToken;
        int256 borrowBalance;
        address underlying;
        uint256 rawBalance;
        uint256 rawBorrowBalance;

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            cToken = CErc20(PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]));
            underlying = cToken.underlying();
            decimals = ERC20(underlying).decimals();
            price = _getPrice(underlying);

            rawBalance = cToken.balanceOfUnderlying(plasmaVault_);
            balanceTemp += IporMath.convertToWadInt(rawBalance.toInt256() * int256(price), decimals + PRICE_DECIMALS);
            rawBorrowBalance = cToken.borrowBalanceCurrent(plasmaVault_);
            borrowBalance = IporMath.convertToWadInt((rawBorrowBalance * price).toInt256(), decimals + PRICE_DECIMALS);

            balanceTemp -= borrowBalance;
        }

        return balanceTemp.toUint256();
    }

    function _getPrice(address asset_) internal view returns (uint256) {
        return PRICE_ORACLE.getAssetPrice(asset_);
    }
}
