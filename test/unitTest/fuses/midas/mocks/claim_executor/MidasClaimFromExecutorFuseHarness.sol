// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MidasClaimFromExecutorFuse, MidasClaimFromExecutorFuseEnterData} from "contracts/fuses/midas/MidasClaimFromExecutorFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {MidasExecutorStorageLib} from "contracts/fuses/midas/lib/MidasExecutorStorageLib.sol";

/// @notice Test harness for MidasClaimFromExecutorFuse.
///         Simulates the PlasmaVault's delegatecall context:
///         - Exposes fuse entry points via delegatecall so storage writes land in this contract.
///         - Provides helpers to configure PlasmaVault storage (grant substrates, set executor)
///           directly on this contract's storage — exactly as PlasmaVault would have it.
contract MidasClaimFromExecutorFuseHarness {
    /// @dev The fuse implementation to delegatecall into
    address public immutable fuse;

    constructor(address fuse_) {
        fuse = fuse_;
    }

    // ─────────────────────────────────────────────────────────────
    // Fuse entry points (delegatecall)
    // ─────────────────────────────────────────────────────────────

    /// @notice Delegatecall enter() on the fuse
    function enter(MidasClaimFromExecutorFuseEnterData memory data_) external {
        (bool success, bytes memory result) = fuse.delegatecall(
            abi.encodeWithSelector(MidasClaimFromExecutorFuse.enter.selector, data_)
        );
        if (!success) {
            // Re-bubble the exact revert data
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @notice Delegatecall deployExecutor() on the fuse
    function deployExecutor() external {
        (bool success, bytes memory result) = fuse.delegatecall(
            abi.encodeWithSelector(MidasClaimFromExecutorFuse.deployExecutor.selector)
        );
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Storage helpers (write to this contract's storage as PlasmaVault would)
    // ─────────────────────────────────────────────────────────────

    /// @notice Grant market substrates in this contract's storage (replaces current grants)
    function grantMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    /// @notice Manually set the executor address in this contract's storage
    function setExecutor(address executor_) external {
        MidasExecutorStorageLib.setExecutor(executor_);
    }

    /// @notice Read the executor address from this contract's storage
    function getExecutor() external view returns (address) {
        return MidasExecutorStorageLib.getExecutor();
    }
}
