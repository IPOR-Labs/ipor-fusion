// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20ForSupplyFuse
/// @notice Minimal ERC20 mock with configurable decimals for MidasSupplyFuse unit tests.
///         Tracks forceApprove call history (via `approve`) for assertion in ordering tests.
///         Inherits from OZ ERC20 so SafeERC20.forceApprove works correctly.
contract MockERC20ForSupplyFuse is ERC20 {
    uint8 private _decimalsOverride;

    // Records of approve calls in order: (spender, amount)
    address[] public approveSpenders;
    uint256[] public approveAmounts;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsOverride = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsOverride;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Override approve so that SafeERC20.forceApprove calls are tracked.
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
}
