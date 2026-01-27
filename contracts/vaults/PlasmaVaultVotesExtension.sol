// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {IPlasmaVaultVotesExtension} from "../interfaces/IPlasmaVaultVotesExtension.sol";
import {ContextClientStorageLib} from "../managers/context/ContextClientStorageLib.sol";

/**
 * @title PlasmaVaultVotesExtension
 * @notice Optional extension providing ERC20Votes functionality for PlasmaVault
 * @dev This contract is called via delegatecall from PlasmaVault to provide voting capabilities
 *
 * Architecture:
 * - Uses ERC-7201 namespaced storage (same slots as OpenZeppelin VotesUpgradeable)
 * - Reads ERC20 balances directly from caller's storage in delegatecall context
 * - Shares nonces with ERC20Permit (NoncesUpgradeable storage)
 * - Shares EIP712 domain with ERC20Permit (EIP712Upgradeable storage)
 *
 * Gas Optimization:
 * - Vaults without voting enabled skip all checkpoint updates during transfers
 * - Only vaults that need governance pay the ~2800-9800 gas overhead per transfer
 *
 * Storage Slots (ERC-7201):
 * - VotesStorage: 0xe8b26c30fad74198956032a3533d903385d56dd795af560196f9c78d4af40d00
 * - NoncesStorage: 0x5ab42ced628888259c08ac98db1eb0cf702fc1501344311d8b100cd1bfe4bb00
 * - EIP712Storage: 0xa16a46d94261c7517cc8ff89f61c0ce93598e3c849801011dee649a6a557d100
 * - ERC20Storage: 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00
 *
 * @custom:security-contact security@ipor.io
 */
contract PlasmaVaultVotesExtension is IPlasmaVaultVotesExtension {
    using Checkpoints for Checkpoints.Trace208;

    // ============ Constants ============

    bytes32 private constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    bytes32 private constant EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // ERC-7201 storage slots (must match OpenZeppelin implementations)
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Votes")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VOTES_STORAGE_LOCATION =
        0xe8b26c30fad74198956032a3533d903385d56dd795af560196f9c78d4af40d00;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Nonces")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NONCES_STORAGE_LOCATION =
        0x5ab42ced628888259c08ac98db1eb0cf702fc1501344311d8b100cd1bfe4bb00;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.EIP712")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EIP712_STORAGE_LOCATION =
        0xa16a46d94261c7517cc8ff89f61c0ce93598e3c849801011dee649a6a557d100;

    // ERC20 storage base slot
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_STORAGE_LOCATION =
        0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    // ============ Errors ============

    /// @dev The clock was incorrectly modified
    error ERC6372InconsistentClock();

    /// @dev Lookup to future votes is not available
    error ERC5805FutureLookup(uint256 timepoint, uint48 clock);

    /// @dev The nonce used for an account is not the expected current nonce
    error InvalidAccountNonce(address account, uint256 currentNonce);

    // Note: VotesExpiredSignature, DelegateChanged, and DelegateVotesChanged are
    // inherited from IVotes via IERC5805

    // ============ Storage Structs ============

    /// @custom:storage-location erc7201:openzeppelin.storage.Votes
    struct VotesStorage {
        mapping(address account => address) _delegatee;
        mapping(address delegatee => Checkpoints.Trace208) _delegateCheckpoints;
        Checkpoints.Trace208 _totalCheckpoints;
    }

    /// @custom:storage-location erc7201:openzeppelin.storage.Nonces
    struct NoncesStorage {
        mapping(address account => uint256) _nonces;
    }

    /// @custom:storage-location erc7201:openzeppelin.storage.EIP712
    struct EIP712Storage {
        bytes32 _hashedName;
        bytes32 _hashedVersion;
        string _name;
        string _version;
    }

    // ============ Storage Access ============

    function _getVotesStorage() private pure returns (VotesStorage storage $) {
        assembly {
            $.slot := VOTES_STORAGE_LOCATION
        }
    }

    function _getNoncesStorage() private pure returns (NoncesStorage storage $) {
        assembly {
            $.slot := NONCES_STORAGE_LOCATION
        }
    }

    function _getEIP712Storage() private pure returns (EIP712Storage storage $) {
        assembly {
            $.slot := EIP712_STORAGE_LOCATION
        }
    }

    // ============ IERC6372 Implementation ============

    /// @notice Clock used for flagging checkpoints (block number)
    function clock() public view virtual returns (uint48) {
        return Time.blockNumber();
    }

    /// @notice Description of the clock
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual returns (string memory) {
        if (clock() != Time.blockNumber()) {
            revert ERC6372InconsistentClock();
        }
        return "mode=blocknumber&from=default";
    }

    // ============ IVotes Implementation ============

    /// @notice Returns the current amount of votes that `account` has
    function getVotes(address account) public view virtual returns (uint256) {
        VotesStorage storage $ = _getVotesStorage();
        return $._delegateCheckpoints[account].latest();
    }

    /// @notice Returns the amount of votes that `account` had at a specific moment in the past
    function getPastVotes(address account, uint256 timepoint) public view virtual returns (uint256) {
        VotesStorage storage $ = _getVotesStorage();
        uint48 currentTimepoint = clock();
        if (timepoint >= currentTimepoint) {
            revert ERC5805FutureLookup(timepoint, currentTimepoint);
        }
        return $._delegateCheckpoints[account].upperLookupRecent(SafeCast.toUint48(timepoint));
    }

    /// @notice Returns the total supply of votes available at a specific moment in the past
    function getPastTotalSupply(uint256 timepoint) public view virtual returns (uint256) {
        VotesStorage storage $ = _getVotesStorage();
        uint48 currentTimepoint = clock();
        if (timepoint >= currentTimepoint) {
            revert ERC5805FutureLookup(timepoint, currentTimepoint);
        }
        return $._totalCheckpoints.upperLookupRecent(SafeCast.toUint48(timepoint));
    }

    /// @notice Returns the delegate that `account` has chosen
    function delegates(address account) public view virtual returns (address) {
        VotesStorage storage $ = _getVotesStorage();
        return $._delegatee[account];
    }

    /// @notice Delegates votes from the sender to `delegatee`
    function delegate(address delegatee) public virtual {
        address account = _msgSender();
        _delegate(account, delegatee);
    }

    /// @notice Delegates votes from signer to `delegatee`
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        if (block.timestamp > expiry) {
            revert VotesExpiredSignature(expiry);
        }
        address signer = ECDSA.recover(
            _hashTypedDataV4(keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry))),
            v,
            r,
            s
        );
        _useCheckedNonce(signer, nonce);
        _delegate(signer, delegatee);
    }

    // ============ Extension-specific Methods ============

    /// @inheritdoc IPlasmaVaultVotesExtension
    function transferVotingUnits(address from_, address to_, uint256 amount_) external {
        _transferVotingUnits(from_, to_, amount_);
    }

    /// @inheritdoc IPlasmaVaultVotesExtension
    function numCheckpoints(address account_) public view virtual returns (uint32) {
        VotesStorage storage $ = _getVotesStorage();
        return SafeCast.toUint32($._delegateCheckpoints[account_].length());
    }

    /// @inheritdoc IPlasmaVaultVotesExtension
    function checkpoints(address account_, uint32 pos_) public view virtual returns (Checkpoints.Checkpoint208 memory) {
        VotesStorage storage $ = _getVotesStorage();
        return $._delegateCheckpoints[account_].at(pos_);
    }

    // ============ Internal Functions ============

    function _delegate(address account, address delegatee) internal virtual {
        VotesStorage storage $ = _getVotesStorage();
        address oldDelegate = delegates(account);
        $._delegatee[account] = delegatee;

        emit DelegateChanged(account, oldDelegate, delegatee);
        _moveDelegateVotes(oldDelegate, delegatee, _getVotingUnits(account));
    }

    function _transferVotingUnits(address from, address to, uint256 amount) internal virtual {
        VotesStorage storage $ = _getVotesStorage();
        if (from == address(0)) {
            _push($._totalCheckpoints, _add, SafeCast.toUint208(amount));
        }
        if (to == address(0)) {
            _push($._totalCheckpoints, _subtract, SafeCast.toUint208(amount));
        }
        _moveDelegateVotes(delegates(from), delegates(to), amount);
    }

    function _moveDelegateVotes(address from, address to, uint256 amount) private {
        VotesStorage storage $ = _getVotesStorage();
        if (from != to && amount > 0) {
            if (from != address(0)) {
                (uint256 oldValue, uint256 newValue) = _push(
                    $._delegateCheckpoints[from],
                    _subtract,
                    SafeCast.toUint208(amount)
                );
                emit DelegateVotesChanged(from, oldValue, newValue);
            }
            if (to != address(0)) {
                (uint256 oldValue, uint256 newValue) = _push(
                    $._delegateCheckpoints[to],
                    _add,
                    SafeCast.toUint208(amount)
                );
                emit DelegateVotesChanged(to, oldValue, newValue);
            }
        }
    }

    function _push(
        Checkpoints.Trace208 storage store,
        function(uint208, uint208) view returns (uint208) op,
        uint208 delta
    ) private returns (uint208, uint208) {
        return store.push(clock(), op(store.latest(), delta));
    }

    function _add(uint208 a, uint208 b) private pure returns (uint208) {
        return a + b;
    }

    function _subtract(uint208 a, uint208 b) private pure returns (uint208) {
        return a - b;
    }

    /// @dev Returns the voting units of an account (ERC20 balance in delegatecall context)
    function _getVotingUnits(address account) internal view virtual returns (uint256) {
        return _balanceOf(account);
    }

    /// @dev Reads ERC20 balance directly from storage (works in delegatecall context)
    function _balanceOf(address account) internal view returns (uint256 bal) {
        // ERC20 balances mapping is at ERC20_STORAGE_LOCATION (first slot in struct)
        bytes32 slot = keccak256(abi.encode(account, ERC20_STORAGE_LOCATION));
        assembly {
            bal := sload(slot)
        }
    }

    // ============ Nonces ============

    /// @dev Returns the next unused nonce for an address
    function nonces(address owner) public view virtual returns (uint256) {
        NoncesStorage storage $ = _getNoncesStorage();
        return $._nonces[owner];
    }

    /// @dev Consumes a nonce after verifying it matches the expected value
    function _useCheckedNonce(address owner, uint256 nonce) internal virtual {
        uint256 current = _useNonce(owner);
        if (nonce != current) {
            revert InvalidAccountNonce(owner, current);
        }
    }

    /// @dev Consumes a nonce and returns the current value
    function _useNonce(address owner) internal virtual returns (uint256) {
        NoncesStorage storage $ = _getNoncesStorage();
        unchecked {
            return $._nonces[owner]++;
        }
    }

    // ============ EIP712 ============

    /// @dev Returns the domain separator for the current chain
    function _domainSeparatorV4() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_TYPE_HASH, _EIP712NameHash(), _EIP712VersionHash(), block.chainid, address(this)));
    }

    /// @dev Returns the hash of the fully encoded EIP712 message
    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    /// @dev Returns the hash of the EIP712 name
    function _EIP712NameHash() internal view returns (bytes32) {
        EIP712Storage storage $ = _getEIP712Storage();
        string memory name = $._name;
        if (bytes(name).length > 0) {
            return keccak256(bytes(name));
        } else {
            bytes32 hashedName = $._hashedName;
            if (hashedName != 0) {
                return hashedName;
            } else {
                return keccak256("");
            }
        }
    }

    /// @dev Returns the hash of the EIP712 version
    function _EIP712VersionHash() internal view returns (bytes32) {
        EIP712Storage storage $ = _getEIP712Storage();
        string memory version = $._version;
        if (bytes(version).length > 0) {
            return keccak256(bytes(version));
        } else {
            bytes32 hashedVersion = $._hashedVersion;
            if (hashedVersion != 0) {
                return hashedVersion;
            } else {
                return keccak256("");
            }
        }
    }

    // ============ Context ============

    /// @dev Gets the message sender from context (same as PlasmaVaultBase)
    function _msgSender() internal view returns (address) {
        return ContextClientStorageLib.getSenderFromContext();
    }
}
