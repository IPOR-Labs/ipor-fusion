// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Account, Chain, Contact, AgreementDetails} from "../../../contracts/safe-harbor/ext/IAgreement.sol";

/// @title MockAgreement
/// @author IPOR Labs
/// @notice Stateful test double preserving the pinned Agreement's account mutation semantics.
/// @dev Intentionally permits duplicates, matches strings exactly, and forbids empty chains.
contract MockAgreement is Ownable {
    error ChainNotFound(string chainId);
    error DuplicateChain(string chainId);
    error AccountNotFound(string accountAddress);
    error CannotRemoveAllAccounts();
    error InvalidChain();
    error InvalidAccount();
    error WriteRejected();

    string[] private _chainIds;
    mapping(string => string) private _recovery;
    mapping(string => Account[]) private _accounts;
    bool private _rejectWrites;

    /// @notice Reverts after a mutation to exercise transaction-wide rollback in the registrar.
    modifier checkedWrite() {
        _;
        if (_rejectWrites) revert WriteRejected();
    }

    /// @notice Creates an Agreement owned by the test fixture.
    /// @param owner_ Initial owner.
    constructor(address owner_) Ownable(owner_) {}

    /// @notice Configures simulated upstream write failure.
    /// @param reject_ Whether mutations revert after executing.
    function setRejectWrites(bool reject_) external {
        _rejectWrites = reject_;
    }

    /// @notice Returns the stored chains and accounts with the real Agreement ABI.
    /// @return details_ Stored agreement details.
    function getDetails() external view returns (AgreementDetails memory details_) {
        details_.protocolName = "Mock IPOR";
        details_.contactDetails = new Contact[](0);
        details_.chains = new Chain[](_chainIds.length);
        for (uint256 i; i < _chainIds.length; ++i) {
            string memory id = _chainIds[i];
            details_.chains[i] = Chain(_recovery[id], _accounts[id], id);
        }
    }

    /// @notice Returns all registered chain identifiers.
    /// @return Registered chain identifiers.
    function getChainIds() external view returns (string[] memory) {
        return _chainIds;
    }

    /// @notice Returns one chain's recovery address without a nested ABI decoder.
    /// @param id_ Chain identifier.
    /// @return Recovery address.
    function getRecovery(string calldata id_) external view returns (string memory) {
        return _recovery[id_];
    }

    /// @notice Returns one chain's account count without a nested ABI decoder.
    /// @param id_ Chain identifier.
    /// @return Number of accounts.
    function getAccountCount(string calldata id_) external view returns (uint256) {
        return _accounts[id_].length;
    }

    /// @notice Returns one account using a flat ABI.
    /// @param id_ Chain identifier.
    /// @param index_ Account index.
    /// @return accountAddress Stored address string.
    /// @return scope Stored child-contract scope as its enum ordinal.
    function getAccount(string calldata id_, uint256 index_)
        external
        view
        returns (string memory accountAddress, uint256 scope)
    {
        Account storage account = _accounts[id_][index_];
        return (account.accountAddress, uint256(account.childContractScope));
    }

    /// @notice Adds nonempty, previously absent chains.
    /// @param chains_ Chains to append.
    function addChains(Chain[] calldata chains_) external onlyOwner checkedWrite {
        for (uint256 i; i < chains_.length; ++i) {
            Chain memory chain = chains_[i];
            if (_exists(chain.caip2ChainId)) revert DuplicateChain(chain.caip2ChainId);
            if (
                bytes(chain.caip2ChainId).length == 0 || bytes(chain.assetRecoveryAddress).length == 0
                    || chain.accounts.length == 0
            ) revert InvalidChain();
            _chainIds.push(chain.caip2ChainId);
            _recovery[chain.caip2ChainId] = chain.assetRecoveryAddress;
            for (uint256 j; j < chain.accounts.length; ++j) {
                if (bytes(chain.accounts[j].accountAddress).length == 0) revert InvalidAccount();
                _accounts[chain.caip2ChainId].push(chain.accounts[j]);
            }
        }
    }

    /// @notice Appends accounts without checking for duplicates, as upstream does.
    /// @param id_ Target chain identifier.
    /// @param accounts_ Accounts to append.
    function addAccounts(string calldata id_, Account[] calldata accounts_) external onlyOwner checkedWrite {
        if (!_exists(id_)) revert ChainNotFound(id_);
        for (uint256 i; i < accounts_.length; ++i) {
            if (bytes(accounts_[i].accountAddress).length == 0) revert InvalidAccount();
            _accounts[id_].push(accounts_[i]);
        }
    }

    /// @notice Removes exact stored strings by swap-and-pop, leaving at least one account.
    /// @param id_ Target chain identifier.
    /// @param addresses_ Exact stored strings to remove.
    function removeAccounts(string calldata id_, string[] calldata addresses_) external onlyOwner checkedWrite {
        if (!_exists(id_)) revert ChainNotFound(id_);
        Account[] storage accounts = _accounts[id_];
        if (!(addresses_.length < accounts.length)) revert CannotRemoveAllAccounts();
        for (uint256 i; i < addresses_.length; ++i) {
            bool found;
            for (uint256 j; j < accounts.length; ++j) {
                if (keccak256(bytes(accounts[j].accountAddress)) == keccak256(bytes(addresses_[i]))) {
                    accounts[j] = accounts[accounts.length - 1];
                    accounts.pop();
                    found = true;
                    break;
                }
            }
            if (!found) revert AccountNotFound(addresses_[i]);
        }
    }

    /// @notice Removes complete chains, including their recovery address and all accounts.
    /// @param ids_ Chain identifiers to remove.
    function removeChains(string[] calldata ids_) external onlyOwner checkedWrite {
        for (uint256 i; i < ids_.length; ++i) {
            if (!_exists(ids_[i])) revert ChainNotFound(ids_[i]);
            for (uint256 j; j < _chainIds.length; ++j) {
                if (keccak256(bytes(_chainIds[j])) == keccak256(bytes(ids_[i]))) {
                    _chainIds[j] = _chainIds[_chainIds.length - 1];
                    _chainIds.pop();
                    break;
                }
            }
            delete _accounts[ids_[i]];
            delete _recovery[ids_[i]];
        }
    }

    function _exists(string memory id_) private view returns (bool) {
        for (uint256 i; i < _chainIds.length; ++i) {
            if (keccak256(bytes(_chainIds[i])) == keccak256(bytes(id_))) return true;
        }
        return false;
    }
}
