// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MidasRequestSupplyFuse, MidasRequestSupplyFuseEnterData, MidasRequestSupplyFuseExitData} from "contracts/fuses/midas/MidasRequestSupplyFuse.sol";
import {MidasPendingRequestsStorageLib} from "contracts/fuses/midas/lib/MidasPendingRequestsStorageLib.sol";
import {MidasExecutorStorageLib} from "contracts/fuses/midas/lib/MidasExecutorStorageLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";

/// @title MidasRequestSupplyFuseHarness
/// @notice Test harness that acts as PlasmaVault, calling MidasRequestSupplyFuse via delegatecall.
///         Holds all ERC-7201 storage (pending requests, executor) for the delegatecall context.
///         Also provides storage inspection helpers and substrate grant helpers.
contract MidasRequestSupplyFuseHarness {
    address public immutable fuse;

    constructor(address fuse_) {
        fuse = fuse_;
    }

    // ============ Delegatecall Wrappers ============

    /// @notice Call fuse.enter() via delegatecall (fuse runs in THIS contract's storage context)
    function enter(MidasRequestSupplyFuseEnterData memory data_) external {
        (bool success, bytes memory ret) = fuse.delegatecall(
            abi.encodeWithSelector(MidasRequestSupplyFuse.enter.selector, data_)
        );
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Call fuse.exit() via delegatecall
    function exit(MidasRequestSupplyFuseExitData memory data_) external {
        (bool success, bytes memory ret) = fuse.delegatecall(
            abi.encodeWithSelector(MidasRequestSupplyFuse.exit.selector, data_)
        );
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Call fuse.cleanupPendingDeposits() via delegatecall
    function cleanupPendingDeposits(address depositVault_, uint256 maxIterations_) external {
        (bool success, bytes memory ret) = fuse.delegatecall(
            abi.encodeWithSelector(MidasRequestSupplyFuse.cleanupPendingDeposits.selector, depositVault_, maxIterations_)
        );
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Call fuse.cleanupPendingRedemptions() via delegatecall
    function cleanupPendingRedemptions(address redemptionVault_, uint256 maxIterations_) external {
        (bool success, bytes memory ret) = fuse.delegatecall(
            abi.encodeWithSelector(MidasRequestSupplyFuse.cleanupPendingRedemptions.selector, redemptionVault_, maxIterations_)
        );
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // ============ Storage Inspection Helpers ============

    function getPendingDepositsForVault(address vault_) external view returns (uint256[] memory) {
        return MidasPendingRequestsStorageLib.getPendingDepositsForVault(vault_);
    }

    function getPendingRedemptionsForVault(address vault_) external view returns (uint256[] memory) {
        return MidasPendingRequestsStorageLib.getPendingRedemptionsForVault(vault_);
    }

    function isDepositPending(address vault_, uint256 requestId_) external view returns (bool) {
        return MidasPendingRequestsStorageLib.isDepositPending(vault_, requestId_);
    }

    function isRedemptionPending(address vault_, uint256 requestId_) external view returns (bool) {
        return MidasPendingRequestsStorageLib.isRedemptionPending(vault_, requestId_);
    }

    function getExecutor() external view returns (address) {
        return MidasExecutorStorageLib.getExecutor();
    }

    // ============ Storage Seeding Helpers ============

    /// @notice Pre-populate a pending deposit for testing cleanup scenarios
    function seedPendingDeposit(address depositVault_, uint256 requestId_) external {
        MidasPendingRequestsStorageLib.addPendingDeposit(depositVault_, requestId_);
    }

    /// @notice Pre-populate a pending redemption for testing cleanup scenarios
    function seedPendingRedemption(address redemptionVault_, uint256 requestId_) external {
        MidasPendingRequestsStorageLib.addPendingRedemption(redemptionVault_, requestId_);
    }

    /// @notice Pre-set executor address in storage (avoids auto-deployment in tests)
    function setExecutor(address executor_) external {
        MidasExecutorStorageLib.setExecutor(executor_);
    }

    // ============ Substrate Grant Helpers ============

    /// @notice Grant a substrate (mToken, vault, asset) to the specified marketId
    function grantSubstrate(uint256 marketId_, MidasSubstrateType substrateType_, address substrateAddress_) external {
        bytes32 encoded = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: substrateType_, substrateAddress: substrateAddress_})
        );
        PlasmaVaultStorageLib.getMarketSubstrates().value[marketId_].substrateAllowances[encoded] = 1;
    }
}
