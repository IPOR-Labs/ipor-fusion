// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IWethEthAdapter
/// @notice Interface for the WethEthAdapter contract.
interface IWethEthAdapter {
    function VAULT() external view returns (address);
    function WETH() external view returns (address);

    /// @notice Unwrap WETH to ETH and call a zapper with ETH; rewrap leftovers and return to VAULT.
    function callZapperWithEth(
        address zapper,
        bytes calldata callData,
        uint256 collAmount,
        uint256 wethAmount,
        uint256 minEthToSpend
    ) external;

    /// @notice Call zapper expecting ETH back; wrap all received ETH to WETH and send tokens to VAULT.
    function callZapperExpectEthBack(
        address zapper,
        bytes calldata callData
    ) external;
}
