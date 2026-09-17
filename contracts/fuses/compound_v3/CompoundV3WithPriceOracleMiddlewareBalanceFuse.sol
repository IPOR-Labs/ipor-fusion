// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IComet} from "./ext/IComet.sol";

/// @title CompoundV3WithPriceOracleMiddlewareBalanceFuse
/// @notice Fuse for Compound V3 protocol responsible for calculating the balance of the Plasma Vault in a Compound V3 Comet market,
///         priced with the Price Oracle Middleware of the Plasma Vault
/// @dev The balance is calculated as the sum of the base token supply and the collateral balances of all market substrates
///      configured for MARKET_ID, minus the base token borrow balance, all converted to USD using the Price Oracle Middleware
///      and normalized to WAD (18 decimals).
///      Substrates in this fuse are the assets that are used in the Compound V3 protocol for a given MARKET_ID.
///      Unlike CompoundV3BalanceFuse, no Comet price feeds and no Comet asset info lookups are used, so the valuation
///      is consistent with every other valuation in the Plasma Vault.
/// @author IPOR Labs
contract CompoundV3WithPriceOracleMiddlewareBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev This ID is used to retrieve the list of substrates (assets) configured for this market
    uint256 public immutable MARKET_ID;

    /// @notice The Compound V3 Comet market used by the Fuse
    IComet public immutable COMET;

    /// @notice The base token of the Comet market
    address public immutable COMPOUND_BASE_TOKEN;

    /// @notice The decimals of the base token of the Comet market
    uint256 public immutable COMPOUND_BASE_TOKEN_DECIMALS;

    /// @notice Error thrown when market ID is zero
    error CompoundV3WithPriceOracleMiddlewareBalanceFuseInvalidMarketId();

    /// @notice Error thrown when the Comet address is the zero address
    error CompoundV3WithPriceOracleMiddlewareBalanceFuseInvalidAddress();

    /// @notice Constructor to initialize the fuse with a market ID and a Compound V3 Comet market
    /// @dev Validates the inputs before reading the base token and its decimals
    /// @param marketId_ The unique identifier for the market configuration
    /// @param cometAddress_ The address of the Compound V3 Comet market
    constructor(uint256 marketId_, address cometAddress_) {
        if (marketId_ == 0) {
            revert CompoundV3WithPriceOracleMiddlewareBalanceFuseInvalidMarketId();
        }
        if (cometAddress_ == address(0)) {
            revert CompoundV3WithPriceOracleMiddlewareBalanceFuseInvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        COMET = IComet(cometAddress_);
        COMPOUND_BASE_TOKEN = COMET.baseToken();
        COMPOUND_BASE_TOKEN_DECIMALS = ERC20(COMPOUND_BASE_TOKEN).decimals();
    }

    /// @notice Calculates the net balance of the Plasma Vault in the Compound V3 Comet market in USD
    /// @dev Executed via delegatecall in the context of the Plasma Vault. The calculation:
    ///      1. For each substrate, reads the base token supply (COMET.balanceOf) or the collateral balance
    ///         (COMET.collateralBalanceOf); zero positions are skipped without querying the oracle
    ///      2. Prices each non-zero position with the Price Oracle Middleware (asset decimals + returned price decimals)
    ///      3. Subtracts the base token borrow balance (COMET.borrowBalanceOf), priced with the Price Oracle Middleware;
    ///         the debt is subtracted outside the substrate loop, regardless of the substrate configuration
    ///      Oracle dependency: the Price Oracle Middleware must price every substrate with a non-zero position and the base
    ///      token while debt is open. The fuse has no explicit zero-price check; it relies on the Price Oracle Middleware
    ///      reverting on missing sources and on zero or negative prices.
    ///      Negative net value: if the debt value exceeds the value of the supplied assets, the conversion to uint256
    ///      reverts, which blocks balance updates of this market until the position is repaid or absorbed.
    /// @return The net balance of the Plasma Vault in the Comet market in USD, normalized to WAD (18 decimals)
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;

        int256 balanceTemp;
        uint256 amount;
        uint256 price;
        uint256 priceDecimals;
        address asset;
        address plasmaVault = address(this);
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);

            if (asset == COMPOUND_BASE_TOKEN) {
                amount = COMET.balanceOf(plasmaVault);
            } else {
                amount = COMET.collateralBalanceOf(plasmaVault, asset);
            }

            if (amount == 0) {
                continue;
            }

            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(asset);

            balanceTemp += IporMath.convertToWadInt(
                amount.toInt256() * price.toInt256(),
                ERC20(asset).decimals() + priceDecimals
            );
        }

        uint256 debt = COMET.borrowBalanceOf(plasmaVault);

        if (debt > 0) {
            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(COMPOUND_BASE_TOKEN);

            balanceTemp -= IporMath.convertToWadInt(
                debt.toInt256() * price.toInt256(),
                COMPOUND_BASE_TOKEN_DECIMALS + priceDecimals
            );
        }

        return balanceTemp.toUint256();
    }
}
