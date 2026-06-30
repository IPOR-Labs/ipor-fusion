// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IAguaGlobalCarryVault} from "./ext/IAguaGlobalCarryVault.sol";
import {AguaSubstrateLib, AguaSubstrate, AguaSubstrateType} from "./lib/AguaSubstrateLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @title AguaBalanceFuse
/// @notice Balance fuse for the Agua Global Carry Vault, reporting NAV in USD (18 decimals).
/// @dev For each granted VAULT substrate the NAV has two legs, both denominated in the vault's
///      underlying asset (e.g. USDC), using the asset's own decimals, and then priced to 18-decimal USD via the oracle:
///        - free leg: `convertToAssets(balanceOf(PlasmaVault))` (live NAV of held shares);
///        - pending leg: `previewCompleteRedemption(PlasmaVault)` (frozen NAV of the escrowed
///          request; 0 when none).
///      Escrowed shares leave `balanceOf` (they are transferred into the Agua vault on request),
///      so they are valued exactly once via the frozen pending leg — no double-count, no undercount.
contract AguaBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when the price oracle middleware is not configured
    error AguaBalanceFusePriceOracleNotSet();

    /// @notice Address of this fuse contract version
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the fuse with a specific market ID
    /// @param marketId_ The market ID used to identify the Agua vault substrates
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Calculate the total Agua NAV held by the PlasmaVault in USD (18 decimals)
    /// @return balance Total balance in USD with 18 decimals
    function balanceOf() external view override returns (uint256 balance) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        address plasmaVault = address(this);
        AguaSubstrate memory substrate;

        for (uint256 i; i < len; ++i) {
            substrate = AguaSubstrateLib.bytes32ToSubstrate(substrates[i]);

            if (substrate.substrateType != AguaSubstrateType.VAULT) {
                continue;
            }

            address vault = substrate.substrateAddress;

            uint256 freeAssets = IAguaGlobalCarryVault(vault).convertToAssets(
                IAguaGlobalCarryVault(vault).balanceOf(plasmaVault)
            );
            uint256 pendingAssets = IAguaGlobalCarryVault(vault).previewCompleteRedemption(plasmaVault);
            uint256 assets = freeAssets + pendingAssets;

            if (assets == 0) {
                continue;
            }

            address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
            if (priceOracleMiddleware == address(0)) revert AguaBalanceFusePriceOracleNotSet();

            address asset = IAguaGlobalCarryVault(vault).asset();
            (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(asset);

            balance += IporMath.convertToWad(assets * price, IERC20Metadata(asset).decimals() + priceDecimals);
        }

        return balance;
    }
}
