// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Vault} from "./Vault.sol";

/// TODO: Vault has super admin who has rights to setup fee

contract VaultFactory {
//    function createVault(
//        string memory assetName,
//        string memory assetSymbol,
//        address underlyingAsset
//    ) external returns (address vault, address vaultOrchestrator) {
//        vault = address(new Vault(assetName, assetSymbol, underlyingAsset));
//    }

    //    function createConnector(
    //        string memory assetName,
    //        string memory assetSymbol,
    //        address underlyingAsset,
    //        VaultTypes.ConnectorType connectorType
    //    ) external returns (address connector) {
    //        if (connectorType == VaultTypes.ConnectorType.MORPHO) {
    //            connector = address(
    //                new ConnectorMorpho(assetName, assetSymbol, underlyingAsset)
    //            );
    //        } else if (connectorType == VaultTypes.ConnectorType.AAVE) {
    //            connector = address(
    //                new ConnectorAave(assetName, assetSymbol, underlyingAsset)
    //            );
    //        } else {
    //            revert("VaultFactory: invalid connector type");
    //        }
    //    }
}
