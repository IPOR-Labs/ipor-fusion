// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IERC4626, IBorrowing} from "./ext/IEVault.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @title Fuse for Euler V2 vaults responsible for calculating the balance of the Plasma Vault in Euler V2 vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the vaults that are used in the Euler V2 protocol for a given MARKET_ID
contract EulerV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @return The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory vaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = vaults.length;

        if (len == 0) {
            return 0;
        }

        int256 netBalance;
        int256 balanceInLoop;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address vault;
        address underlyingAsset;
        uint256 underlyingAssetDecimals;
        uint256 price; // @dev price represented in 8 decimals
        uint256 priceDecimals;

        for (uint256 i; i < len; i++) {
            vault = PlasmaVaultConfigLib.bytes32ToAddress(vaults[i]);
            underlyingAsset = IERC4626(vault).asset();
            underlyingAssetDecimals = ERC20(underlyingAsset).decimals();
            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(underlyingAsset);

            if (price == 0) {
                revert Errors.UnsupportedQuoteCurrencyFromOracle();
            }

            balanceInLoop =
                IporMath.convertToWadInt(
                    int256(IERC4626(vault).convertToAssets(ERC20(vault).balanceOf(address(this)))) * int256(price),
                    ERC20(underlyingAsset).decimals() + priceDecimals
                ) -
                IporMath.convertToWadInt(
                    int256(IBorrowing(vault).debtOf(address(this))) * int256(price),
                    ERC20(underlyingAsset).decimals() + priceDecimals
                );

            netBalance += balanceInLoop;
        }

        return netBalance.toUint256();
    }
}
