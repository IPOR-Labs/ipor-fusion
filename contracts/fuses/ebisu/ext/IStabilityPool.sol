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
}
