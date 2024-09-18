// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

contract ERC20BalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function balanceOf() external view override returns (uint256) {
        bytes32[] memory vaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = vaults.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address asset;
        uint256 price;
        uint256 priceDecimals;
        address underlyingAsset = IERC4626(address(this)).asset();
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            asset = PlasmaVaultConfigLib.bytes32ToAddress(vaults[i]);
            if (address(asset) == underlyingAsset) {
                continue;
            }
            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(asset);

            balance += IporMath.convertToWad(
                IERC20(asset).balanceOf(address(this)) * price,
                IERC20Metadata(asset).decimals() + priceDecimals
            );
        }

        return balance;
    }
}
