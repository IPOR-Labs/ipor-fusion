// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IAavePoolDataProvider} from "./ext/IAavePoolDataProvider.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";

/// @title Fuse for Aave V3 protocol responsible for calculating the balance of the Plasma Vault in Aaave V3 protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the Aave V3 protocol for a given MARKET_ID
contract AaveV3WithPriceOracleMiddlewareBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;

    uint256 public immutable MARKET_ID;
    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert Errors.WrongAddress();
        }

        MARKET_ID = marketId_;
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    function balanceOf() external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;

        if (len == 0) {
            return 0;
        }

        int256 balanceTemp;
        int256 balanceInLoop;
        uint256 decimals;
        uint256 price;
        uint256 priceDecimals;
        address asset;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address plasmaVault = address(this);
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            decimals = ERC20(asset).decimals();
            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(asset);

            if (price == 0) {
                revert Errors.UnsupportedQuoteCurrencyFromOracle();
            }

            (aTokenAddress, stableDebtTokenAddress, variableDebtTokenAddress) = IAavePoolDataProvider(
                IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPoolDataProvider()
            ).getReserveTokensAddresses(asset);

            if (aTokenAddress != address(0)) {
                balanceInLoop += int256(ERC20(aTokenAddress).balanceOf(plasmaVault));
            }
            if (stableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(stableDebtTokenAddress).balanceOf(plasmaVault));
            }
            if (variableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(variableDebtTokenAddress).balanceOf(plasmaVault));
            }

            balanceTemp += IporMath.convertToWadInt(balanceInLoop * int256(price), decimals + priceDecimals);
        }

        return balanceTemp.toUint256();
    }
}
