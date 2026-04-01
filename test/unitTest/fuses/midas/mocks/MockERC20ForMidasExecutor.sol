// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20ForMidasExecutor
/// @notice Minimal ERC20 mock with configurable decimals for MidasExecutor unit tests.
///         Tracks forceApprove call history for assertion in ordering tests.
///         Also tracks transfer() calls to assert guard conditions (e.g. `if (amount > 0)`).
contract MockERC20ForMidasExecutor is ERC20 {
    uint8 private _decimalsOverride;

    // Records of forceApprove calls in order: (spender, amount)
    address[] public approveSpenders;
    uint256[] public approveAmounts;

    // Transfer call tracking
    uint256 private _transferCallCount;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsOverride = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsOverride;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Overrides forceApprove via approve (ERC20 allows this).
    ///      The real SafeERC20.forceApprove calls ERC20.approve under the hood.
    ///      We override approve to record calls while still setting the real allowance.
    function approve(address spender, uint256 amount) public override returns (bool) {
        approveSpenders.push(spender);
        approveAmounts.push(amount);
        return super.approve(spender, amount);
    }

    /// @notice Returns total number of approve calls recorded
    function approveCallCount() external view returns (uint256) {
        return approveSpenders.length;
    }

    /// @notice Clears recorded approve history (useful for test isolation)
    function clearApproveHistory() external {
        delete approveSpenders;
        delete approveAmounts;
    }

    /// @dev Overrides transfer to count calls — used to assert that safeTransfer is NOT
    ///      called when balance is zero (kills the `if (amount > 0)` guard-removal mutant).
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferCallCount++;
        return super.transfer(to, amount);
    }

    /// @notice Returns total number of transfer() calls recorded
    function transferCallCount() external view returns (uint256) {
        return _transferCallCount;
    }
}
