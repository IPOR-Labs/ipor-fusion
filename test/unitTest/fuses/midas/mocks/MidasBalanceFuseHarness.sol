// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MidasBalanceFuse} from "contracts/fuses/midas/MidasBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {MidasPendingRequestsStorageLib} from "contracts/fuses/midas/lib/MidasPendingRequestsStorageLib.sol";
import {MidasExecutorStorageLib} from "contracts/fuses/midas/lib/MidasExecutorStorageLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";

/// @title MidasBalanceFuseHarness
/// @notice Test harness that inherits MidasBalanceFuse and exposes helpers to write to the
///         ERC-7201 storage slots used by PlasmaVaultConfigLib, MidasPendingRequestsStorageLib,
///         MidasExecutorStorageLib, and PlasmaVaultLib.
///
///         When tests call balanceOf() on this harness, address(this) is the harness itself,
///         simulating the PlasmaVault delegatecall context.
contract MidasBalanceFuseHarness is MidasBalanceFuse {
    constructor(uint256 marketId_) MidasBalanceFuse(marketId_) {}

    // ============ PlasmaVaultConfigLib helpers ============

    /// @notice Write market substrates directly to the ERC-7201 storage slot
    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    // ============ MidasPendingRequestsStorageLib helpers ============

    /// @notice Add a pending deposit request ID for a vault into storage
    function addPendingDeposit(address depositVault_, uint256 requestId_) external {
        MidasPendingRequestsStorageLib.addPendingDeposit(depositVault_, requestId_);
    }

    /// @notice Add a pending redemption request ID for a vault into storage
    function addPendingRedemption(address redemptionVault_, uint256 requestId_) external {
        MidasPendingRequestsStorageLib.addPendingRedemption(redemptionVault_, requestId_);
    }

    // ============ MidasExecutorStorageLib helpers ============

    /// @notice Set the executor address in ERC-7201 storage
    function setExecutor(address executor_) external {
        MidasExecutorStorageLib.setExecutor(executor_);
    }

    // ============ PlasmaVaultLib helpers ============

    /// @notice Set the price oracle middleware address in ERC-7201 storage
    function setPriceOracle(address oracle_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(oracle_);
    }
}
