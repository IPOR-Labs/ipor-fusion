// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMarketBalanceFuse} from "../../../contracts/fuses/IMarketBalanceFuse.sol";

/// @title SettableBalanceFuseMock
/// @notice Test-only balance fuse (IL-7976 regression coverage) whose reported balance is externally
/// controllable.
/// @dev balanceOf() is invoked by PlasmaVault via delegatecall, so it executes in the *vault's* storage
/// context, not this contract's own storage. The value is therefore read from a fixed, namespaced
/// storage slot that tests write directly with `vm.store(address(vault), BALANCE_SLOT, bytes32(value))`
/// - this cannot collide with PlasmaVault's real ERC-7201 storage slots because the slot is derived
/// from a distinct, test-only namespace string.
contract SettableBalanceFuseMock is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    /// @dev keccak256("io.ipor.test.SettableBalanceFuseMock.v1")
    bytes32 public constant BALANCE_SLOT = 0x5cb88e2414a1b8b1d09377ac199baab10cecec8a1a6f798592534228a448ec02;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function balanceOf() external view override returns (uint256 balanceValue) {
        bytes32 slot = BALANCE_SLOT;
        assembly {
            balanceValue := sload(slot)
        }
    }
}
