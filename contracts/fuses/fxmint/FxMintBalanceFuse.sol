// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFxPool, IFxPoolConfiguration} from "./ext/IFxPool.sol";
import {FxMintFuseLib} from "./lib/FxMintFuseLib.sol";

/// @title FxMintBalanceFuse
/// @notice USD value (WAD) of the vault's f(x) Protocol v2 positions in the granted pools:
///         collateral exit value (net of the f(x) withdraw fee) - fxUSD debt, both priced by the vault's
///         PriceOracleMiddleware (collateral token and fxUSD need price sources). Saturates at 0.
contract FxMintBalanceFuse is IMarketBalanceFuse {
    uint256 private constant FEE_PRECISION = 1e9;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    error FxMintBalanceFuseZeroPrice(address asset);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function balanceOf() external view override returns (uint256) {
        bytes32[] memory pools = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = pools.length;
        if (len == 0) return 0;

        address middleware = PlasmaVaultLib.getPriceOracleMiddleware();
        int256 total;
        for (uint256 i; i < len; ++i) {
            total += _poolValue(PlasmaVaultConfigLib.bytes32ToAddress(pools[i]), middleware);
        }
        return total > 0 ? uint256(total) : 0;
    }

    function _poolValue(address pool_, address middleware_) private view returns (int256) {
        (uint256 positionId, uint256 rawColls, uint256 rawDebts) = FxMintFuseLib.position(pool_);
        if (positionId == 0 || (rawColls == 0 && rawDebts == 0)) return 0;

        address collateral = IFxPool(pool_).collateralToken();
        uint256 amount = FxMintFuseLib.collateralAmount(pool_, rawColls);
        (, uint256 withdrawFee, , ) = IFxPoolConfiguration(IFxPool(pool_).configuration()).getPoolFeeRatio(
            pool_,
            address(this)
        );
        amount = withdrawFee >= FEE_PRECISION ? 0 : (amount * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;

        int256 value = int256(_usd(middleware_, collateral, amount));
        if (rawDebts != 0) value -= int256(_usd(middleware_, IFxPool(pool_).fxUSD(), rawDebts));
        return value;
    }

    function _usd(address middleware_, address asset_, uint256 amount_) private view returns (uint256) {
        if (amount_ == 0) return 0;
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(middleware_).getAssetPrice(asset_);
        if (price == 0) revert FxMintBalanceFuseZeroPrice(asset_);
        return IporMath.convertToWad(amount_ * price, IERC20Metadata(asset_).decimals() + priceDecimals);
    }
}
