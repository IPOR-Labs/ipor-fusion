// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IAgreement (vendored)
 * @notice Minimal interface and types of the SEAL Safe Harbor `Agreement` contract used by the IPOR
 * SafeHarborRegistrar. Only the functions and types the Registrar relies on are vendored here.
 * @dev Vendored from https://github.com/security-alliance/safe-harbor
 * commit 78ba9237377a9622439cbab41a5336673cea1b92
 * files registry-contracts/src/Agreement.sol and registry-contracts/src/types/AgreementTypes.sol.
 * Struct field order and enum member order MUST stay identical to upstream - they define the ABI encoding.
 * Upstream semantics the Registrar depends on (at the pinned commit):
 * - `addAccounts` does NOT de-duplicate accounts and reverts when the chain does not exist.
 * - `removeAccounts` matches the stored `accountAddress` string exactly (case-sensitive keccak256 comparison)
 *   and reverts with `Agreement__CannotRemoveAllAccounts` when it would leave the chain with zero accounts.
 * - `addChains` reverts with `Agreement__DuplicateChainId` when the chain already exists and every chain
 *   must carry at least one account and a non-empty `assetRecoveryAddress`.
 * - `removeChains` deletes the chain together with all its accounts.
 * - `transferOwnership` is the single-step OpenZeppelin `Ownable` transfer (effective immediately).
 */

/// @notice Enum that defines the inclusion of child contracts in an agreement.
enum ChildContractScope {
    // No child contracts are included.
    None,
    // Only child contracts that were created before the time of this agreement are included.
    ExistingOnly,
    // All child contracts, both existing and new, are included.
    All,
    // Only child contracts that were created after the time of this agreement are included.
    FutureOnly
}

/// @notice Whitehat identity verification requirements.
enum IdentityRequirements {
    // The whitehat will be subject to no KYC requirements.
    Anonymous,
    // The whitehat must provide a pseudonym.
    Pseudonymous,
    // The whitehat must confirm their legal name.
    Named
}

/// @notice Struct that contains the contact details of the agreement.
struct Contact {
    string name;
    // This person's contact details (email, phone, telegram handle, etc.)
    string contact;
}

/// @notice Struct that contains the details of an account in an agreement.
struct Account {
    // The address of the account (EOA or smart contract).
    string accountAddress;
    // The scope of child contracts included in the agreement.
    ChildContractScope childContractScope;
}

/// @notice Struct that contains the details of an agreement by chain.
struct Chain {
    // The address to which recovered assets will be sent.
    string assetRecoveryAddress;
    // The accounts in scope for the agreement.
    Account[] accounts;
    // The CAIP-2 chain ID, e.g. "eip155:1".
    string caip2ChainId;
}

/// @notice Struct that contains the terms of the bounty for the agreement.
struct BountyTerms {
    // Percentage of the recovered funds a Whitehat receives as their bounty (0-100).
    uint256 bountyPercentage;
    // The maximum bounty in USD.
    uint256 bountyCapUSD;
    // Whether the whitehat can retain their bounty or must return all funds to the asset recovery address.
    bool retainable;
    // The identity verification requirements on the whitehat.
    IdentityRequirements identity;
    // The diligence requirements placed on eligible whitehats. Only applicable for Named whitehats.
    string diligenceRequirements;
    // Optional. Caps the total USD value of bounties paid across all whitehats for a single exploit.
    uint256 aggregateBountyCapUSD;
}

/// @notice Struct that contains the details of the agreement.
struct AgreementDetails {
    // The name of the protocol adopting the agreement.
    string protocolName;
    // The contact details (required for pre-notifying).
    Contact[] contactDetails;
    // The scope and recovery address by chain.
    Chain[] chains;
    // The terms of the agreement.
    BountyTerms bountyTerms;
    // IPFS hash or other URI of the actual agreement document, which confirms all terms.
    string agreementURI;
}

/// @title IAgreement
/// @author Security Alliance (vendored by IPOR Labs, see the file header for the pinned commit)
/// @notice Subset of the SEAL Safe Harbor `Agreement` API used by the SafeHarborRegistrar
interface IAgreement {
    /// @notice Returns the current owner of the Agreement (OpenZeppelin Ownable)
    /// @return The owner address
    function owner() external view returns (address);

    /// @notice Transfers ownership of the Agreement (single-step, effective immediately)
    /// @param newOwner The new owner of the Agreement
    function transferOwnership(address newOwner) external;

    /// @notice Returns the full agreement details, chains and accounts included
    /// @dev Cannot be ABI-decoded by the legacy codegen (stack too deep); read the raw return data instead
    /// @return The agreement details
    function getDetails() external view returns (AgreementDetails memory);

    /// @notice Adds chains to the Agreement, reverts when a chain already exists
    /// @param _chains The chains to add, each with at least one account
    function addChains(Chain[] memory _chains) external;

    /// @notice Removes chains (with all their accounts) from the Agreement
    /// @param _caip2ChainIds The CAIP-2 ids of the chains to remove
    function removeChains(string[] memory _caip2ChainIds) external;

    /// @notice Appends accounts to an existing chain, no de-duplication
    /// @param _caip2ChainId The CAIP-2 id of the chain
    /// @param _accounts The accounts to add
    function addAccounts(string memory _caip2ChainId, Account[] calldata _accounts) external;

    /// @notice Removes accounts from an existing chain by exact address string, at least one account must remain
    /// @param _caip2ChainId The CAIP-2 id of the chain
    /// @param _accountAddresses The exact stored account address strings to remove
    function removeAccounts(string memory _caip2ChainId, string[] memory _accountAddresses) external;
}
