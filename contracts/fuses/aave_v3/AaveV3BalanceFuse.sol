// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IAavePriceOracle} from "./IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "./IAavePoolDataProvider.sol";
import {AaveConstants} from "./AaveConstants.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlazmaVaultConfigLib} from "../../libraries/PlazmaVaultConfigLib.sol";

contract AaveV3BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;

    /// @dev Aave Price Oracle base currency decimals
    uint256 private constant AAVE_ORACLE_BASE_CURRENCY_DECIMALS = 8;

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
    }

    function balanceOf(address plazmaVault) external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlazmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;

        if (len == 0) {
            return 0;
        }

        int256 balanceTemp = 0;
        int256 balanceInLoop;
        uint256 decimals;
        // @dev this value has 8 decimals
        uint256 price;
        address asset;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            asset = PlazmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            decimals = ERC20(asset).decimals();
            price = IAavePriceOracle(AaveConstants.ETHEREUM_AAVE_PRICE_ORACLE_MAINNET).getAssetPrice(asset);

            (aTokenAddress, stableDebtTokenAddress, variableDebtTokenAddress) = IAavePoolDataProvider(
                AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET
            ).getReserveTokensAddresses(asset);

            if (aTokenAddress != address(0)) {
                balanceInLoop += int256(ERC20(aTokenAddress).balanceOf(plazmaVault));
            }
            if (stableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(stableDebtTokenAddress).balanceOf(plazmaVault));
            }
            if (variableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(variableDebtTokenAddress).balanceOf(plazmaVault));
            }

            balanceTemp += IporMath.convertToWadInt(
                balanceInLoop * int256(price),
                decimals + AAVE_ORACLE_BASE_CURRENCY_DECIMALS
            );
        }

        return balanceTemp.toUint256();
    }
}
