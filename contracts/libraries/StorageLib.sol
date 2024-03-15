// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Storage ID's associated with the IPOR Protocol Router.
library StorageLib {

    // keccak256(abi.encode(uint256(keccak256("io.ipor.marketsGrantedAssets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MARKETS_GRANTED_ASSETS = 0x6c69fe10a4a5f90d958b48daeb420fdb031044e272ec2a4b02855a335483b700;

    bytes32 private constant KEEPERS = 0x6c69fe10a4a5f90d958b48daeb420fdb031044e272ec2a4b02855a335483b701;

    bytes32 private constant COMMAND_CONNECTORS = 0x6c69fe10a4a5f90d958b48daeb420fdb031044e272ec2a4b02855a335483b702;

    bytes32 private constant BALANCE_CONNECTORS = 0x6c69fe10a4a5f90d958b48daeb420fdb031044e272ec2a4b02855a335483b703;


    /// @custom:storage-location erc7201:io.ipor.marketsGrantedAssets
    struct MarketsGrantedAssets {
        // marketId => asset =>  1 - granted, otherwise  - not granted
        mapping(uint256 => mapping(address => uint256)) value;
    }

    function getMarketsGrantedAssets() internal pure returns (MarketsGrantedAssets storage grantedAssets) {
        assembly {
            grantedAssets.slot := MARKETS_GRANTED_ASSETS
        }
    }
}
