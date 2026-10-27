// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface ICrosschainExecutorV2 {
    function MANAGER() external view returns (address);
    function ASSET() external view returns (address);
    function ASSET_ID() external view returns (bytes32);
    function FACTORY() external view returns (address);
    function getBalance() external view returns (uint256);
    /// @dev Per-chain booked component in local ASSET decimals. CCIP: fail-closed like `getBalance()`
    ///      (`ChainBlocked` / `TransferStale` / `ObservationStale`); Stargate: a raw sum of the three booked buckets
    ///      with no `ChainBlocked` or staleness gates (IL-9066). Never use it to price anything.
    function getBalanceByChain(uint256 chainId_) external view returns (uint256);
    function claimAsset(uint256 amount_) external;
    function isDispatcherReady(uint256 chainId_) external view returns (bool);
}
