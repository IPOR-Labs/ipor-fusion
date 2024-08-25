// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CErc20} from "./ext/CErc20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @dev Fuse for Compound V2 protocol responsible for calculating the balance of the user in the Compound V2 protocol
/// based on preconfigured market substrates
/// @dev Substrates in this fuse are the cTokens that are used in the Compound V2 protocol for a given MARKET_ID
contract CompoundV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    using SafeCast for uint256;
    using Address for address;

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @return The balance of the given input plasmaVault_ in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf() external override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        if (assetsRaw.length == 0) {
            return 0;
        }

        int256 balanceTemp;
        uint256 decimals;
        uint256 price; // @dev this value has 8 decimals
        uint256 priceDecimals;
        CErc20 cToken;
        address underlying;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < assetsRaw.length; ++i) {
            cToken = CErc20(PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]));
            underlying = cToken.underlying();
            decimals = ERC20(underlying).decimals();

            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(underlying);

            balanceTemp += IporMath.convertToWadInt(
                cToken.balanceOfUnderlying(address(this)).toInt256() * int256(price),
                decimals + priceDecimals
            );
            balanceTemp -= IporMath.convertToWadInt(
                (cToken.borrowBalanceCurrent(address(this)) * price).toInt256(),
                decimals + priceDecimals
            );
        }

        return balanceTemp.toUint256();
    }
}
