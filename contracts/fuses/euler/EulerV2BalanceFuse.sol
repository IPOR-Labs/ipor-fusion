// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

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

/**
 * @title Fuse for Euler V2 vaults responsible for calculating the balance of the Plasma Vault in Euler V2 vaults based on preconfigured market substrates
 * @notice Calculates the net balance (collateral - debt) of the Plasma Vault across all configured Euler V2 vaults
 * @dev Substrates in this fuse are the Euler V2 vault addresses that are used for a given MARKET_ID.
 *      This fuse iterates through all configured substrates, calculates collateral value from ERC4626 vault shares,
 *      subtracts debt value, and returns the net balance in USD normalized to WAD (18 decimals).
 */
contract EulerV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (Euler V2 vault addresses)
    uint256 public immutable MARKET_ID;

    /// @notice Ethereum Vault Connector (EVC) address for Euler V2 protocol
    /// @dev Immutable value set in constructor, used for Euler V2 protocol interactions
    IEVC public immutable EVC;

    /**
     * @notice Initializes the EulerV2BalanceFuse with a market ID and EVC address
     * @param marketId_ The market ID used to identify the Euler V2 vault substrates
     * @param eulerV2EVC_ The address of the Ethereum Vault Connector for Euler V2 protocol (must not be address(0))
     * @dev Reverts if eulerV2EVC_ is zero address
     */
    constructor(uint256 marketId_, address eulerV2EVC_) {
        if (eulerV2EVC_ == address(0)) {
            revert Errors.WrongAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /**
     * @notice Calculates the net balance (collateral - debt) of the Plasma Vault in Euler V2 vaults
     * @dev This function:
     *      1. Retrieves all substrates (Euler V2 vault addresses) configured for the market
     *      2. For each vault, generates the sub-account address for the Plasma Vault
     *      3. Calculates collateral value: converts ERC4626 vault shares to underlying assets and converts to USD
     *      4. Calculates debt value: retrieves debt from the vault and converts to USD
     *      5. Subtracts debt from collateral to get net balance
     *      6. Returns the total net balance normalized to WAD (18 decimals)
     *      The price oracle middleware provides prices in USD with its own decimal precision.
     *      All values are normalized to WAD (18 decimals) using IporMath.convertToWad().
     * @return The net balance (collateral - debt) of the Plasma Vault in USD, normalized to WAD (18 decimals)
     * @custom:revert Errors.UnsupportedQuoteCurrencyFromOracle When price oracle cannot provide a price for the asset
     */
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
