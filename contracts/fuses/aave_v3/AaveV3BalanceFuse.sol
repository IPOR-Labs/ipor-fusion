// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Errors} from "../../libraries/errors/Errors.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IAavePoolDataProvider} from "./ext/IAavePoolDataProvider.sol";
import {IAavePriceOracle} from "./ext/IAavePriceOracle.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";

/// @title AaveV3BalanceFuse
/// @notice Fuse for Aave V3 protocol responsible for calculating the balance of the Plasma Vault in Aave V3 protocol
/// @dev This fuse calculates the total balance by iterating through all market substrates (assets) configured for the given MARKET_ID.
///      For each asset, it retrieves the balance of aTokens (supplied assets) and subtracts the balances of debt tokens
///      (stable and variable debt). The final balance is converted to USD using Aave's price oracle and normalized to WAD (18 decimals).
///      Substrates in this fuse are the assets that are used in the Aave V3 protocol for a given MARKET_ID.
/// @author IPOR Labs
contract AaveV3BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev This ID is used to retrieve the list of substrates (assets) configured for this market
    uint256 public immutable MARKET_ID;

    /// @notice The Aave V3 Pool Addresses Provider address
    /// @dev This address is used to retrieve the price oracle and pool data provider for Aave V3 protocol
    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    /// @dev Aave Price Oracle base currency decimals (USD)
    /// @notice The number of decimals used by Aave's price oracle for base currency (USD) prices
    /// @dev This constant is set to 8, which is the standard decimal precision for Aave price oracles
    uint256 private constant AAVE_ORACLE_BASE_CURRENCY_DECIMALS = 8;

    /// @notice Constructor to initialize the fuse with a market ID and Aave V3 Pool Addresses Provider
    /// @param marketId_ The unique identifier for the market configuration
    /// @param aaveV3PoolAddressesProvider_ The address of the Aave V3 Pool Addresses Provider
    /// @dev The market ID is used to retrieve the list of substrates (assets) that this fuse will track.
    ///      The addresses provider is used to access Aave V3's price oracle and pool data provider.
    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert Errors.WrongAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    /// @notice Calculates the total balance of the Plasma Vault in Aave V3 protocol
    /// @dev This function iterates through all substrates (assets) configured for the MARKET_ID and calculates:
    ///      1. For each asset, retrieves the balance of aTokens (supplied assets) and debt tokens (borrowed assets)
    ///      2. Calculates net balance: aToken balance - stable debt - variable debt
    ///      3. Converts the balance to USD using Aave's price oracle (8 decimals)
    ///      4. Normalizes the result to WAD (18 decimals) using IporMath.convertToWadInt
    ///      5. Sums all asset balances and returns the total
    ///      The calculation methodology ensures that:
    ///      - Positive balances represent supplied assets (aTokens)
    ///      - Negative balances represent borrowed assets (debt tokens)
    ///      - All balances are converted to a common USD-denominated value using oracle prices
    ///      - Final result is normalized to WAD precision (18 decimals) for consistency
    /// @return The total balance of the Plasma Vault in Aave V3 protocol, normalized to WAD (18 decimals)
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;

        if (len == 0) {
            return 0;
        }

        int256 balanceTemp;
        int256 balanceInLoop;
        uint256 decimals;
        uint256 price; // @dev assume price represented in 8 decimals
        address asset;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address plasmaVault = address(this);

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            decimals = ERC20(asset).decimals();
            price = IAavePriceOracle(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPriceOracle())
                .getAssetPrice(asset);

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

            balanceTemp += IporMath.convertToWadInt(
                balanceInLoop * int256(price),
                decimals + AAVE_ORACLE_BASE_CURRENCY_DECIMALS
            );
        }

        return balanceTemp.toUint256();
    }
}
