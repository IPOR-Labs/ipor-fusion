// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.26;

interface IAavePoolDataProvider {
    /**
     * @notice Returns the token addresses of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return aTokenAddress The AToken address of the reserve
     * @return stableDebtTokenAddress The StableDebtToken address of the reserve
     * @return variableDebtTokenAddress The VariableDebtToken address of the reserve
     */
    function getReserveTokensAddresses(
        address asset
    ) external view returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
}
