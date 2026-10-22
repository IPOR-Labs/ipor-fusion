// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface ICrosschainExecutorV2 {
    function MANAGER() external view returns (address);
    function ASSET() external view returns (address);
    function ASSET_ID() external view returns (bytes32);
    function FACTORY() external view returns (address);
    function getBalance() external view returns (uint256);
    function getBalanceByChain(uint256 chainId_) external view returns (uint256);
    function claimAsset(uint256 amount_) external;
    function isDispatcherReady(uint256 chainId_) external view returns (bool);
}
