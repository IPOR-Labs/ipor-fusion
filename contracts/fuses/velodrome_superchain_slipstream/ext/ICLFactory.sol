// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface ICLFactory {
    /// @notice The address of the pool implementation contract used to deploy proxies / clones
    /// @return The address of the pool implementation contract
    function poolImplementation() external view returns (address);
}
