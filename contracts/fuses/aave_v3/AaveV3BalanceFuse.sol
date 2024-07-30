// SPDX-License-Identifier: BUSL-1.1
/**
 * @title AaveV3BalanceFuse
 * This contract is used for calculate balance of the Plasma Vault in AAVE Protocol version 3.
 * All actions performed by the code from this fuse are executed in the context of the Plasma Vault and are invoked using delegateCall.
 * Before using this fuse, should contain the AaveV3SupplyFuse and it should be configurate in the Plasma Vault.
 *
 * Deploy:
 * To deploy a new implementation, the following parameters must be provided:
 * - marketIdInput - This should be selected from the IporFusionMarkets*.sol file the same value as in AaveV3SupplyFuse.
 * - aavePriceOracle - The address of the AAVE Pool contract.
 * - aavePoolDataProviderV3_ - The address of the AAVE Pool Data Provider V3 contract.
 *
 *
 * Uses in Plasma Vault:
 * - Add fuse to Plasma Vault
 *      To add a balance fuse to the Plasma Vault, call the method addBalanceFuse(uint256 marketId_, address fuse_),
 *      where marketId_ is the market provided during deployment, and fuse_ is the address of the fuse.
 *
 */
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IAavePriceOracle} from "./ext/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "./ext/IAavePoolDataProvider.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

contract AaveV3BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;

    /// @dev Aave Price Oracle base currency decimals
    uint256 private constant AAVE_ORACLE_BASE_CURRENCY_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    address public immutable AAVE_PRICE_ORACLE;
    address public immutable AAVE_POOL_DATA_PROVIDER_V3;

    constructor(uint256 marketIdInput, address aavePriceOracle, address aavePoolDataProviderV3) {
        MARKET_ID = marketIdInput;
        AAVE_PRICE_ORACLE = aavePriceOracle;
        AAVE_POOL_DATA_PROVIDER_V3 = aavePoolDataProviderV3;
    }

    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

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
            asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            decimals = ERC20(asset).decimals();
            price = IAavePriceOracle(AAVE_PRICE_ORACLE).getAssetPrice(asset);

            if (price == 0) {
                revert Errors.UnsupportedBaseCurrencyFromOracle();
            }

            (aTokenAddress, stableDebtTokenAddress, variableDebtTokenAddress) = IAavePoolDataProvider(
                AAVE_POOL_DATA_PROVIDER_V3
            ).getReserveTokensAddresses(asset);

            if (aTokenAddress != address(0)) {
                balanceInLoop += int256(ERC20(aTokenAddress).balanceOf(plasmaVault_));
            }
            if (stableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(stableDebtTokenAddress).balanceOf(plasmaVault_));
            }
            if (variableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(variableDebtTokenAddress).balanceOf(plasmaVault_));
            }

            balanceTemp += IporMath.convertToWadInt(
                balanceInLoop * int256(price),
                decimals + AAVE_ORACLE_BASE_CURRENCY_DECIMALS
            );
        }

        return balanceTemp.toUint256();
    }
}
