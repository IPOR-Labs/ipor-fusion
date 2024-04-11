// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IIporPriceOracle} from "../../priceOracle/IIporPriceOracle.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {Errors} from "./../../libraries/errors/Errors.sol";

contract ERC4626BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IIporPriceOracle public immutable PRICE_ORACLE;

    constructor(uint256 marketIdInput, address priceOracle) {
        MARKET_ID = marketIdInput;
        PRICE_ORACLE = priceOracle;
    }

    function balanceOf(address plazmaVault) external view override returns (uint256) {
        bytes32[] memory vaults = MarketConfigurationLib.getMarketConfigurationSubstrates(MARKET_ID);

        uint256 len = vaults.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance = 0;
        uint256 vaultAssets;
        uint256 decimals;
        // @dev this value has 8 decimals
        uint256 assetPrice;
        address vaultAddress;
        IERC4626 vault;

        for (uint256 i; i < len; ++i) {
            vaultAddress = MarketConfigurationLib.bytes32ToAddress(vaults[i]);
            vault = IERC4626(vaultAddress);
            vaultAssets = vault.convertToAssets(vault.balanceOf(plazmaVault));
            balance += IporMath.convertToWad(
                vaultAssets * PRICE_ORACLE.getAssetPrice(vault.asset()),
                vault.decimals() + PRICE_DECIMALS
            );
        }

        return balance;
    }
}
