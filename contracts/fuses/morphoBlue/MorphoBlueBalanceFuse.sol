// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

import {IIporPriceOracle} from "../../priceOracle/IIporPriceOracle.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoStorageLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";

contract MorphoBlueBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeCast for int256;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address private constant USD = address(0x0000000000000000000000000000000000000348);

    IIporPriceOracle public immutable PRICE_ORACLE;
    uint256 public immutable MARKET_ID;
    constructor(address priceOracle, uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        PRICE_ORACLE = IIporPriceOracle(priceOracle);
    }

    function balanceOf(address plazmaVault) external view override returns (uint256) {
        bytes32[] memory markets = MarketConfigurationLib.getMarketConfigurationSubstrates(MARKET_ID);

        uint256 len = markets.length;
        if (len == 0) {
            return 0;
        }

        int256 balance = 0;

        MarketParams memory marketParams;
        for (uint256 i; i < len; ++i) {
            marketParams = MORPHO.idToMarketParams(Id.wrap(markets[i]));
            uint256 totalSupplyAssets = MORPHO.expectedSupplyAssets(marketParams, plazmaVault);

            bytes32[] memory slots = new bytes32[](1);
            slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(Id.wrap(markets[i]), plazmaVault);
            bytes32[] memory values = MORPHO.extSloads(slots);
            uint256 totalCollateralAssets = uint256(values[0] >> 128);

            uint256 totalBorrowAssets = MORPHO.expectedBorrowAssets(marketParams, plazmaVault);

            balance += _convertToUsd(marketParams.collateralToken, totalCollateralAssets).toInt256(); //totalCollateralAssets - totalBorrowAssets;
            balance +=
                _convertToUsd(marketParams.loanToken, totalSupplyAssets).toInt256() -
                _convertToUsd(marketParams.collateralToken, totalBorrowAssets).toInt256(); //totalCollateralAssets - totalBorrowAssets;
        }

        return balance.toUint256();
    }

    function _convertToUsd(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 price = PRICE_ORACLE.getAssetPrice(asset);
        uint256 decimals = ERC20(asset).decimals();
        return IporMath.convertToWad(amount * price, decimals + 8);
    }
}
