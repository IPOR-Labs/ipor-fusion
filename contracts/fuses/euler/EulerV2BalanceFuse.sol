// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IEVC} from "@ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {EulerFuseLib, EulerSubstrate} from "./EulerFuseLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IBorrowing} from "./ext/IBorrowing.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @title Fuse for Euler V2 vaults responsible for calculating the balance of the Plasma Vault in Euler V2 vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the vaults that are used in the Euler V2 protocol for a given MARKET_ID
contract EulerV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
        if (eulerV2EVC_ == address(0)) {
            revert Errors.WrongAddress();
        }
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @return The balance of the Plasma Vault associated with Fuse Balance marketId in USD, represented in 8 decimals
    /// @dev The balance is calculated as the sum of the balance of the underlying assets in the vaults minus the debt in the vaults
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        int256 balance;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address plasmaVault = address(this);
        address eulerVaultAsset;
        uint256 eulerVaultAssetDecimals;
        uint256 price; // @dev price represented in 8 decimals (USD is quote asset)
        uint256 priceDecimals;
        uint256 balanceOfSubAccountInEulerVault;
        uint256 balanceOfSubAccountInUnderlyingAsset;
        EulerSubstrate memory substrate;
        address subAccount;

        for (uint256 i; i < len; ++i) {
            substrate = EulerFuseLib.bytes32ToSubstrate(substrates[i]);

            eulerVaultAsset = ERC4626(substrate.eulerVault).asset();

            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(eulerVaultAsset);

            if (price == 0) {
                revert Errors.UnsupportedQuoteCurrencyFromOracle();
            }

            subAccount = EulerFuseLib.generateSubAccountAddress(plasmaVault, substrate.subAccounts);

            eulerVaultAssetDecimals = IERC20Metadata(eulerVaultAsset).decimals();

            balanceOfSubAccountInEulerVault = ERC4626(substrate.eulerVault).balanceOf(subAccount);

            if (balanceOfSubAccountInEulerVault > 0) {
                balanceOfSubAccountInUnderlyingAsset = ERC4626(substrate.eulerVault).convertToAssets(
                    balanceOfSubAccountInEulerVault
                );
                balance += IporMath
                    .convertToWad(balanceOfSubAccountInUnderlyingAsset * price, eulerVaultAssetDecimals + priceDecimals)
                    .toInt256();
            }

            balance -= IporMath
                .convertToWad(
                    IBorrowing(substrate.eulerVault).debtOf(subAccount) * price,
                    eulerVaultAssetDecimals + priceDecimals
                )
                .toInt256();
        }

        /// @dev This value, considering collateral and debt, should never be negative
        return balance.toUint256();
    }
}
