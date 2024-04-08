// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Vault} from "./Vault.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
        Vault.MarketConfig[] memory marketConfigs,
        address[] memory fuses,
        Vault.FuseStruct[] memory balanceFuses
    ) external returns (address vault) {
        /// TODO: validate if used marketId exists in global configuration. Storage: GLOBAL_CFG_MARKETS, GLOBAL_CFG_MARKETS_ARRAY
        /// TODO: admin can add or remove markets in global configuration of a VaultFactory

        ///TODO: validate connectors used markets existing in global configuration.
        ///TODO: validate balance connectors used markets existing in global configuration.

        vault = address(
            new Vault(
                iporVaultInitialOwner,
                assetName,
                assetSymbol,
                underlyingToken,
                keepers,
                marketConfigs,
                fuses,
                balanceFuses
            )
        );
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
