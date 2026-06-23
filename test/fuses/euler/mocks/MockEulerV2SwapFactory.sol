// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IEulerV2Swap} from "../../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";

/// @title MockEulerV2SwapFactory
/// @notice Mock EulerSwap factory with controllable compute/deploy results, compatible with
///         {IEulerV2SwapFactory} signatures.
contract MockEulerV2SwapFactory {
    address public computeResult;
    address public deployResult;
    bool public deployResultSet;
    bool public deployedPoolsResult = true;

    address public lastEulerAccount;
    uint256 public deployCallCount;

    function setComputeResult(address a) external {
        computeResult = a;
    }

    function setDeployedPoolsResult(bool v) external {
        deployedPoolsResult = v;
    }

    function setDeployResult(address a) external {
        deployResult = a;
        deployResultSet = true;
    }

    function computePoolAddress(
        IEulerV2Swap.StaticParams memory,
        bytes32
    ) external view returns (address) {
        return computeResult;
    }

    function deployPool(
        IEulerV2Swap.StaticParams memory sp,
        IEulerV2Swap.DynamicParams memory,
        IEulerV2Swap.InitialState memory,
        bytes32
    ) external returns (address) {
        lastEulerAccount = sp.eulerAccount;
        deployCallCount++;
        return deployResultSet ? deployResult : computeResult;
    }

    function deployedPools(address) external view returns (bool) {
        return deployedPoolsResult;
    }
}
