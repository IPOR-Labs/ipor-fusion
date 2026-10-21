// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";

/// @notice Minimal view of the executor's asset identity. `ASSET()` is intentionally NOT on
///         `ICrosschainExecutor` (a non-virtual base immutable getter cannot be reconciled with an
///         interface method), so the fuses reach it through this dedicated one-method interface (§9 P2).
interface IExecutorAssetView {
    function ASSET() external view returns (address);
}

/// @notice Typed substrate kinds for the CROSSCHAIN market.
/// @dev Encoding: type in the top 8 bits [255:248], chainId in bits [247:160] (88 bits, zero for
///      EXECUTOR), address in the low 160 bits. Enum value 0 = UNDEFINED so an uninitialized
///      bytes32 is invalid.
enum CrosschainSubstrateType {
    UNDEFINED, // 0 - invalid
    EXECUTOR, // 1 - a crosschain executor (Stargate or CCIP) the vault's fuses are allowed to drive
    REMOTE_VAULT // 2 - a (chainId, remote PlasmaVault) pair the command fuse may target
}

/// @notice Decoded CROSSCHAIN substrate.
/// @param substrateType The substrate kind.
/// @param chainId Destination chainId the substrate is bound to (REMOTE_VAULT only, 0 for EXECUTOR).
/// @param substrateAddress The executor (EXECUTOR) or remote PlasmaVault (REMOTE_VAULT) address.
struct CrosschainSubstrate {
    CrosschainSubstrateType substrateType;
    uint256 chainId;
    address substrateAddress;
}

/// @title CrosschainSubstrateLib
/// @notice Encodes/decodes and validates typed substrates for the CROSSCHAIN market (plan §5.1).
/// @dev Two substrate kinds:
///      - EXECUTOR: the vault whitelists which crosschain executors (Stargate or CCIP) its fuses may touch.
///      - REMOTE_VAULT: the vault whitelists which remote PlasmaVaults (per destination chainId) the
///        command fuses may allowlist on a dispatcher (CREATE_DISPATCHER / UPDATE_PLASMA_VAULTS / UPDATE_VAULTS)
///        or target with a business command (SEND_COMMAND, a retried DEPOSIT). The destination dispatcher
///        keeps its own allowlist; this is the source-side governance gate.
///      Chain-consistency (`executor.MANAGER() == address(this)`) is asserted by the fuses and the NAV
///      pre-hook, not here.
/// @author IPOR Labs
library CrosschainSubstrateLib {
    /// @notice Maximum chainId that fits the 88-bit substrate slot [247:160].
    uint256 internal constant MAX_SUBSTRATE_CHAIN_ID = (1 << 88) - 1;

    /// @notice Thrown when a required substrate is not granted to the CROSSCHAIN market.
    error CrosschainFuseUnsupportedSubstrate(uint8 substrateType, address substrateAddress);

    /// @notice Thrown when a remote PlasmaVault is not granted as a REMOTE_VAULT substrate for `chainId`.
    error CrosschainFuseRemoteVaultNotGranted(uint256 chainId, address vault);

    /// @notice Thrown when a chainId does not fit the 88-bit substrate encoding slot.
    error CrosschainFuseChainIdOverflow(uint256 chainId);

    /// @notice Thrown when the encoded substrate type is outside the declared enum range.
    error CrosschainFuseInvalidSubstrateType(uint256 substrateType);

    /// @notice Thrown when a granted executor substrate resolves to an address with no contract code (§9 P2).
    error CrosschainFuseExecutorNoCode(address executor);

    /// @notice Thrown when an executor's underlying asset differs from the asset the caller expects (§9 P2).
    /// @param executor The executor whose asset was validated.
    /// @param expectedAsset The asset supplied by the caller (`asset_` of `validateExecutorHandlesAsset`), not
    ///        necessarily the vault underlying.
    /// @param actualAsset The executor's `ASSET()`.
    error CrosschainFuseExecutorAssetMismatch(address executor, address expectedAsset, address actualAsset);

    /// @notice Pack a typed substrate into a bytes32 (type << 248 | chainId << 160 | address).
    function substrateToBytes32(CrosschainSubstrate memory substrate_) internal pure returns (bytes32) {
        if (substrate_.chainId > MAX_SUBSTRATE_CHAIN_ID) {
            revert CrosschainFuseChainIdOverflow(substrate_.chainId);
        }
        return bytes32(
            uint256(uint160(substrate_.substrateAddress)) | (substrate_.chainId << 160)
                | (uint256(substrate_.substrateType) << 248)
        );
    }

    /// @notice Unpack a bytes32 into a typed substrate.
    function bytes32ToSubstrate(bytes32 bytes32Substrate_)
        internal
        pure
        returns (CrosschainSubstrate memory substrate)
    {
        uint256 substrateType = uint256(bytes32Substrate_) >> 248;
        if (substrateType > uint256(CrosschainSubstrateType.REMOTE_VAULT)) {
            revert CrosschainFuseInvalidSubstrateType(substrateType);
        }
        substrate.substrateType = CrosschainSubstrateType(substrateType);
        substrate.chainId = (uint256(bytes32Substrate_) >> 160) & MAX_SUBSTRATE_CHAIN_ID;
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
    }

    /// @notice Encode an EXECUTOR substrate (chainId slot is zero — the executor lives on this chain).
    function executorSubstrate(address executor_) internal pure returns (bytes32) {
        return substrateToBytes32(
            CrosschainSubstrate({
                substrateType: CrosschainSubstrateType.EXECUTOR, chainId: 0, substrateAddress: executor_
            })
        );
    }

    /// @notice Encode a REMOTE_VAULT substrate: a remote PlasmaVault bound to its destination chainId.
    function remoteVaultSubstrate(uint256 chainId_, address vault_) internal pure returns (bytes32) {
        return substrateToBytes32(
            CrosschainSubstrate({
                substrateType: CrosschainSubstrateType.REMOTE_VAULT, chainId: chainId_, substrateAddress: vault_
            })
        );
    }

    /// @notice Revert unless `executor_` is granted as an EXECUTOR substrate on `marketId_`.
    function validateExecutorGranted(uint256 marketId_, address executor_) internal view {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, executorSubstrate(executor_))) {
            revert CrosschainFuseUnsupportedSubstrate(uint8(CrosschainSubstrateType.EXECUTOR), executor_);
        }
    }

    /// @notice Revert unless `vault_` is granted as a REMOTE_VAULT substrate for `chainId_` on `marketId_`.
    /// @dev The grant is chainId-bound: the same vault address granted for another chainId does NOT pass.
    function validateRemoteVaultGranted(uint256 marketId_, uint256 chainId_, address vault_) internal view {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, remoteVaultSubstrate(chainId_, vault_))) {
            revert CrosschainFuseRemoteVaultNotGranted(chainId_, vault_);
        }
    }

    /// @notice Revert unless every vault in `vaults_` is granted as a REMOTE_VAULT substrate for `chainId_`.
    function validateRemoteVaultsGranted(uint256 marketId_, uint256 chainId_, address[] memory vaults_) internal view {
        uint256 len = vaults_.length;
        for (uint256 i; i < len; ++i) {
            validateRemoteVaultGranted(marketId_, chainId_, vaults_[i]);
        }
    }

    /// @notice Revert unless `executor_` has code and its underlying `ASSET()` equals `asset_`.
    /// @dev Used when the managed asset is chosen per call (e.g. `StargateCrosschainSupplyFuse`) and may
    ///      legitimately differ from the PlasmaVault underlying.
    function validateExecutorHandlesAsset(address executor_, address asset_) internal view {
        if (executor_.code.length == 0) revert CrosschainFuseExecutorNoCode(executor_);
        address actualAsset = IExecutorAssetView(executor_).ASSET();
        if (actualAsset != asset_) {
            revert CrosschainFuseExecutorAssetMismatch(executor_, asset_, actualAsset);
        }
    }
}
