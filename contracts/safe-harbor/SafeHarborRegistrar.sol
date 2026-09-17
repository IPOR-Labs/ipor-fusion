// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {Roles} from "../libraries/Roles.sol";
import {ISafeHarborRegistrar} from "./ISafeHarborRegistrar.sol";
import {IFusionFactoryVaultCheck} from "./IFusionFactoryVaultCheck.sol";
import {IAgreement, Chain, Account, ChildContractScope} from "./ext/IAgreement.sol";

/**
 * @title SafeHarborRegistrar
 * @author IPOR Labs
 * @notice Owner-gated per-vault opt-in/opt-out of the SEAL Safe Harbor Agreement adopted by IPOR.
 * The Registrar owns the per-chain SEAL `Agreement` on behalf of IPOR and lets each Plasma Vault owner decide,
 * with one transaction, whether whitehats may legally rescue funds from that vault during an active exploit.
 * @dev The contract is intentionally minimal and NOT upgradeable; the replacement path is
 * `transferAgreementOwnership` to a new Registrar (or back to the multisig).
 *
 * Trust model:
 * - Registrar owner (Ownable2Step, expected to be the IPOR multisig): curates the manual allowlist, can force-remove
 *   any vault, can re-point the Registrar at another Agreement and can hand the Agreement ownership over.
 *   `renounceOwnership` is disabled.
 * - Vault owner (OWNER_ROLE on the vault's IporFusionAccessManager): the only party that can opt its vault in or out.
 *   Execution delay of the role is ignored - membership alone decides.
 * - Agreement: trusted SEAL contract owned by this Registrar.
 * - Genuineness gate: only genuine Fusion vaults can ever be added, so arbitrary contracts never enter IPOR's
 *   Agreement. A vault is eligible when it is on the owner-curated manual allowlist OR when the FusionFactory
 *   reports `isFusionVault(vault) == true` (IL-8227). The allowlist is checked first; the factory is queried with a
 *   guarded staticcall (zero factory address allowed) so a factory that predates IL-8227, reverts, is not deployed
 *   or returns malformed data simply answers "false" and never blocks the allowlisted path. The configured factory
 *   is trusted: whatever it reports as a Fusion vault is eligible. After eligibility, the caller must hold
 *   OWNER_ROLE on the AccessManager returned by the vault's `authority()`.
 * - Residual risk: the account list of the current chain grows with every eligible opt-in and every participation
 *   lookup or mutation reads and scans that whole list (`getDetails()`). Growth is bounded by the number of genuine
 *   vaults. Escape hatch / runbook for the multisig: (1) `forceRemove(vault)` for individual entries;
 *   (2) `transferAgreementOwnership(multisig)` (does not use the reader) and clean the Agreement directly in bounded
 *   calls (`removeAccounts` / `removeChains` / `setChains`), then `Agreement.transferOwnership(registrar)` to resume;
 *   (3) when retiring an Agreement, transfer its ownership away BEFORE `setAgreement` so no stale ownership is left
 *   with this Registrar.
 *
 * Agreement integration (pinned upstream commit, see `ext/IAgreement.sol`):
 * - The Registrar keeps NO local participation state. `isParticipating` is answered by reading the Agreement, so the
 *   Registrar never drifts from the legal source of truth after `setAgreement` or an ownership round-trip.
 * - The vault address is stored in the Agreement as the lowercase hex string produced by `Strings.toHexString`.
 *   Matching is case-insensitive so entries imported from an Agreement that was edited manually are recognised;
 *   opt-out removes every matching entry (by its exact stored string) so the Agreement never keeps stale duplicates.
 * - Upstream forbids removing the last account of a chain and forbids chains without accounts, therefore the last
 *   opt-out removes the whole chain entry (after caching its asset recovery address, which overrides any value set
 *   earlier via `setAssetRecoveryAddress`) and the next opt-in recreates it with the cached recovery address.
 *   Chains other than the current one are never touched.
 * - CAIP-2 chain id: `string` cannot be `immutable` in Solidity, so `eip155:<block.chainid>` is computed once in the
 *   constructor and stored in regular storage. A Registrar is deployed per chain and the chain id cannot change for a
 *   deployed contract, so this is equivalent to an immutable at the cost of one storage read per call.
 *
 * Function permissions:
 * - setParticipation: OWNER_ROLE holders on the vault's access manager, for eligible (genuine) vaults only
 * - forceRemove, setManualAllowlist, setManualAllowlistBatch, setAgreement, transferAgreementOwnership,
 *   setAssetRecoveryAddress: owner only
 *
 * Misconfigured vaults: eligibility is verified before any call to the vault, so only allowlisted or factory-verified
 * vaults reach `authority()`. A zero `authority()` reverts with NoAccessManager; a vault without the `authority()`
 * selector and an authority that is not an AccessManager revert with the raw error of the failing call.
 */
contract SafeHarborRegistrar is ISafeHarborRegistrar, Ownable2Step {
    /// @notice FusionFactory used to verify that an address is a Plasma Vault deployed by IPOR (zero = not available)
    IFusionFactoryVaultCheck public immutable FUSION_FACTORY;

    /// @notice SEAL Agreement currently managed by this Registrar
    address private _agreement;

    /// @notice CAIP-2 id of the chain this Registrar is deployed on, "eip155:<block.chainid>"
    /// @dev Constructor-set storage string - `immutable string` is not supported by Solidity
    string private _caip2ChainId;

    /// @notice Asset recovery address written into the Agreement whenever the chain entry has to be (re)created
    string private _assetRecoveryAddress;

    /// @notice Vaults deployed before the FusionFactory exposed `isFusionVault`, curated by the owner
    mapping(address vault => bool allowed) private _manualAllowlist;

    /// @dev View of the current chain entry extracted from the raw `getDetails()` return data
    struct ChainInfo {
        /// @dev True when the Agreement has an entry for the current chain
        bool exists;
        /// @dev Asset recovery address stored for the current chain
        string assetRecoveryAddress;
        /// @dev Number of accounts stored for the current chain
        uint256 accountsCount;
    }

    /// @notice Sets the initial owner, the managed Agreement, the FusionFactory and the asset recovery address
    /// @param initialOwner_ The initial owner, expected to be the IPOR multisig; zero reverts with OwnableInvalidOwner
    /// @param agreement_ The SEAL Agreement to manage; its ownership is expected to be transferred to this contract
    /// after deployment (not verified here so that deployment order stays flexible)
    /// @param fusionFactory_ The FusionFactory used for `isFusionVault` checks; zero address allowed (factory path
    /// then always answers false and only the manual allowlist grants eligibility)
    /// @param assetRecoveryAddress_ The non-empty asset recovery address used when (re)creating the chain entry
    constructor(address initialOwner_, address agreement_, address fusionFactory_, string memory assetRecoveryAddress_)
        Ownable(initialOwner_)
    {
        if (agreement_ == address(0)) {
            revert Errors.WrongAddress();
        }
        if (bytes(assetRecoveryAddress_).length == 0) {
            revert EmptyAssetRecoveryAddress();
        }
        FUSION_FACTORY = IFusionFactoryVaultCheck(fusionFactory_);
        _agreement = agreement_;
        _assetRecoveryAddress = assetRecoveryAddress_;
        _caip2ChainId = string.concat("eip155:", Strings.toString(block.chainid));
    }

    /**
     * @notice Adds the vault to or removes it from the Agreement on the current chain
     * @param vault_ The Plasma Vault, must be eligible (manual allowlist or FusionFactory `isFusionVault`)
     * @param enabled_ True to opt in (added with ChildContractScope.None), false to opt out
     * @dev Checks, in order: eligibility (NotFusionVault), non-zero `authority()` (NoAccessManager), caller OWNER_ROLE
     * on that access manager (NotVaultOwner), Agreement ownership (AgreementNotOwnedByRegistrar), then the current
     * participation state (AlreadyParticipating / NotParticipating). The Agreement update is atomic with the call.
     * @custom:access Restricted to accounts holding OWNER_ROLE on the AccessManager returned by the vault's
     * `authority()`
     */
    function setParticipation(address vault_, bool enabled_) external override {
        if (!_isEligibleVault(vault_)) {
            revert NotFusionVault(vault_);
        }
        address accessManager = IAccessManaged(vault_).authority();
        if (accessManager == address(0)) {
            revert NoAccessManager(vault_);
        }
        (bool isMember,) = IAccessManager(accessManager).hasRole(Roles.OWNER_ROLE, msg.sender);
        if (!isMember) {
            revert NotVaultOwner(vault_, msg.sender);
        }
        _requireAgreementOwnership();
        if (enabled_) {
            _optIn(vault_);
        } else {
            _optOut(vault_);
        }
        emit ParticipationChanged(vault_, enabled_, msg.sender);
    }

    /**
     * @notice Removes a vault from the Agreement regardless of the vault's own governance
     * @param vault_ The vault to remove
     * @dev Does not verify eligibility, the vault's access manager or the caller's vault role - the Registrar owner
     * may need to remove an entry for a vault that is broken, hostile or no longer managed by IPOR. Only entries
     * whose stored string is a hex address can be targeted; other manual imports (e.g. names) need direct Agreement
     * ownership.
     * Reverts with NotParticipating
     * when the vault is not listed and with AgreementNotOwnedByRegistrar when the Registrar cannot modify the
     * Agreement.
     * @custom:access Restricted to the owner
     */
    function forceRemove(address vault_) external override onlyOwner {
        _requireAgreementOwnership();
        _optOut(vault_);
        emit ParticipationChanged(vault_, false, msg.sender);
    }

    /**
     * @notice Sets the manual allowlist entry of a vault deployed before the factory exposed `isFusionVault`
     * @param vault_ The vault address, non-zero
     * @param allowed_ True to allowlist, false to remove from the allowlist
     * @dev Removing a vault from the allowlist does not remove it from the Agreement; use `forceRemove` for that.
     * @custom:access Restricted to the owner
     */
    function setManualAllowlist(address vault_, bool allowed_) external override onlyOwner {
        if (vault_ == address(0)) {
            revert Errors.WrongAddress();
        }
        _manualAllowlist[vault_] = allowed_;
        emit ManualAllowlistUpdated(vault_, allowed_);
    }

    /**
     * @notice Sets the manual allowlist entry of several vaults in one transaction
     * @param vaults_ The vault addresses, non-empty, every entry non-zero (duplicates allowed, idempotent)
     * @param allowed_ True to allowlist, false to remove from the allowlist
     * @dev Atomic: an empty array reverts with Errors.WrongValue and any zero address reverts with Errors.WrongAddress
     * before any entry is written. Emits ManualAllowlistUpdated once per input address, in input order.
     * @custom:access Restricted to the owner
     */
    function setManualAllowlistBatch(address[] calldata vaults_, bool allowed_) external override onlyOwner {
        uint256 length = vaults_.length;
        if (length == 0) {
            revert Errors.WrongValue();
        }
        for (uint256 i; i < length; ++i) {
            if (vaults_[i] == address(0)) {
                revert Errors.WrongAddress();
            }
        }
        for (uint256 i; i < length; ++i) {
            _manualAllowlist[vaults_[i]] = allowed_;
            emit ManualAllowlistUpdated(vaults_[i], allowed_);
        }
    }

    /**
     * @notice Points the Registrar at a different Agreement
     * @param newAgreement_ The new Agreement address, non-zero
     * @dev Pure pointer switch: participants are NOT migrated and the new Agreement's ownership is NOT verified here,
     * so the owner may point the Registrar first and transfer the Agreement ownership afterwards. Participation is
     * always read from the currently managed Agreement.
     * @custom:access Restricted to the owner
     */
    function setAgreement(address newAgreement_) external override onlyOwner {
        if (newAgreement_ == address(0)) {
            revert Errors.WrongAddress();
        }
        address oldAgreement = _agreement;
        _agreement = newAgreement_;
        emit AgreementUpdated(oldAgreement, newAgreement_);
    }

    /**
     * @notice Transfers the ownership of the managed Agreement to another account
     * @param newOwner_ The new owner of the Agreement, non-zero
     * @dev Upstream Agreement uses single-step Ownable, so the transfer is effective immediately. Afterwards
     * `setParticipation` and `forceRemove` revert with AgreementNotOwnedByRegistrar until ownership is handed back.
     * @custom:access Restricted to the owner
     */
    function transferAgreementOwnership(address newOwner_) external override onlyOwner {
        if (newOwner_ == address(0)) {
            revert Errors.WrongAddress();
        }
        address agreement = _agreement;
        emit AgreementOwnershipTransferred(agreement, newOwner_);
        IAgreement(agreement).transferOwnership(newOwner_);
    }

    /**
     * @notice Sets the asset recovery address used when the Registrar has to (re)create the chain entry
     * @param assetRecoveryAddress_ The recovery address as a non-empty string
     * @dev An existing chain entry in the Agreement is never modified by this call; the value is applied the next
     * time the chain entry is created (first opt-in, or the first opt-in after the last opt-out).
     * Precedence: when the last opt-out removes the chain entry, the recovery address that was in force in the
     * Agreement is cached here and OVERRIDES any value set earlier through this function, so that a re-opt-in
     * restores exactly the previous legal state. To change the recovery address for the re-created chain entry,
     * call this function AFTER the chain entry has been removed (i.e. while no vault participates).
     * @custom:access Restricted to the owner
     */
    function setAssetRecoveryAddress(string calldata assetRecoveryAddress_) external override onlyOwner {
        if (bytes(assetRecoveryAddress_).length == 0) {
            revert EmptyAssetRecoveryAddress();
        }
        _assetRecoveryAddress = assetRecoveryAddress_;
        emit AssetRecoveryAddressUpdated(assetRecoveryAddress_);
    }

    /// @notice Renouncing ownership is disabled to prevent leaving the Agreement unmanageable
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    /// @inheritdoc ISafeHarborRegistrar
    function isParticipating(address vault_) external view override returns (bool participating) {
        (uint256 matchCount,,) = _findAccounts(vault_);
        return matchCount > 0;
    }

    /// @inheritdoc ISafeHarborRegistrar
    function isEligibleVault(address vault_) external view override returns (bool eligible) {
        return _isEligibleVault(vault_);
    }

    /// @inheritdoc ISafeHarborRegistrar
    function isManualAllowlisted(address vault_) external view override returns (bool allowed) {
        return _manualAllowlist[vault_];
    }

    /// @inheritdoc ISafeHarborRegistrar
    function getFusionFactory() external view override returns (address fusionFactory) {
        return address(FUSION_FACTORY);
    }

    /// @inheritdoc ISafeHarborRegistrar
    function getAgreement() external view override returns (address agreement) {
        return _agreement;
    }

    /// @inheritdoc ISafeHarborRegistrar
    function getCaip2ChainId() external view override returns (string memory caip2ChainId) {
        return _caip2ChainId;
    }

    /// @inheritdoc ISafeHarborRegistrar
    function getAssetRecoveryAddress() external view override returns (string memory assetRecoveryAddress) {
        return _assetRecoveryAddress;
    }

    /// @dev Adds the vault to the current chain entry, creating the chain entry when it does not exist yet
    function _optIn(address vault_) private {
        (uint256 matchCount,, ChainInfo memory chainInfo) = _findAccounts(vault_);
        if (matchCount > 0) {
            revert AlreadyParticipating(vault_);
        }

        Account[] memory accounts = new Account[](1);
        accounts[0] =
            Account({accountAddress: Strings.toHexString(vault_), childContractScope: ChildContractScope.None});

        IAgreement agreement = IAgreement(_agreement);
        if (chainInfo.exists) {
            agreement.addAccounts(_caip2ChainId, accounts);
        } else {
            Chain[] memory chains = new Chain[](1);
            chains[0] =
                Chain({assetRecoveryAddress: _assetRecoveryAddress, accounts: accounts, caip2ChainId: _caip2ChainId});
            agreement.addChains(chains);
        }
    }

    /// @dev Removes every entry matching the vault from the current chain entry; removes the whole chain entry when
    /// the vault entries are the only accounts on it (upstream forbids chains without accounts)
    function _optOut(address vault_) private {
        (uint256 matchCount, string[] memory matchedStrings, ChainInfo memory chainInfo) = _findAccounts(vault_);
        if (matchCount == 0) {
            revert NotParticipating(vault_);
        }

        IAgreement agreement = IAgreement(_agreement);
        if (matchCount == chainInfo.accountsCount) {
            if (keccak256(bytes(chainInfo.assetRecoveryAddress)) != keccak256(bytes(_assetRecoveryAddress))) {
                _assetRecoveryAddress = chainInfo.assetRecoveryAddress;
                emit AssetRecoveryAddressUpdated(chainInfo.assetRecoveryAddress);
            }
            string[] memory chainIds = new string[](1);
            chainIds[0] = _caip2ChainId;
            agreement.removeChains(chainIds);
        } else {
            agreement.removeAccounts(_caip2ChainId, matchedStrings);
        }
    }

    /// @dev Reverts unless this Registrar is the owner of the managed Agreement
    function _requireAgreementOwnership() private view {
        address agreement = _agreement;
        address currentOwner = IAgreement(agreement).owner();
        if (currentOwner != address(this)) {
            revert AgreementNotOwnedByRegistrar(agreement, currentOwner);
        }
    }

    /// @notice Returns true when the vault is manually allowlisted or reported by the FusionFactory
    /// @dev The allowlist short-circuits unconditionally (no factory call). The factory is queried with a guarded
    /// staticcall: a zero or undeployed factory, a missing selector, a revert, or a return that is not exactly one
    /// canonical bool word all answer false. The configured factory itself is trusted (its "true" is final)
    /// @param vault_ The address to check
    /// @return eligible True when the vault may be opted in
    function _isEligibleVault(address vault_) private view returns (bool eligible) {
        if (_manualAllowlist[vault_]) {
            return true;
        }
        address factory = address(FUSION_FACTORY);
        if (factory.code.length == 0) {
            return false;
        }
        (bool success, bytes memory returnData) =
            factory.staticcall(abi.encodeCall(IFusionFactoryVaultCheck.isFusionVault, (vault_)));
        if (!success || returnData.length != 0x20) {
            return false;
        }
        return abi.decode(returnData, (uint256)) == 1;
    }

    /// @notice Scans the current chain entry of the Agreement for accounts matching the vault (case-insensitive)
    /// @dev The Agreement's `getDetails()` return data is read raw and walked with a bounds-checked ABI reader because
    /// the legacy codegen cannot ABI-decode the nested `AgreementDetails` struct without via-ir (stack too deep).
    /// @param vault_ The vault to look for
    /// @return matchCount Number of matching entries (0 when the chain entry does not exist)
    /// @return matchedStrings Exact stored strings of the matching entries, in Agreement order
    /// @return chainInfo Existence, recovery address and account count of the current chain entry
    function _findAccounts(address vault_)
        private
        view
        returns (uint256 matchCount, string[] memory matchedStrings, ChainInfo memory chainInfo)
    {
        bytes memory data = _getDetailsRaw();
        (bool exists, uint256 chainPos) = _findChainPos(data);
        if (!exists) {
            return (0, matchedStrings, chainInfo);
        }
        chainInfo.exists = true;
        chainInfo.assetRecoveryAddress = string(_bytesAt(data, chainPos + _offset(data, chainPos)));
        uint256 accountsPos = chainPos + _offset(data, chainPos + 0x20);
        chainInfo.accountsCount = _count(data, accountsPos);
        (matchCount, matchedStrings) = _matchAccounts(data, accountsPos, vault_);
    }

    /// @dev Calls `getDetails()` on the managed Agreement and returns the raw ABI-encoded return data
    function _getDetailsRaw() private view returns (bytes memory data) {
        bool success;
        (success, data) = _agreement.staticcall(abi.encodeCall(IAgreement.getDetails, ()));
        if (!success) {
            // bubble up the Agreement revert reason
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    /// @notice Locates the tuple of the current chain inside the raw `getDetails()` return data
    /// @dev Layout: [offset to AgreementDetails][protocolName off][contactDetails off][chains off][bountyTerms off]
    /// [agreementURI off] ... chains: [length][elem offsets...] ... Chain: [assetRecoveryAddress off][accounts off]
    /// [caip2ChainId off]. Every offset is relative to the start of the enclosing tuple / array data.
    /// @param data_ Raw `getDetails()` return data
    /// @return exists True when the current chain has an entry
    /// @return chainPos Absolute position of the Chain tuple in `data_` (only meaningful when `exists`)
    function _findChainPos(bytes memory data_) private view returns (bool exists, uint256 chainPos) {
        uint256 detailsPos = _offset(data_, 0);
        uint256 chainsPos = detailsPos + _offset(data_, detailsPos + 0x40);
        uint256 chainsLength = _count(data_, chainsPos);
        uint256 elementsPos = chainsPos + 0x20;
        bytes32 chainHash = keccak256(bytes(_caip2ChainId));
        for (uint256 i; i < chainsLength; ++i) {
            chainPos = elementsPos + _offset(data_, elementsPos + i * 0x20);
            if (keccak256(_bytesAt(data_, chainPos + _offset(data_, chainPos + 0x40))) == chainHash) {
                return (true, chainPos);
            }
        }
        return (false, 0);
    }

    /// @notice Collects the exact stored strings of every account whose address equals the vault (case-insensitive)
    /// @dev Layout of accounts: [length][elem offsets...] ... Account: [accountAddress off][childContractScope]
    /// @param data_ Raw `getDetails()` return data
    /// @param accountsPos_ Absolute position of the accounts array (its length word) in `data_`
    /// @param vault_ The vault to match
    /// @return matchCount Number of matching entries
    /// @return matchedStrings Exact stored strings of the matching entries, in Agreement order
    function _matchAccounts(bytes memory data_, uint256 accountsPos_, address vault_)
        private
        pure
        returns (uint256 matchCount, string[] memory matchedStrings)
    {
        bytes32 vaultHash = keccak256(bytes(Strings.toHexString(vault_)));
        uint256 accountsLength = _count(data_, accountsPos_);
        uint256 elementsPos = accountsPos_ + 0x20;
        matchedStrings = new string[](accountsLength);
        for (uint256 i; i < accountsLength; ++i) {
            uint256 accountPos = elementsPos + _offset(data_, elementsPos + i * 0x20);
            bytes memory stored = _bytesAt(data_, accountPos + _offset(data_, accountPos));
            if (keccak256(_toLowerAscii(stored)) == vaultHash) {
                matchedStrings[matchCount] = string(stored);
                ++matchCount;
            }
        }
        // shrink the array to the number of matches
        assembly ("memory-safe") {
            mstore(matchedStrings, matchCount)
        }
    }

    /// @dev Reads a word at `pos_` that is used as a relative ABI offset; reverts unless it fits inside `data_`, so
    /// adding it to any base position inside `data_` can never overflow
    function _offset(bytes memory data_, uint256 pos_) private pure returns (uint256 offset) {
        offset = _word(data_, pos_);
        if (offset > data_.length) {
            revert MalformedAgreementData();
        }
    }

    /// @dev Reads the length word of a dynamic array at `pos_`; reverts unless the offset table of that many elements
    /// fits inside `data_`, so element loops and allocations are bounded by the actual return data size
    function _count(bytes memory data_, uint256 pos_) private pure returns (uint256 count) {
        count = _word(data_, pos_);
        if (count > (data_.length - pos_ - 0x20) / 0x20) {
            revert MalformedAgreementData();
        }
    }

    /// @dev Reads one 32-byte word at `pos_` of `data_`, reverts on out-of-bounds
    function _word(bytes memory data_, uint256 pos_) private pure returns (uint256 value) {
        if (pos_ + 0x20 > data_.length) {
            revert MalformedAgreementData();
        }
        assembly ("memory-safe") {
            value := mload(add(add(data_, 0x20), pos_))
        }
    }

    /// @dev Copies the dynamic bytes value whose length word sits at `pos_` of `data_`, reverts on out-of-bounds
    function _bytesAt(bytes memory data_, uint256 pos_) private pure returns (bytes memory value) {
        uint256 length = _word(data_, pos_);
        if (length > data_.length - pos_ - 0x20) {
            revert MalformedAgreementData();
        }
        value = new bytes(length);
        assembly ("memory-safe") {
            mcopy(add(value, 0x20), add(add(data_, 0x40), pos_), length)
        }
    }

    /// @dev Lower-cases ASCII letters A-Z of a string, other bytes are copied unchanged
    function _toLowerAscii(bytes memory inputBytes) private pure returns (bytes memory output) {
        uint256 length = inputBytes.length;
        output = new bytes(length);
        for (uint256 i; i < length; ++i) {
            bytes1 char = inputBytes[i];
            if (char > 0x40 && char < 0x5b) {
                output[i] = bytes1(uint8(char) + 32);
            } else {
                output[i] = char;
            }
        }
    }
}
