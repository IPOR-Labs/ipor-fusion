// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal ERC20 mock for MidasClaimFromExecutorFuse unit tests.
///         Supports minting arbitrary amounts to simulate executor token balances.
contract MockERC20ForClaim is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint tokens to any address (unrestricted, for test setup)
    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}
