// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IEulerV2Swap} from "../../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";

/// @title MockEulerV2SwapRegistry
/// @notice Mock EulerSwap registry tracking pool registration/unregistration and eulerAccount lookups.
contract MockEulerV2SwapRegistry {
    address public lastRegisteredPool;
    uint256 public lastBond;
    uint256 public registerCallCount;
    uint256 public unregisterCallCount;

    mapping(address => address) internal _poolByEulerAccount;

    function registerPool(address pool) external payable {
        lastRegisteredPool = pool;
        lastBond = msg.value;
        registerCallCount++;
        _poolByEulerAccount[IEulerV2Swap(pool).getStaticParams().eulerAccount] = pool;
    }

    function unregisterPool() external {
        unregisterCallCount++;
    }

    function poolByEulerAccount(address a) external view returns (address) {
        return _poolByEulerAccount[a];
    }

    function setPoolByEulerAccount(address account, address pool) external {
        _poolByEulerAccount[account] = pool;
    }

    function validityBond(address) external pure returns (uint256) {
        return 0;
    }

    function minimumValidityBond() external pure returns (uint256) {
        return 0;
    }
}
