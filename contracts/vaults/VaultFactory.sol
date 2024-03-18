// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Vault} from "./Vault.sol";

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// TODO: Vault has super admin who has rights to setup fee
contract VaultFactory is Ownable2Step {
    address public iporVaultInitialOwner;

    constructor(address iporVaultInitialOwnerInput) Ownable(msg.sender) {
        iporVaultInitialOwner = iporVaultInitialOwnerInput;
    }

    function createVault(
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        address[] memory keepers,
        Vault.AssetsMarketStruct[] memory supportedAssetsInMarkets,
        Vault.ConnectorStruct[] memory connectors,
        Vault.ConnectorStruct[] memory balanceConnectors
    ) external returns (address vault) {
        vault = address(new Vault(iporVaultInitialOwner, assetName, assetSymbol, underlyingToken, keepers, supportedAssetsInMarkets, connectors, balanceConnectors));
    }

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
