// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IComet} from "./IComet.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

contract CompoundV3BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    using SafeCast for uint256;

    uint256 private constant PRICE_DECIMALS = 8;

    IComet public immutable COMET;
    uint256 public immutable MARKET_ID;
    address public immutable COMPOUND_BASE_TOKEN;
    uint256 public immutable COMPOUND_BASE_TOKEN_DECIMALS;
    address public immutable BASE_TOKEN_PRICE_FEED;

    constructor(address cometAddressInput, uint256 marketIdInput) {
        COMET = IComet(cometAddressInput);
        MARKET_ID = marketIdInput;
        COMPOUND_BASE_TOKEN = COMET.baseToken();
        BASE_TOKEN_PRICE_FEED = COMET.baseTokenPriceFeed();
        COMPOUND_BASE_TOKEN_DECIMALS = ERC20(COMPOUND_BASE_TOKEN).decimals();
    }

    function balanceOf(address plazmaVault) external view override returns (uint256) {
        bytes32[] memory assetsRaw = MarketConfigurationLib.getMarketConfigurationSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;
        if (len == 0) {
            return 0;
        }

        int256 balanceTemp = 0;
        int256 balanceInLoop;
        uint256 decimals;
        // @dev this value has 8 decimals
        uint256 price;
        address asset;
        int256 borrowBalance;

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            asset = MarketConfigurationLib.bytes32ToAddress(assetsRaw[i]);
            decimals = ERC20(asset).decimals();
            price = _getPrice(asset);

            balanceTemp += IporMath.convertToWadInt(
                _getBalance(plazmaVault, asset).toInt256() * int256(price),
                decimals + PRICE_DECIMALS
            );
        }

        borrowBalance = IporMath.convertToWadInt(
            (COMET.borrowBalanceOf(plazmaVault) * COMET.getPrice(BASE_TOKEN_PRICE_FEED)).toInt256(),
            COMPOUND_BASE_TOKEN_DECIMALS + PRICE_DECIMALS
        );

        balanceTemp -= borrowBalance;

        return balanceTemp.toUint256();
    }

    function _getPrice(address asset) internal view returns (uint256) {
        if (asset == COMPOUND_BASE_TOKEN) {
            return COMET.getPrice(BASE_TOKEN_PRICE_FEED);
        }
        address priceFeed = COMET.getAssetInfoByAddress(asset).priceFeed;
        return COMET.getPrice(priceFeed);
    }

    function _getBalance(address plazmaVault, address asset) private view returns (uint256) {
        if (asset == COMPOUND_BASE_TOKEN) {
            return COMET.balanceOf(plazmaVault);
        } else {
            return COMET.collateralBalanceOf(plazmaVault, asset);
        }
    }
}