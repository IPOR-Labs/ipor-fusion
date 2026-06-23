// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IEulerV2Swap} from "../../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";

/// @title MockEulerV2SwapPool
/// @notice Mock EulerSwap pool implementing the {IEulerV2Swap} getters/mutators used by the fuses.
contract MockEulerV2SwapPool {
    IEulerV2Swap.StaticParams internal _staticParams;
    IEulerV2Swap.DynamicParams internal _dynamicParams;
    IEulerV2Swap.InitialState internal _initialState;

    address public asset0;
    address public asset1;

    bool public reconfigured;
    uint256 public reconfigureCallCount;

    address public lastManager;
    bool public lastInstalled;
    uint256 public setManagerCallCount;

    function setStaticParams(IEulerV2Swap.StaticParams memory sp) external {
        _staticParams = sp;
    }

    function getStaticParams() external view returns (IEulerV2Swap.StaticParams memory) {
        return _staticParams;
    }

    function getDynamicParams() external view returns (IEulerV2Swap.DynamicParams memory) {
        return _dynamicParams;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_initialState.reserve0, _initialState.reserve1, 0);
    }

    function setAssets(address asset0_, address asset1_) external {
        asset0 = asset0_;
        asset1 = asset1_;
    }

    function getAssets() external view returns (address, address) {
        return (asset0, asset1);
    }

    function reconfigure(IEulerV2Swap.DynamicParams memory dp, IEulerV2Swap.InitialState memory is_) external {
        _dynamicParams = dp;
        _initialState = is_;
        reconfigured = true;
        reconfigureCallCount++;
    }

    function setManager(address m, bool installed) external {
        lastManager = m;
        lastInstalled = installed;
        setManagerCallCount++;
    }

    function managers(address) external pure returns (bool) {
        return false;
    }

    function isInstalled() external pure returns (bool) {
        return true;
    }

    function activate(IEulerV2Swap.DynamicParams memory, IEulerV2Swap.InitialState memory) external {}
}
