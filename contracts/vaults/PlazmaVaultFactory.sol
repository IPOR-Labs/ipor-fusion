// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {PlazmaVault} from "./PlazmaVault.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// TODO: Vault has super admin who has rights to setup fee
//TODO: upgradeable
contract PlazmaVaultFactory is Ownable2Step {
    address public iporVaultInitialOwner;

    constructor(address iporVaultInitialOwnerInput) Ownable(msg.sender) {
        iporVaultInitialOwner = iporVaultInitialOwnerInput;
    }

    function createVault(
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        address[] memory alphas,
        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs,
        address[] memory fuses,
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses
    ) external returns (address plazmaVault) {
        /// TODO: validate if used marketId exists in global configuration. Storage: GLOBAL_CFG_MARKETS, GLOBAL_CFG_MARKETS_ARRAY
        /// TODO: admin can add or remove markets in global configuration of a VaultFactory

        ///TODO: validate fuses used markets existing in global configuration.
        ///TODO: validate balance fuses used markets existing in global configuration.

        plazmaVault = address(
            new PlazmaVault(
                iporVaultInitialOwner,
                assetName,
                assetSymbol,
                underlyingToken,
                alphas,
                marketConfigs,
                fuses,
                balanceFuses
            )
        );
    }
}
