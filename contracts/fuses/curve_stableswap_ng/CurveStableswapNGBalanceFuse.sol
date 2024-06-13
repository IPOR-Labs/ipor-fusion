// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {IIporPriceOracle} from "./../../priceOracle/IIporPriceOracle.sol";

contract CurveStableswapNGBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IIporPriceOracle public immutable PRICE_ORACLE;

    constructor(uint256 marketIdInput, address priceOracle) {
        MARKET_ID = marketIdInput;
        PRICE_ORACLE = IIporPriceOracle(priceOracle);
    }

    function balanceOf(address plasmaVault) external override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 decimals;
        // @dev this value has 8 decimals
        uint256 price;
        address asset;

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            balance += IporMath.convertToWadInt(
                ERC20(asset).balanceOf(plasmaVault) * PRICE_ORACLE.getAssetPrice(asset),
                ERC20(asset).decimals() + PRICE_DECIMALS
            );
        }
        return balance;
    }
}
