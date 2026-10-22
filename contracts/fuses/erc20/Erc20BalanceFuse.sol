// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title Fuse for calculating ERC20 token balances in Plasma Vault
 * @notice Calculates the total balance of ERC20 tokens held by the Plasma Vault, excluding the underlying asset
 * @dev This fuse iterates through all substrates (ERC20 token addresses) configured for the market,
 *      retrieves the balance of each token, converts it to USD using price oracle middleware,
 *      and returns the sum of all balances normalized to WAD (18 decimals).
 *      The underlying asset of the vault is excluded from the calculation to avoid double counting.
 */
contract ERC20BalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when market ID is zero
    /// @custom:error Erc20BalanceFuseInvalidMarketId
    error Erc20BalanceFuseInvalidMarketId();

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates
    uint256 public immutable MARKET_ID;

    /**
     * @notice Initializes the ERC20BalanceFuse with a specific market ID
     * @param marketId_ The market ID used to identify the ERC20 token substrates
     * @dev Reverts if marketId_ is zero
     */
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert Erc20BalanceFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Calculates the total balance of ERC20 tokens held by the Plasma Vault
     * @dev This function:
     *      1. Retrieves all substrates (ERC20 token addresses) configured for the market
     *      2. For each token, skips if it matches the vault's underlying asset (to avoid double counting)
     *      3. Gets the token balance held by the vault and skips the token when the balance is zero
     *      4. Retrieves the token price from price oracle middleware (only for held tokens)
     *      5. Converts balance to USD value normalized to WAD (18 decimals)
     *      6. Sums all token balances and returns the total
     * @dev The price is read only for tokens the vault actually holds, so a granted token without a price
     *      (the middleware reverts) does not block the whole market while its balance is zero. A held token
     *      without a price still reverts. Residual: anyone can transfer 1 wei of a granted unpriced token to
     *      the vault and restore the revert; unblock by adding the price to the middleware or removing the
     *      substrate from the market.
     * @return The total balance of all ERC20 tokens in USD, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory vaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = vaults.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address asset;
        uint256 tokenBalance;
        uint256 price;
        uint256 priceDecimals;
        address underlyingAsset = IERC4626(address(this)).asset();
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            asset = PlasmaVaultConfigLib.bytes32ToAddress(vaults[i]);
            if (address(asset) == underlyingAsset) {
                continue;
            }
            tokenBalance = IERC20(asset).balanceOf(address(this));
            if (tokenBalance == 0) {
                continue;
            }
            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(asset);

            balance += IporMath.convertToWad(tokenBalance * price, IERC20Metadata(asset).decimals() + priceDecimals);
        }

        return balance;
    }
}
