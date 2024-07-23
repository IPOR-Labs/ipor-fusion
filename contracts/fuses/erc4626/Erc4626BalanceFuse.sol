// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../priceOracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

contract ERC4626BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 private constant PRICE_DECIMALS = 8;
    uint256 public immutable MARKET_ID;

    IPriceOracleMiddleware public immutable PRICE_ORACLE;

    constructor(uint256 marketId_, address priceOracle_) {
        MARKET_ID = marketId_;
        PRICE_ORACLE = IPriceOracleMiddleware(priceOracle_);
    }

    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        bytes32[] memory vaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = vaults.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 vaultAssets;
        IERC4626 vault;
        address asset;

        for (uint256 i; i < len; ++i) {
            vault = IERC4626(PlasmaVaultConfigLib.bytes32ToAddress(vaults[i]));
            vaultAssets = vault.convertToAssets(vault.balanceOf(plasmaVault_));
            asset = vault.asset();
            balance += IporMath.convertToWad(
                vaultAssets * PRICE_ORACLE.getAssetPrice(asset),
                IERC20Metadata(asset).decimals() + PRICE_DECIMALS
            );
        }

        return balance;
    }
}
