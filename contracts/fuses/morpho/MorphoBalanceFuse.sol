// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoStorageLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title Fuse Morpho Balance protocol responsible for calculating the balance of the Plasma Vault in the Morpho protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the Morpho Market IDs that are used in the Morpho protocol for a given MARKET_ID
contract MorphoBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeCast for int256;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    IMorpho public immutable MORPHO;
    address private constant USD = address(0x0000000000000000000000000000000000000348);

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_, address morpho_) {
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    /// @return The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory morphoMarkets = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = morphoMarkets.length;
        if (len == 0) {
            return 0;
        }

        int256 balance = 0;
        uint256 totalCollateralAssets;
        uint256 totalBorrowAssets;
        uint256 totalSupplyAssets;
        bytes32[] memory slots = new bytes32[](1);
        bytes32[] memory values;
        address plasmaVault = address(this);

        MarketParams memory marketParams;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            marketParams = MORPHO.idToMarketParams(Id.wrap(morphoMarkets[i]));
            totalSupplyAssets = MORPHO.expectedSupplyAssets(marketParams, plasmaVault);

            slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(Id.wrap(morphoMarkets[i]), plasmaVault);
            values = MORPHO.extSloads(slots);
            totalCollateralAssets = uint256(values[0] >> 128);

            totalBorrowAssets = MORPHO.expectedBorrowAssets(marketParams, plasmaVault);

            balance += _convertToUsd(priceOracleMiddleware, marketParams.collateralToken, totalCollateralAssets)
                .toInt256();

            if (totalSupplyAssets > totalBorrowAssets) {
                balance += _convertToUsd(
                    priceOracleMiddleware,
                    marketParams.loanToken,
                    totalSupplyAssets - totalBorrowAssets
                ).toInt256();
            } else {
                balance -= _convertToUsd(
                    priceOracleMiddleware,
                    marketParams.loanToken,
                    totalBorrowAssets - totalSupplyAssets
                ).toInt256();
            }
        }
        return balance.toUint256();
    }

    function _convertToUsd(
        address priceOracleMiddleware_,
        address asset_,
        uint256 amount_
    ) internal view returns (uint256) {
        if (amount_ == 0) return 0;
        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(asset_);

        return IporMath.convertToWad(amount_ * price, ERC20(asset_).decimals() + decimals);
    }
}
