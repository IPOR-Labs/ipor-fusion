// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";

contract CurveStableswapNGBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    ICurveStableswapNG public immutable CURVE_STABLESWAP_NG;

    constructor(uint256 marketIdInput, address curveStableswapNG) {
        MARKET_ID = marketIdInput;
        CURVE_STABLESWAP_NG = ICurveStableswapNG(curveStableswapNG);
    }

    function balanceOf(address plasmaVault) external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address asset;

        for (uint256 i; i < len; ++i) {
            asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            // TODO Currently vulnerable to donation-style attacks for rebasing tokens
            balance += IporMath.convertToWad(
                ERC20(asset).balanceOf(plasmaVault) * CURVE_STABLESWAP_NG.get_virtual_price(),
                ERC20(asset).decimals() + PRICE_DECIMALS
            );
        }
        return balance;
    }
}
