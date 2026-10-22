// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {BalancerBalanceFuse} from "contracts/fuses/balancer/BalancerBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";

/// @title BalancerBalanceFuseHarness
/// @notice Test harness that inherits BalancerBalanceFuse and exposes helpers to write to the
///         ERC-7201 storage slots used by PlasmaVaultConfigLib and PlasmaVaultLib.
///
///         When tests call balanceOf() on this harness, address(this) is the harness itself,
///         simulating the PlasmaVault delegatecall context (mirrors the pattern used in
///         test/unitTest/fuses/midas/mocks/MidasBalanceFuseHarness.sol).
contract BalancerBalanceFuseHarness is BalancerBalanceFuse {
    constructor(uint256 marketId_) BalancerBalanceFuse(marketId_) {}

    // ============ PlasmaVaultConfigLib helpers ============

    /// @notice Write market substrates directly to the ERC-7201 storage slot
    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    // ============ PlasmaVaultLib helpers ============

    /// @notice Set the price oracle middleware address in ERC-7201 storage
    function setPriceOracle(address oracle_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(oracle_);
    }
}
