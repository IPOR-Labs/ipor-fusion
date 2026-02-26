// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CREATE3} from "solady/utils/CREATE3.sol";
import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";

/**
 * @title Fusion Factory CREATE3 Library
 * @notice Library that wraps Solady's CREATE3 for deterministic deployment of minimal proxies
 * @dev Provides salt derivation, deterministic deployment, and address prediction for
 * all Fusion Factory components (vault, access, price, withdraw, rewards, context).
 *
 * Salt Domains:
 * - AUTO_DOMAIN: Used for auto-deployment with factory index
 * - EXPLICIT_DOMAIN: Used for explicit (cross-chain) deployment with user-provided salt
 *
 * Each master salt is further derived into 6 component salts, one per Fusion component.
 */
library FusionFactoryCreate3Lib {
    /// @notice Thrown when a CREATE3 salt has already been used for deployment
    error SaltAlreadyUsed();

    /// @notice Thrown when the implementation address is zero
    error InvalidImplementation();

    /// @dev Domain separator for auto-deployment salts derived from factory index
    bytes32 internal constant AUTO_DOMAIN = keccak256("ipor.fusion.auto");

    /// @dev Domain separator for explicit (cross-chain) salts provided by the user
    bytes32 internal constant EXPLICIT_DOMAIN = keccak256("ipor.fusion.explicit");

    /// @notice Derives a master salt for auto-deployment from factory index
    /// @param factoryIndex_ The factory index to derive the salt from
    /// @return The derived master salt
    function deriveAutoMasterSalt(uint256 factoryIndex_) internal pure returns (bytes32) {
        return keccak256(abi.encode(AUTO_DOMAIN, factoryIndex_));
    }

    /// @notice Derives a master salt for explicit (cross-chain) deployment
    /// @param userSalt_ The user-provided salt for cross-chain deterministic deployment
    /// @return The derived master salt
    function deriveExplicitMasterSalt(bytes32 userSalt_) internal pure returns (bytes32) {
        return keccak256(abi.encode(EXPLICIT_DOMAIN, userSalt_));
    }

    /// @notice Derives a component salt from a master salt and component name
    /// @param masterSalt_ The master salt to derive from
    /// @param component_ The component name (e.g. "vault", "access", "price", "withdraw", "rewards", "context")
    /// @return The derived component salt
    function deriveComponentSalt(bytes32 masterSalt_, string memory component_) internal pure returns (bytes32) {
        return keccak256(abi.encode(masterSalt_, component_));
    }

    /// @notice Derives all 6 component salts from a master salt
    /// @param masterSalt_ The master salt to derive from
    /// @return vaultSalt Salt for the PlasmaVault proxy
    /// @return accessSalt Salt for the AccessManager proxy
    /// @return priceSalt Salt for the PriceManager proxy
    /// @return withdrawSalt Salt for the WithdrawManager proxy
    /// @return rewardsSalt Salt for the RewardsManager proxy
    /// @return contextSalt Salt for the ContextManager proxy
    function deriveAllComponentSalts(
        bytes32 masterSalt_
    )
        internal
        pure
        returns (
            bytes32 vaultSalt,
            bytes32 accessSalt,
            bytes32 priceSalt,
            bytes32 withdrawSalt,
            bytes32 rewardsSalt,
            bytes32 contextSalt
        )
    {
        vaultSalt = deriveComponentSalt(masterSalt_, "vault");
        accessSalt = deriveComponentSalt(masterSalt_, "access");
        priceSalt = deriveComponentSalt(masterSalt_, "price");
        withdrawSalt = deriveComponentSalt(masterSalt_, "withdraw");
        rewardsSalt = deriveComponentSalt(masterSalt_, "rewards");
        contextSalt = deriveComponentSalt(masterSalt_, "context");
    }

    /// @notice Deploys a minimal proxy (EIP-1167) via CREATE3 at a deterministic address
    /// @dev Constructs the EIP-1167 minimal proxy creation code and deploys it using Solady CREATE3.
    ///
    /// The hardcoded hex values represent the standard EIP-1167 minimal proxy bytecode (45 bytes runtime):
    ///
    /// Creation code (10 bytes) — deploys the runtime code:
    ///   3d602d80600a3d3981f3
    ///
    /// Runtime code (45 bytes) — forwards all calls via DELEGATECALL to implementation:
    ///   363d3d373d3d3d363d73 <20-byte implementation address> 5af43d82803e903d91602b57fd5bf3
    ///
    /// Runtime opcodes breakdown:
    ///   36 3d 3d 37          - copy calldata to memory
    ///   3d 3d 3d 36 3d       - prepare DELEGATECALL args (gas, to, value=0, input)
    ///   73 <impl>            - push 20-byte implementation address
    ///   5a f4                - DELEGATECALL with all available gas
    ///   3d 82 80 3e          - copy return data
    ///   90 3d 91 602b 57     - if success jump to RETURN
    ///   fd                   - REVERT on failure
    ///   5b f3                - RETURN on success
    ///
    /// Reference: https://eips.ethereum.org/EIPS/eip-1167
    ///
    /// @param implementation_ The implementation contract address for the proxy
    /// @param salt_ The CREATE3 salt determining the deployment address
    /// @return proxy The address of the deployed minimal proxy
    function deployMinimalProxyDeterministic(address implementation_, bytes32 salt_) internal returns (address proxy) {
        if (implementation_ == address(0)) revert InvalidImplementation();

        // EIP-1167 minimal proxy creation code: [loader (10B)] + [runtime prefix (10B)] + [impl (20B)] + [runtime suffix (15B)]
        bytes memory creationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            implementation_,
            hex"5af43d82803e903d91602b57fd5bf3"
        );

        proxy = CREATE3.deployDeterministic(creationCode, salt_);
    }

    /// @notice Predicts the address of a CREATE3 deployment for a given salt (deployer = address(this))
    /// @param salt_ The CREATE3 salt to predict the address for
    /// @return The predicted deployment address
    function predictAddress(bytes32 salt_) internal view returns (address) {
        return CREATE3.predictDeterministicAddress(salt_);
    }

    /// @notice Predicts the address of a CREATE3 deployment for a given salt and deployer
    /// @param salt_ The CREATE3 salt to predict the address for
    /// @param deployer_ The deployer address (the contract calling CREATE3.deployDeterministic)
    /// @return The predicted deployment address
    function predictAddress(bytes32 salt_, address deployer_) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(salt_, deployer_);
    }

    /// @notice Predicts all 6 component addresses for a master salt using factory deployers
    /// @param masterSalt_ The master salt to derive component salts and predict addresses from
    /// @param factoryAddresses_ Factory addresses used as deployers for each component
    /// @return vault Predicted PlasmaVault proxy address
    /// @return accessManager Predicted AccessManager proxy address
    /// @return priceManager Predicted PriceManager proxy address
    /// @return withdrawManager Predicted WithdrawManager proxy address
    /// @return rewardsManager Predicted RewardsManager proxy address
    /// @return contextManager Predicted ContextManager proxy address
    function predictAllAddresses(
        bytes32 masterSalt_,
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses_
    )
        internal
        pure
        returns (
            address vault,
            address accessManager,
            address priceManager,
            address withdrawManager,
            address rewardsManager,
            address contextManager
        )
    {
        (
            bytes32 vaultSalt,
            bytes32 accessSalt,
            bytes32 priceSalt,
            bytes32 withdrawSalt,
            bytes32 rewardsSalt,
            bytes32 contextSalt
        ) = deriveAllComponentSalts(masterSalt_);

        vault = predictAddress(vaultSalt, factoryAddresses_.plasmaVaultFactory);
        accessManager = predictAddress(accessSalt, factoryAddresses_.accessManagerFactory);
        priceManager = predictAddress(priceSalt, factoryAddresses_.priceManagerFactory);
        withdrawManager = predictAddress(withdrawSalt, factoryAddresses_.withdrawManagerFactory);
        rewardsManager = predictAddress(rewardsSalt, factoryAddresses_.rewardsManagerFactory);
        contextManager = predictAddress(contextSalt, factoryAddresses_.contextManagerFactory);
    }
}
