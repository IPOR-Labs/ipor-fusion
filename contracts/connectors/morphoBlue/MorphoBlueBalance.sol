// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBalance} from "../IBalance.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IComet} from "./IComet.sol";

import {IIporPriceOracle} from "../../priceOracle/IIporPriceOracle.sol";

import {IMorpho} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MorphoBlueBalance {
    using SafeCast for uint256;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address private constant USD = address(0x0000000000000000000000000000000000000348);

    IIporPriceOracle public immutable PRICE_ORACLE;
    constructor(address priceOracle, uint256 marketIdInput) {
        COMET = IComet(cometAddressInput);
        MARKET_ID = marketIdInput;
        COMPOUND_BASE_TOKEN = COMET.baseToken();
        BASE_TOKEN_PRICE_FEED = COMET.baseTokenPriceFeed();
        COMPOUND_BASE_TOKEN_DECIMALS = ERC20(COMPOUND_BASE_TOKEN).decimals();
    }

    function balanceOfMarket(address user) external view override returns (uint256, address) {
        bytes32[] memory markets;

        uint256 len = markets.length;
        if (len == 0) {
            return (0, USD);
        }

        uint256 balance = 0;

        IMorpho.MarketParams memory marketParams;
        for (uint256 i; i < len; ++i) {
            marketParams = MORPHO.idToMarketParams(markets[i]);
            uint256 totalSupplyAssets = morpho.expectedSupplyAssets(marketParams, address(this));

            bytes32[] memory slots = new bytes32[](1);
            slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(marketId, user);
            bytes32[] memory values = morpho.extSloads(slots);
            uint256 totalCollateralAssets = uint256(values[0] >> 128);

            uint256 totalBorrowAssets = morpho.expectedBorrowAssets(marketParams, user);

            balance += _convertToUsd(marketParams.collateralToken, totalCollateralAssets); //totalCollateralAssets - totalBorrowAssets;
            balance +=
                _convertToUsd(marketParams.loanToken, totalSupplyAssets) -
                _convertToUsd(marketParams.collateralToken, totalBorrowAssets); //totalCollateralAssets - totalBorrowAssets;
        }

        return (balance, USD);
    }

    function _convertToUsd(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 price = IIporPriceOracle(priceOracle).getAssetPrice(asset);
        uint256 decimals = ERC20(asset).decimals();
        Math.mulDiv(amount, price, 10 ** (decimals));
        return IporMath.convertToWad(amount * price, decimals + 8);
    }
}
