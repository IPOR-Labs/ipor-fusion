// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title Generic fuse for ERC4626 vaults responsible for calculating the balance of the Plasma Vault in the ERC4626 vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the ERC4626 vaults for a given MARKET_ID
/// @dev Notice! PriceFeed for underlying asset of the ERC4626 vaults have to be configured in Price Oracle Middleware Manager or Price Oracle Middleware
contract Erc4626BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @return The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
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
