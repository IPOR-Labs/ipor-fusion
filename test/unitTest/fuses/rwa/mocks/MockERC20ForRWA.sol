// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20ForRWA
/// @notice Minimal ERC20 mock with configurable decimals, used by RWA unit tests.
contract MockERC20ForRWA is ERC20 {
    uint8 private _decimalsOverride;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsOverride = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsOverride;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function burn(address from_, uint256 amount_) external {
        _burn(from_, amount_);
    }
}
