// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Minimal ERC20 mock with configurable balances and decimals used in MidasBalanceFuse unit tests.
contract MockERC20ForBalance {
    mapping(address => uint256) private _balances;
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function setBalance(address account_, uint256 balance_) external {
        _balances[account_] = balance_;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function balanceOf(address account_) external view returns (uint256) {
        return _balances[account_];
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
