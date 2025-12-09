// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";

/// @title Fuse Morpho Balance protocol responsible for calculating the balance of the Plasma Vault in the Morpho protocol based on preconfigured market substrates
/// @notice This contract calculates the balance of the Plasma Vault in the Morpho protocol
/// @dev Substrates in this fuse are the Morpho Market IDs that are used in the Morpho protocol for a given MARKET_ID
contract MorphoOnlyLiquidityBalanceFuse is IMarketBalanceFuse {
    using MorphoBalancesLib for IMorpho;

    error MorphoOnlyLiquidityBalanceFuseInvalidMorpho();
    error MorphoOnlyLiquidityBalanceFuseInvalidMarketId();

    /// @notice Morpho Blue protocol interface
    IMorpho public immutable MORPHO;

    /// @notice Version identifier for this contract
    address public immutable VERSION;

    /// @notice Market ID associated with this fuse
    uint256 public immutable MARKET_ID;

    /// @notice Constructor
    /// @param marketId_ The market ID
    /// @param morpho_ The Morpho Blue protocol address
    constructor(uint256 marketId_, address morpho_) {
        if (morpho_ == address(0)) {
            revert MorphoOnlyLiquidityBalanceFuseInvalidMorpho();
        }
        if (marketId_ == 0) {
            revert MorphoOnlyLiquidityBalanceFuseInvalidMarketId();
        }
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
        VERSION = address(this);
    }

    /// @notice Calculates the total balance of the Plasma Vault in USD
    /// @return The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory morphoMarkets = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = morphoMarkets.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        /// @dev plasmaVault is the address of the Plasma Vault because it is the address of the contract that is calling the balanceOf function using delegatecall
        address plasmaVault = address(this);
        MarketParams memory marketParams;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            marketParams = MORPHO.idToMarketParams(Id.wrap(morphoMarkets[i]));
            /// @dev if the marketParams.loanToken is the zero address, it means that the market is not a liquidity market, so we skip it
            if (marketParams.loanToken == address(0)) {
                continue;
            }
            /// @dev we convert the expected supply assets to USD using the price oracle middleware
            balance += _convertToUsd(
                priceOracleMiddleware,
                marketParams.loanToken,
                MORPHO.expectedSupplyAssets(marketParams, plasmaVault)
            );
        }

        return balance;
    }

    /// @notice Converts an asset amount to USD
    /// @param priceOracleMiddleware_ The price oracle middleware address
    /// @param asset_ The asset address
    /// @param amount_ The amount of asset
    /// @return The equivalent amount in USD (18 decimals)
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
