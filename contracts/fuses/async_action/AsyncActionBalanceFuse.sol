// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {AsyncActionFuseLib} from "./AsyncActionFuseLib.sol";
import {AsyncExecutor} from "./AsyncExecutor.sol";
import {console2} from "forge-std/console2.sol";

/// @title AsyncActionBalanceFuse
/// @notice Provides USD-denominated valuation of assets managed by the async action executor
/// @dev Reads cached balance (expressed in underlying asset units) from AsyncExecutor and converts it to USD
/// @author IPOR Labs
contract AsyncActionBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when price oracle middleware is not configured in the plasma vault
    /// @custom:error AsyncActionBalanceFuseInvalidPriceOracleMiddleware
    error AsyncActionBalanceFuseInvalidPriceOracleMiddleware();

    /// @notice Identifier of the market this balance fuse is associated with
    uint256 public immutable MARKET_ID;

    /// @notice Sets the immutable market identifier handled by this fuse
    /// @param marketId_ Unique identifier of the market handled by this fuse
    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice Returns the USD value of the assets tracked by the async executor
    /// @return balanceValueUsd Balance expressed in 18-decimal USD precision (WAD format)
    /// @dev Reads cached balance from AsyncExecutor (in underlying asset units), fetches price from oracle,
    ///      and converts to USD using IporMath.convertToWad. Returns 0 if executor doesn't exist or balance is zero.
    ///      Requires price oracle middleware to be configured in the Plasma Vault.
    function balanceOf() external view override returns (uint256 balanceValueUsd) {
        address executor = AsyncActionFuseLib.getAsyncExecutor();

        if (executor == address(0)) {
            return 0;
        }

        uint256 balanceInUnderlying = AsyncExecutor(payable(executor)).balance();
        console2.log("balanceInUnderlying", balanceInUnderlying);

        if (balanceInUnderlying == 0) {
            return 0;
        }

        address underlyingAsset = IERC4626(address(this)).asset();
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware == address(0)) {
            revert AsyncActionBalanceFuseInvalidPriceOracleMiddleware();
        }

        (uint256 price, uint256 priceDecimals) =
            IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(underlyingAsset);
        uint256 underlyingDecimals = IERC20Metadata(underlyingAsset).decimals();

        // Convert balance * price to WAD (18 decimals) accounting for both price and underlying decimals
        balanceValueUsd = IporMath.convertToWad(
            balanceInUnderlying * price, underlyingDecimals + priceDecimals
        );
    }
}
