// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IStabilityPool {
    function provideToSP(uint256 _amount, bool _doClaim) external;

    function withdrawFromSP(uint256 _amount, bool _doClaim) external;

    function claimAllCollGains() external;

    function stashedColl(address _depositor) external view returns (uint256);

    function deposits(address _depositor) external view returns (uint256);

    function troveManager() external view returns (address);

    function offset(uint256 _debtToOffset, uint256 _collToAdd) external;

    /// @notice Get the current compounded BOLD deposit for a depositor (after accounting for liquidations)
    /// @param _depositor The address of the depositor
    /// @return The compounded deposit amount
    function getCompoundedBoldDeposit(address _depositor) external view returns (uint256);

    /// @notice Get the unrealized collateral gain for a depositor from liquidations
    /// @param _depositor The address of the depositor
    /// @return The collateral gain amount
    function getDepositorCollGain(address _depositor) external view returns (uint256);

    /// @notice Get the unrealized BOLD yield gain for a depositor from interest
    /// @param _depositor The address of the depositor
    /// @return The yield gain amount
    function getDepositorYieldGain(address _depositor) external view returns (uint256);
}
