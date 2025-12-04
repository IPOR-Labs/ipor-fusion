// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IYieldBasisLT} from "./ext/IYieldBasisLT.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {FullMath} from "../ramses/ext/FullMath.sol";

/// @title Fuse for Yield Basis Leveraged Liquidity Token vaults responsible for calculating the balance of the Plasma Vault in the Yield Basis vaults
/// @dev Substrates in this fuse are the assets that are used in the Yield Basis LT tokens for a given MARKET_ID
/// @dev Notice! PriceFeed for underlying asset of the Yield Basis LT tokens have to be configured in Price Oracle Middleware Manager or Price Oracle Middleware
/// @dev Notice! This fuse is used for Yield Basis LT tokens that are not ERC4626 compatible
contract YieldBasisLtBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (Yield Basis LT token addresses)
    uint256 public immutable MARKET_ID;

    /**
     * @notice Initializes the YieldBasisLtBalanceFuse with a market ID
     * @param marketId_ The market ID used to identify the market and retrieve substrates
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @return balance The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256 balance) {
        bytes32[] memory lts = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = lts.length;

        if (len == 0) {
            return 0;
        }

        IYieldBasisLT lt;
        uint256 ltAssetsInWad;
        uint256 ltSharesInWad;
        uint256 assetPrice;
        uint256 assetPriceDecimals;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address plasmaVault = address(this);

        for (uint256 i; i < len; ++i) {
            lt = IYieldBasisLT(PlasmaVaultConfigLib.bytes32ToAddress(lts[i]));

            ltSharesInWad = IporMath.convertToWad(lt.balanceOf(plasmaVault), lt.decimals());
            ltAssetsInWad = (ltSharesInWad * lt.pricePerShare()) / 1e18;

            (assetPrice, assetPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(
                lt.ASSET_TOKEN()
            );

            balance += FullMath.mulDiv(ltAssetsInWad, assetPrice, 10 ** assetPriceDecimals);
        }

        return balance;
    }
}
