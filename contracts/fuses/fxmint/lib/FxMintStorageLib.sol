// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title FxMintStorageLib
/// @notice f(x) position ids of the Plasma Vault, one per f(x) pool
/// @dev ERC-7201 namespaced storage, read and written by the FxMint fuses in the vault's context (delegatecall)
library FxMintStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.FxMintPositionIds")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FX_MINT_POSITION_IDS = 0xdab5b7d53c456d684bd7aab42036d7f8a41a58fdd80195990e6fa923e0f6d200;

    /// @custom:storage-location erc7201:io.ipor.FxMintPositionIds
    struct FxMintPositionIds {
        mapping(address pool => uint256 positionId) positionIds;
    }

    function _storage() private pure returns (FxMintPositionIds storage s) {
        assembly {
            s.slot := FX_MINT_POSITION_IDS
        }
    }

    /// @notice Position id of the vault in `pool_` (0 = none)
    function getPositionId(address pool_) internal view returns (uint256) {
        return _storage().positionIds[pool_];
    }

    /// @notice Stores the vault's position id in `pool_`
    function setPositionId(address pool_, uint256 positionId_) internal {
        _storage().positionIds[pool_] = positionId_;
    }
}
