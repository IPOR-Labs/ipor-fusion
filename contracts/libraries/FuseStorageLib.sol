// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Fuses storage library responsible for managing storage fuses in the Plasma Vault
library FuseStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_FUSES = 0x48932b860eb451ad240d4fe2b46522e5a0ac079d201fe50d4e0be078c75b5400;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_FUSES_ARRAY = 0xad43e358bd6e59a5a0c80f6bf25fa771408af4d80f621cdc680c8dfbf607ab00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.tokenIdsUsedInFuse")) - 1)) & ~bytes32(uint256(0xff));
    /// @dev this memory is designed to use with uniswap v3 fuses
    bytes32 private constant TOKEN_IDS_USED_IN_FUSE =
        0xda8804a8d91737b4c393e8fbbd1085e373450a3e16b6b8ef2011e85a93352600;

    /// @custom:storage-location erc7201:io.ipor.CfgFuses
    struct Fuses {
        /// @dev fuse address => If index = 0 - is not granted, otherwise - granted
        mapping(address fuse => uint256 index) value;
    }

    /// @custom:storage-location erc7201:io.ipor.CfgFusesArray
    struct FusesArray {
        /// @dev value is a fuse address
        address[] value;
    }

    /// @custom:storage-location erc7201:io.ipor.TokenIdsUsedInFuse
    struct TokenIdsUsedInFuse {
        uint256[] tokenIds;
        mapping(uint256 tokenId => uint256 index) indexes;
    }

    /// @notice Gets the fuses storage pointer
    function getFuses() internal pure returns (Fuses storage fuses) {
        assembly {
            fuses.slot := CFG_FUSES
        }
    }

    /// @notice Gets the fuses array storage pointer
    function getFusesArray() internal pure returns (FusesArray storage fusesArray) {
        assembly {
            fusesArray.slot := CFG_FUSES_ARRAY
        }
    }

    /// @notice Gets the tokenIdUsedFuse storage pointer
    function getTokenIdUsedFuse() internal pure returns (TokenIdsUsedInFuse storage tokenIdsUsedInFuse) {
        assembly {
            tokenIdsUsedInFuse.slot := TOKEN_IDS_USED_IN_FUSE
        }
    }
}
