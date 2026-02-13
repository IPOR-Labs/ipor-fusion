// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {AaveConstantsEthereum} from "./AaveConstantsEthereum.sol";
import {IAavePriceOracle} from "./ext/IAavePriceOracle.sol";
import {AaveLendingPoolV2, ReserveData} from "./ext/AaveLendingPoolV2.sol";

/// @title AaveV2BalanceFuse
/// @notice Fuse for Aave V2 protocol responsible for calculating the balance of the Plasma Vault in Aave V2 protocol
/// @dev This fuse calculates the total balance by iterating through all market substrates (assets) configured for the given MARKET_ID.
///      For each asset, it retrieves the balance of aTokens (supplied assets) and subtracts the balances of debt tokens
///      (stable and variable debt). The final balance is converted to USD using Aave's price oracle and normalized to WAD (18 decimals).
///      Substrates in this fuse are the assets that are used in the Aave V2 protocol for a given MARKET_ID.
/// @author IPOR Labs
contract AaveV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev This ID is used to retrieve the list of substrates (assets) configured for this market
    uint256 public immutable MARKET_ID;

    /// @dev Aave Price Oracle base currency decimals (USD)
    /// @notice The number of decimals used by Aave's price oracle for base currency (USD) prices
    /// @dev This constant is set to 8, which is the standard decimal precision for Aave price oracles
    uint256 private constant AAVE_ORACLE_BASE_CURRENCY_DECIMALS = 8;

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketIdInput_ The unique identifier for the market configuration
    /// @dev The market ID is used to retrieve the list of substrates (assets) that this fuse will track
    constructor(uint256 marketIdInput_) {
        VERSION = address(this);
        MARKET_ID = marketIdInput_;
    }

    /// @notice Calculates the total balance of the Plasma Vault in Aave V2 protocol
    /// @dev This function iterates through all substrates (assets) configured for the MARKET_ID and calculates:
    ///      1. For each asset, retrieves the balance of aTokens (supplied assets) and debt tokens (borrowed assets)
    ///      2. Calculates net balance: aToken balance - stable debt - variable debt
    ///      3. Converts the balance to USD using Aave's price oracle (8 decimals)
    ///      4. Normalizes the result to WAD (18 decimals) using IporMath.convertToWadInt
    ///      5. Sums all asset balances and returns the total
    /// @return The total balance of the Plasma Vault in Aave V2 protocol, normalized to WAD (18 decimals)
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;

        if (len == 0) {
            return 0;
        }

        int256 balanceTemp;
        int256 balanceInLoop;
        uint256 decimals;
        uint256 price; // @dev value represented in 8 decimals
        address asset;
        ReserveData memory reserveData;

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            decimals = ERC20(asset).decimals();
            price = IAavePriceOracle(AaveConstantsEthereum.AAVE_PRICE_ORACLE_MAINNET).getAssetPrice(asset);

            reserveData = AaveLendingPoolV2(AaveConstantsEthereum.AAVE_LENDING_POOL_V2).getReserveData(asset);

            if (reserveData.aTokenAddress != address(0)) {
                balanceInLoop += int256(ERC20(reserveData.aTokenAddress).balanceOf(address(this)));
            }
            if (reserveData.stableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(reserveData.stableDebtTokenAddress).balanceOf(address(this)));
            }
            if (reserveData.variableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(reserveData.variableDebtTokenAddress).balanceOf(address(this)));
            }

            balanceTemp += IporMath.convertToWadInt(
                balanceInLoop * int256(price),
                decimals + AAVE_ORACLE_BASE_CURRENCY_DECIMALS
            );
        }

        return balanceTemp.toUint256();
    }
}
