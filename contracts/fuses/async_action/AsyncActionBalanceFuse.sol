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

/// @title AsyncActionBalanceFuse
/// @notice Provides USD-denominated valuation of assets managed by the async action executor
/// @dev Reads cached balance (expressed in underlying asset units) from AsyncExecutor and converts it to USD
/// @author IPOR Labs
contract AsyncActionBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when price oracle middleware is not configured in the plasma vault
    error AsyncActionBalanceFuseInvalidPriceOracleMiddleware();

    /// @notice Identifier of the market this balance fuse is associated with
    uint256 public immutable MARKET_ID;

    /// @notice Sets the immutable market identifier handled by this fuse
    /// @param marketId_ Unique identifier of the market handled by this fuse
    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice Returns the USD value of the assets tracked by the async executor
    /// @return balanceValueUsd_ Balance expressed in 18-decimal USD precision
    function balanceOf() external view override returns (uint256 balanceValueUsd_) {
        address executor_ = AsyncActionFuseLib.getAsyncExecutor();

        if (executor_ == address(0)) {
            return 0;
        }

        uint256 balanceInUnderlying_ = AsyncExecutor(payable(executor_)).balance();

        if (balanceInUnderlying_ == 0) {
            return 0;
        }

        address underlyingAsset_ = IERC4626(address(this)).asset();
        address priceOracleMiddleware_ = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware_ == address(0)) {
            revert AsyncActionBalanceFuseInvalidPriceOracleMiddleware();
        }

        (uint256 price_, uint256 priceDecimals_) =
            IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(underlyingAsset_);
        uint256 underlyingDecimals_ = IERC20Metadata(underlyingAsset_).decimals();

        balanceValueUsd_ = IporMath.convertToWad(
            balanceInUnderlying_ * price_, underlyingDecimals_ + priceDecimals_
        );
    }
}

