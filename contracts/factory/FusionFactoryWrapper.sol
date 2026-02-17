// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FusionFactory} from "./FusionFactory.sol";
import {FusionFactoryLogicLib} from "./lib/FusionFactoryLogicLib.sol";
import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title FusionFactoryWrapper
/// @notice Wrapper around FusionFactory that distributes core vault roles in a single transaction
/// @dev Calls FusionFactory.clone() with address(this) as owner, grants essential roles,
///      then renounces all vault roles. Remaining roles can be granted by atomist after deployment.
contract FusionFactoryWrapper is AccessControlEnumerable {
    error OwnerZeroAddress();
    error AtomistZeroAddress();
    error AlphaZeroAddress();
    error WhitelistZeroAddress();
    error InvalidSignature();

    /// @notice Role required to call createVault() and createVaultSigned()
    bytes32 public constant VAULT_CREATOR_ROLE = keccak256("VAULT_CREATOR_ROLE");

    /// @notice EIP-712 typehash for CreateVaultInput
    bytes32 public constant CREATE_VAULT_INPUT_TYPEHASH = keccak256(
        "CreateVaultInput(string assetName,string assetSymbol,address underlyingToken,uint256 redemptionDelayInSeconds,uint256 daoFeePackageIndex,address owner,address guardian,address atomist,address alpha,address whitelist)"
    );

    /// @notice EIP-712 domain separator
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice The FusionFactory instance used for cloning vaults
    FusionFactory public immutable FUSION_FACTORY;

    /// @notice Parameters for vault creation and core role assignments
    struct CreateVaultInput {
        string assetName;
        string assetSymbol;
        address underlyingToken;
        uint256 redemptionDelayInSeconds;
        uint256 daoFeePackageIndex;
        address owner;
        address guardian;
        address atomist;
        address alpha;
        address whitelist;
    }

    /// @notice Constructs the FusionFactoryWrapper
    /// @param fusionFactory_ Address of the FusionFactory proxy
    /// @param admin_ Address that receives DEFAULT_ADMIN_ROLE (can manage VAULT_CREATOR_ROLE)
    constructor(address fusionFactory_, address admin_) {
        FUSION_FACTORY = FusionFactory(fusionFactory_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FusionFactoryWrapper"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Creates a new vault with core roles distributed in a single transaction
    /// @param input Vault parameters and role assignments
    /// @return fusionInstance The created FusionInstance with all contract addresses
    function createVault(
        CreateVaultInput calldata input
    ) external onlyRole(VAULT_CREATOR_ROLE) returns (FusionFactoryLogicLib.FusionInstance memory fusionInstance) {
        if (input.owner == address(0)) revert OwnerZeroAddress();
        if (input.atomist == address(0)) revert AtomistZeroAddress();
        if (input.alpha == address(0)) revert AlphaZeroAddress();
        if (input.whitelist == address(0)) revert WhitelistZeroAddress();

        return _createVault(input);
    }

    /// @notice Creates a new vault where input data is signed by the whitelist address
    /// @param input Vault parameters and role assignments
    /// @param v ECDSA signature v
    /// @param r ECDSA signature r
    /// @param s ECDSA signature s
    /// @return fusionInstance The created FusionInstance with all contract addresses
    /// @dev The signature must be produced by input.whitelist over the EIP-712 typed hash of input.
    ///      Only the signer receives WHITELIST_ROLE — no other address gets it.
    function createVaultSigned(
        CreateVaultInput calldata input,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyRole(VAULT_CREATOR_ROLE) returns (FusionFactoryLogicLib.FusionInstance memory fusionInstance) {
        if (input.owner == address(0)) revert OwnerZeroAddress();
        if (input.atomist == address(0)) revert AtomistZeroAddress();
        if (input.alpha == address(0)) revert AlphaZeroAddress();
        if (input.whitelist == address(0)) revert WhitelistZeroAddress();

        bytes32 structHash = _hashCreateVaultInput(input);
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        address signer = ECDSA.recover(digest, v, r, s);

        if (signer != input.whitelist) revert InvalidSignature();

        return _createVault(input);
    }

    /// @notice Internal vault creation logic shared by createVault and createVaultSigned
    function _createVault(
        CreateVaultInput calldata input
    ) private returns (FusionFactoryLogicLib.FusionInstance memory fusionInstance) {
        // Step 1: Clone vault with wrapper as temporary owner
        fusionInstance = FUSION_FACTORY.clone(
            input.assetName,
            input.assetSymbol,
            input.underlyingToken,
            input.redemptionDelayInSeconds,
            address(this),
            input.daoFeePackageIndex
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(fusionInstance.accessManager);

        // Step 2: Grant OWNER-managed roles
        if (input.guardian != address(0)) {
            accessManager.grantRole(Roles.GUARDIAN_ROLE, input.guardian, 0);
        }

        // Step 3: Grant temporary ATOMIST_ROLE to wrapper
        accessManager.grantRole(Roles.ATOMIST_ROLE, address(this), 0);

        // Step 4: Grant ATOMIST-managed roles
        accessManager.grantRole(Roles.ALPHA_ROLE, input.alpha, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, input.whitelist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, input.atomist, 0);

        // Step 5: Grant real ATOMIST_ROLE
        accessManager.grantRole(Roles.ATOMIST_ROLE, input.atomist, 0);

        // Step 6: Renounce temporary ATOMIST_ROLE from wrapper
        accessManager.renounceRole(Roles.ATOMIST_ROLE, address(this));

        // Step 7: Grant OWNER_ROLE to the real owner
        accessManager.grantRole(Roles.OWNER_ROLE, input.owner, 0);

        // Step 8: Renounce OWNER_ROLE from wrapper
        accessManager.renounceRole(Roles.OWNER_ROLE, address(this));

        return fusionInstance;
    }

    /// @notice Computes the EIP-712 struct hash for CreateVaultInput
    function _hashCreateVaultInput(CreateVaultInput calldata input) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CREATE_VAULT_INPUT_TYPEHASH,
                keccak256(bytes(input.assetName)),
                keccak256(bytes(input.assetSymbol)),
                input.underlyingToken,
                input.redemptionDelayInSeconds,
                input.daoFeePackageIndex,
                input.owner,
                input.guardian,
                input.atomist,
                input.alpha,
                input.whitelist
            )
        );
    }
}
