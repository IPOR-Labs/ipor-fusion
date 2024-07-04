// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IComet} from "./ext/IComet.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

contract CompoundV3BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    using SafeCast for uint256;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IComet public immutable COMET;
    address public immutable COMPOUND_BASE_TOKEN;
    uint256 public immutable COMPOUND_BASE_TOKEN_DECIMALS;
    address public immutable BASE_TOKEN_PRICE_FEED;

    constructor(uint256 marketId_, address cometAddress_) {
        MARKET_ID = marketId_;
        COMET = IComet(cometAddress_);
        COMPOUND_BASE_TOKEN = COMET.baseToken();
        BASE_TOKEN_PRICE_FEED = COMET.baseTokenPriceFeed();
        COMPOUND_BASE_TOKEN_DECIMALS = ERC20(COMPOUND_BASE_TOKEN).decimals();
    }

    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

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

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            decimals = ERC20(asset).decimals();
            price = _getPrice(asset);

            balanceTemp += IporMath.convertToWadInt(
                _getBalance(plasmaVault_, asset).toInt256() * int256(price),
                decimals + PRICE_DECIMALS
            );
        }

        int256 borrowBalance = IporMath.convertToWadInt(
            (COMET.borrowBalanceOf(plasmaVault_) * COMET.getPrice(BASE_TOKEN_PRICE_FEED)).toInt256(),
            COMPOUND_BASE_TOKEN_DECIMALS + PRICE_DECIMALS
        );

        balanceTemp -= borrowBalance;

        return balanceTemp.toUint256();
    }

    function _getPrice(address asset_) internal view returns (uint256) {
        if (asset_ == COMPOUND_BASE_TOKEN) {
            return COMET.getPrice(BASE_TOKEN_PRICE_FEED);
        }
        address priceFeed = COMET.getAssetInfoByAddress(asset_).priceFeed;
        return COMET.getPrice(priceFeed);
    }

    function _getBalance(address plasmaVault_, address asset_) private view returns (uint256) {
        if (asset_ == COMPOUND_BASE_TOKEN) {
            return COMET.balanceOf(plasmaVault_);
        } else {
            return COMET.collateralBalanceOf(plasmaVault_, asset_);
        }
    }
}
