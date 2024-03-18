// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Storage
library StorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.marketsGrantedAssets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MARKETS_GRANTED_ASSETS =
        0x6c69fe10a4a5f90d958b48daeb420fdb031044e272ec2a4b02855a335483b700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.keepers")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant KEEPERS = 0x7dd7151eda9a8aa729c84433daab8cd1eaf1f4ce42af566ab5ad0e56a8023100;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.commandConnectors")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CONNECTORS = 0x8df706fc41a6e9ea82576edcbe6c0508c833d6c213c8726956c1b91cfc40df00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.balanceConnectors")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant BALANCE_CONNECTORS = 0x5a5829737eca653c0b5b4a20468c03c7bec2bc961055a682ab2b91dff4463a00;


    /// @custom:storage-location erc7201:io.ipor.marketsGrantedAssets
    struct MarketsGrantedAssets {
        /// @dev marketId => asset =>  1 - granted, otherwise  - not granted
        mapping(uint256 => mapping(address => uint256)) value;
    }

    /// @custom:storage-location erc7201:io.ipor.keepers
    struct Keepers {
        /// @dev keeper address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    struct Connectors {
        /// @dev =connector address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    struct BalanceConnectors {
        /// @dev marketId => connector address => 1 - is granted, otherwise - not granted
        mapping(uint256 => mapping(address => uint256)) value;
    }

    function getMarketsGrantedAssets() internal pure returns (MarketsGrantedAssets storage grantedAssets) {
        assembly {
            grantedAssets.slot := MARKETS_GRANTED_ASSETS
        }
    }

    function getKeepers() internal pure returns (Keepers storage keepers) {
        assembly {
            keepers.slot := KEEPERS
        }
    }

    function getConnectors() internal pure returns (Connectors storage connectors) {
        assembly {
            connectors.slot := CONNECTORS
        }
    }

    function getBalanceConnectors() internal pure returns (BalanceConnectors storage balanceConnectors) {
        assembly {
            balanceConnectors.slot := BALANCE_CONNECTORS
        }
    }
}
