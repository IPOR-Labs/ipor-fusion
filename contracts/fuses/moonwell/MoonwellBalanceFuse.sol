// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MErc20} from "./ext/MErc20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title MoonwellBalanceFuse
/// @notice Fuse for calculating user balances in the Moonwell protocol
/// @dev Calculates net balance by taking supplied assets minus borrowed assets
/// @dev Substrates in this fuse are the mTokens used in the Moonwell protocol for a given MARKET_ID
contract MoonwellBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    using SafeCast for uint256;
    using Address for address;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    error MoonwellBalanceFuseInvalidPrice();

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice Gets the total balance in USD for this contract in the Moonwell protocol
    /// @return The balance in USD with 18 decimals
    function balanceOf() external override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        return _calculateBalance(assetsRaw, address(this));
    }

    /// @notice Calculates balance for specific substrates and plasma vault
    /// @param substrates_ Array of substrate addresses encoded as bytes32
    /// @param plasmaVault_ Address of the plasma vault
    /// @return The balance in USD with 18 decimals
    function balanceOf(bytes32[] memory substrates_, address plasmaVault_) external returns (uint256) {
        return _calculateBalance(substrates_, plasmaVault_);
    }

    /// @dev Internal function to calculate balance for given substrates and plasma vault
    /// @param substrates_ Array of substrate addresses encoded as bytes32
    /// @param plasmaVault_ Address of the plasma vault
    /// @return Balance in USD with 18 decimals
    function _calculateBalance(bytes32[] memory substrates_, address plasmaVault_) internal returns (uint256) {
        if (substrates_.length == 0) {
            return 0;
        }

        int256 balanceTemp;
        uint256 decimals;
        uint256 price; // @dev this value has 8 decimals
        uint256 priceDecimals;
        MErc20 mToken;
        address underlying;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < substrates_.length; ++i) {
            mToken = MErc20(PlasmaVaultConfigLib.bytes32ToAddress(substrates_[i]));
            underlying = mToken.underlying();
            decimals = ERC20(underlying).decimals();

            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(underlying);
            if (price == 0) {
                revert MoonwellBalanceFuseInvalidPrice();
            }
            // Calculate supplied value in USD
            balanceTemp += IporMath.convertToWadInt(
                mToken.balanceOfUnderlying(plasmaVault_).toInt256() * int256(price),
                decimals + priceDecimals
            );

            // Subtract borrowed value in USD using borrowBalanceStored
            balanceTemp -= IporMath.convertToWadInt(
                (mToken.borrowBalanceStored(plasmaVault_) * price).toInt256(),
                decimals + priceDecimals
            );
        }

        // If balance is negative, return 0
        return balanceTemp < 0 ? 0 : balanceTemp.toUint256();
    }
}
