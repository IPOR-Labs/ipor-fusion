// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title Generic fuse for ERC4626 vaults responsible for calculating the balance of the Plasma Vault in the ERC4626 vaults based on preconfigured market substrates
 * @notice Calculates the total balance of ERC4626 vault shares held by the Plasma Vault, converted to underlying asset value in USD
 * @dev Substrates in this fuse are the ERC4626 vault addresses that are used for a given MARKET_ID.
 *      PriceFeed for underlying asset of the ERC4626 vaults have to be configured in Price Oracle Middleware Manager or Price Oracle Middleware.
 *      This fuse iterates through all configured ERC4626 vaults, retrieves the vault shares balance,
 *      converts shares to underlying assets, and converts to USD using price oracle middleware.
 */
contract Erc4626BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (ERC4626 vault addresses)
    uint256 public immutable MARKET_ID;

    /**
     * @notice Initializes the Erc4626BalanceFuse with a specific market ID
     * @param marketId_ The market ID used to identify the ERC4626 vault substrates
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Calculates the total balance of ERC4626 vault shares held by the Plasma Vault
     * @dev This function:
     *      1. Retrieves all substrates (ERC4626 vault addresses) configured for the market
     *      2. For each vault, gets the vault shares balance held by the Plasma Vault
     *      3. Converts vault shares to underlying assets using convertToAssets()
     *      4. Retrieves the underlying asset price from price oracle middleware
     *      5. Converts underlying asset amount to USD value normalized to WAD (18 decimals)
     *      6. Sums all vault balances and returns the total
     * @return The total balance of all ERC4626 vaults in USD, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory vaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = vaults.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 vaultAssets;
        IERC4626 vault;
        address asset;
        uint256 price;
        uint256 priceDecimals;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address plasmaVault = address(this);

        for (uint256 i; i < len; ++i) {
            vault = IERC4626(PlasmaVaultConfigLib.bytes32ToAddress(vaults[i]));
            vaultAssets = vault.convertToAssets(vault.balanceOf(plasmaVault));
            asset = vault.asset();
            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(asset);
            balance += IporMath.convertToWad(vaultAssets * price, IERC20Metadata(asset).decimals() + priceDecimals);
        }

        return balance;
    }
}
