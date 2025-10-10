// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IYieldBasisLT} from "./ext/IYieldBasisLT.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title Fuse for Yield Basis Leveraged Liquidity Token vaults responsible for calculating the balance of the Plasma Vault in the Yield Basis vaults
/// @dev Substrates in this fuse are the assets that are used in the Yield Basis vaults for a given MARKET_ID
/// @dev Notice! PriceFeed for underlying asset of the Yield Basis vaults have to be configured in Price Oracle Middleware Manager or Price Oracle Middleware
/// @dev Notice! This fuse is used for Yield Basis vaults that are not ERC4626 compatible
contract YieldBasisLtBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
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

            ltSharesInWad = lt.balanceOf(plasmaVault) * 10 ** (18 - lt.decimals());
            ltAssetsInWad = ltSharesInWad * lt.pricePerShare() / 1e18;

            (assetPrice, assetPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(lt.ASSET_TOKEN());

            balance += (ltAssetsInWad * assetPrice) / 10 ** assetPriceDecimals;
        }

        return balance;
    }
}
