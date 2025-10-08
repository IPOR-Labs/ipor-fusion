// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ILeverageZapper} from "./ILeverageZapper.sol";

/// @title IWethEthAdapter
/// @notice Interface for the WethEthAdapter contract.
interface IWethEthAdapter {
    function VAULT() external view returns (address);
    function WETH() external view returns (address);

    /// @notice Unwrap WETH to ETH and call a zapper with ETH; rewrap leftovers and return to VAULT.
    function callZapperWithEth(
        ILeverageZapper.OpenLeveragedTroveParams calldata params,
        address zapper,
        uint256 wethAmount
    ) external;

    /// @notice Call zapper expecting ETH back; wrap all received ETH to WETH and send tokens to VAULT.
    function callZapperExpectEthBack(
        address zapper,
        bool exitFromCollateral,
        uint256 troveId,
        uint256 flashLoanAmount,
        uint256 minExpectedCollateral
    ) external;
}
