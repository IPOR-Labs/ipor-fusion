// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/// @notice Abstract for PlasmaVault where is fusion of ERC20, ERC4626, ERC20Permit, ERC20Votes standards.
abstract contract PlasmaVaultErc20Fusion is ERC20, ERC4626, ERC20Permit, ERC20Votes {
    constructor(
        string memory name,
        string memory symbol,
        address underlyingAsset
    ) ERC20(name, symbol) ERC20Permit(name) ERC4626(IERC20Metadata(underlyingAsset)) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        ERC20Votes._update(from, to, amount);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
