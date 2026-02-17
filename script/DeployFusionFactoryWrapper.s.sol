// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {FusionFactoryWrapper} from "../contracts/factory/FusionFactoryWrapper.sol";

/// @title DeployFusionFactoryWrapper
/// @notice Foundry script to deploy FusionFactoryWrapper on Ethereum mainnet
/// @dev Usage:
///
///   DRY RUN (simulation):
///     forge script script/DeployFusionFactoryWrapper.s.sol \
///       --rpc-url $ETHEREUM_PROVIDER_URL \
///       --sender <DEPLOYER_ADDRESS>
///
///   BROADCAST (real deployment):
///     forge script script/DeployFusionFactoryWrapper.s.sol \
///       --rpc-url $ETHEREUM_PROVIDER_URL \
///       --broadcast \
///       --verify \
///       --etherscan-api-key $ETHERSCAN_API_KEY \
///       --private-key $DEPLOYER_PRIVATE_KEY
///
///   Or with a hardware wallet (Ledger):
///     forge script script/DeployFusionFactoryWrapper.s.sol \
///       --rpc-url $ETHEREUM_PROVIDER_URL \
///       --broadcast \
///       --verify \
///       --etherscan-api-key $ETHERSCAN_API_KEY \
///       --ledger
///
///   Environment variables:
///     FUSION_FACTORY_PROXY  - FusionFactory proxy address (default: 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852)
///     WRAPPER_ADMIN         - Address that receives DEFAULT_ADMIN_ROLE on the wrapper (required)
///     VAULT_CREATOR         - Address that receives VAULT_CREATOR_ROLE (optional, granted after deploy)
contract DeployFusionFactoryWrapper is Script {
    address constant DEFAULT_FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;

    function run() external {
        address fusionFactoryProxy = vm.envOr("FUSION_FACTORY_PROXY", DEFAULT_FUSION_FACTORY_PROXY);
        address wrapperAdmin = vm.envAddress("WRAPPER_ADMIN");
        address vaultCreator = vm.envOr("VAULT_CREATOR", address(0));

        require(wrapperAdmin != address(0), "WRAPPER_ADMIN must be set");

        console.log("=== DeployFusionFactoryWrapper ===");
        console.log("Chain ID:             ", block.chainid);
        console.log("FusionFactory proxy:  ", fusionFactoryProxy);
        console.log("Wrapper admin:        ", wrapperAdmin);
        if (vaultCreator != address(0)) {
            console.log("Vault creator:        ", vaultCreator);
        }
        console.log("==================================");

        vm.startBroadcast();

        FusionFactoryWrapper wrapper = new FusionFactoryWrapper(fusionFactoryProxy, wrapperAdmin);
        console.log("FusionFactoryWrapper deployed at:", address(wrapper));

        if (vaultCreator != address(0)) {
            wrapper.grantRole(wrapper.VAULT_CREATOR_ROLE(), vaultCreator);
            console.log("VAULT_CREATOR_ROLE granted to:   ", vaultCreator);
        }

        vm.stopBroadcast();

        console.log("=== Deployment complete ===");
    }
}
