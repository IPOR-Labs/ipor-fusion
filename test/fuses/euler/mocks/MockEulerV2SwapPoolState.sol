// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IEulerV2Swap} from "../../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";

/// @title MockEulerV2SwapPoolState
/// @notice EulerSwap pool stand-in for the valuation tests of EulerV2BalanceFuse (IL-9706): the views the balance fuse
///         reads (`getStaticParams`, `getDynamicParams`, `getAssets`, `getReserves`) with state set by the test, and a
///         switch that makes `getReserves` revert `Locked()` as the `nonReentrantView` getter of a real pool does in the
///         middle of a swap. It has no ERC-4626 or EVK view: a fuse that reads a pool entry as an eVault row reverts.
contract MockEulerV2SwapPoolState {
    /// @notice Same selector as EulerSwap `EulerSwapBase.Locked()`
    error Locked();

    IEulerV2Swap.StaticParams internal _staticParams;
    IEulerV2Swap.DynamicParams internal _dynamicParams;

    address public asset0;
    address public asset1;

    uint112 public reserve0;
    uint112 public reserve1;

    bool public locked;

    constructor(address asset0_, address asset1_, address eulerAccount_) {
        asset0 = asset0_;
        asset1 = asset1_;
        _staticParams.eulerAccount = eulerAccount_;
    }

    function setStaticParams(IEulerV2Swap.StaticParams memory staticParams_) external {
        _staticParams = staticParams_;
    }

    function setEulerAccount(address eulerAccount_) external {
        _staticParams.eulerAccount = eulerAccount_;
    }

    function setDynamicParams(IEulerV2Swap.DynamicParams memory dynamicParams_) external {
        _dynamicParams = dynamicParams_;
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
    }

    function setLocked(bool locked_) external {
        locked = locked_;
    }

    function getStaticParams() external view returns (IEulerV2Swap.StaticParams memory) {
        return _staticParams;
    }

    function getDynamicParams() external view returns (IEulerV2Swap.DynamicParams memory) {
        return _dynamicParams;
    }

    function getAssets() external view returns (address, address) {
        return (asset0, asset1);
    }

    /// @dev Status 1 = activated and unlocked, as in EulerSwap
    function getReserves() external view returns (uint112, uint112, uint32) {
        if (locked) {
            revert Locked();
        }
        return (reserve0, reserve1, 1);
    }
}
