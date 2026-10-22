// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IFxPool
/// @notice Minimal interface of an f(x) Protocol v2 long pool used by the FxMint fuses
interface IFxPool {
    function collateralToken() external view returns (address);

    function fxUSD() external view returns (address);

    function poolManager() external view returns (address);

    function configuration() external view returns (address);

    /// @return rawColls Collateral, scaled to 18 decimals (amount = rawColls * 1e18 / scalingFactor)
    /// @return rawDebts Debt in fxUSD (18 decimals)
    function getPosition(uint256 positionId) external view returns (uint256 rawColls, uint256 rawDebts);
}

/// @title IFxPoolConfiguration
/// @notice f(x) pool fee configuration (1e9 precision)
interface IFxPoolConfiguration {
    function getPoolFeeRatio(
        address pool,
        address recipient
    ) external view returns (uint256 supplyRatio, uint256 withdrawRatio, uint256 borrowRatio, uint256 repayRatio);
}

/// @title IFxPoolLimits
/// @notice f(x) pool risk parameters used to size instant withdrawals
interface IFxPoolLimits {
    function priceOracle() external view returns (address);

    /// @return minDebtRatio Lower debt ratio bound (1e18 = 100%)
    /// @return maxDebtRatio Upper debt ratio bound (1e18 = 100%)
    function getDebtRatioRange() external view returns (uint256 minDebtRatio, uint256 maxDebtRatio);
}

/// @title IFxPriceOracle
/// @notice f(x) collateral price oracle (USD, 18 decimals)
interface IFxPriceOracle {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}
