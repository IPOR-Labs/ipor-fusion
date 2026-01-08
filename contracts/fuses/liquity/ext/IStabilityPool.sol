// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IStabilityPool {
    function provideToSP(uint256 amount_, bool doClaim_) external;

    function withdrawFromSP(uint256 amount_, bool doClaim_) external;

    function claimAllCollGains() external;

    function stashedColl(address depositor_) external view returns (uint256);

    function deposits(address depositor_) external view returns (uint256);

    function troveManager() external view returns (address);

    function offset(uint256 debtToOffset_, uint256 collToAdd_) external;

    /// @notice Get the current compounded BOLD deposit for a depositor (after accounting for liquidations)
    /// @param depositor_ The address of the depositor
    /// @return The compounded deposit amount
    function getCompoundedBoldDeposit(address depositor_) external view returns (uint256);

    /// @notice Get the unrealized collateral gain for a depositor from liquidations
    /// @param depositor_ The address of the depositor
    /// @return The collateral gain amount
    function getDepositorCollGain(address depositor_) external view returns (uint256);

    /// @notice Get the unrealized BOLD yield gain for a depositor from interest
    /// @param depositor_ The address of the depositor
    /// @return The yield gain amount
    function getDepositorYieldGainWithPending(address depositor_) external view returns (uint256);
}
