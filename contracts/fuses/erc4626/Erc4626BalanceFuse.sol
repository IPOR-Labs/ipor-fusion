// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IIporPriceOracle} from "../../priceOracle/IIporPriceOracle.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

contract ERC4626BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 private constant PRICE_DECIMALS = 8;
    uint256 public immutable MARKET_ID;

    IIporPriceOracle public immutable PRICE_ORACLE;

    constructor(uint256 marketIdInput, address priceOracle) {
        MARKET_ID = marketIdInput;
        PRICE_ORACLE = IIporPriceOracle(priceOracle);
    }

    function balanceOf(address plasmaVault) external view override returns (uint256) {
        bytes32[] memory vaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = vaults.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 vaultAssets;
        IERC4626 vault;

        for (uint256 i; i < len; ++i) {
            vault = IERC4626(PlasmaVaultConfigLib.bytes32ToAddress(vaults[i]));
            vaultAssets = vault.convertToAssets(vault.balanceOf(plasmaVault));
            balance += IporMath.convertToWad(
                vaultAssets * PRICE_ORACLE.getAssetPrice(vault.asset()),
                vault.decimals() + PRICE_DECIMALS
            );
        }

        return balance;
    }
}
