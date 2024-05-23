// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGuardElectron, TimeLockType} from "./IGuardElectron.sol";

contract GuardElectron is Ownable2Step, IGuardElectron {
    event TimeLockChanged(TimeLockType timeLockType, uint256 newTimelock);
    event AppointedToAccess(address contractAddress, bytes4 functionName, address actor);
    event AccessGranted(address contractAddress, bytes4 functionName, address actor);
    event AccessRevoked(address contractAddress, bytes4 functionName, address actor);
    event ContractPaused(address contractAddress, bytes4 functionName);

    error TimelockError(uint256 time, uint256 minimalTimeLock);
    error SenderNotGuardian();
    error SenderNotAtomist();
    error ArrayLengthMismatch(uint256 len1, uint256 len2);

    //    TimeLocks config
    // TODO confirm minimalTimeLock
    uint32 public minimalTimeLock = 1 hours;
    mapping(TimeLockType timeLockType => uint32 timeLock) public timelocks;
    mapping(TimeLockType timeLockType => uint32 timestamp) public appointedTimeLocks;

    // pausing configuration
    // @dev isGuardian = 1 means guardian is active
    mapping(address pauseGuardianAddress => uint256 isGuardian) public pauseGuardians;
    // @dev isPaused = 1 means contract is paused
    // @dev key = keccak256(abi.encodePacked(address contractAddress, byte4 functionSignature))
    mapping(bytes32 key => uint256 isPaused) public pausedMethods;

    // Access control
    // @dev key = keccak256(abi.encodePacked(address contractAddress, byte4 functionSignature, address actor))
    mapping(bytes32 key => uint32 timestamp) public appointedToGrantAccess;
    // @dev key = keccak256(abi.encodePacked(address contractAddress, byte4 functionSignature, address actor))
    mapping(bytes32 key => uint256 isGranted) public accesses;
    // @dev key = keccak256(abi.encodePacked(address contractAddress, byte4 functionSignature))
    mapping(bytes32 key => uint256 isRevoked) public disabledWhitelist;

    modifier onlyPauseGuardian() {
        if (pauseGuardians[msg.sender] != 1) {
            revert SenderNotGuardian();
        }
        _;
    }

    modifier onlyAtomist() {
        if (msg.sender != getAtomist()) {
            revert SenderNotAtomist();
        }
        _;
    }

    constructor(address atomist_, uint32 minimalTimeLock_) Ownable(atomist_) {
        if (minimalTimeLock_ < minimalTimeLock) {
            revert TimelockError(minimalTimeLock_, minimalTimeLock);
        }
        minimalTimeLock = minimalTimeLock_;
        timelocks[TimeLockType.AtomistTransferOwnership] = minimalTimeLock_;
        timelocks[TimeLockType.AccessControl] = minimalTimeLock_;
    }

    function getAtomist() public view returns (address) {
        return owner();
    }

    function hasAccess(
        address contractAddress_,
        bytes4 functionSignature_,
        address actor_
    ) external view override returns (bool) {
        if (disabledWhitelist[keccak256(abi.encodePacked(contractAddress_, functionSignature_))] == 1) {
            return true;
        }
        return accesses[keccak256(abi.encodePacked(contractAddress_, functionSignature_, actor_))] == 1;
    }

    function setTimeLock(TimeLockType timeLockType_, uint32 newTimeLock_) external override onlyAtomist {
        if (newTimeLock_ < minimalTimeLock) {
            revert TimelockError(newTimeLock_, minimalTimeLock);
        }
        timelocks[timeLockType_] = newTimeLock_;
        emit TimeLockChanged(timeLockType_, newTimeLock_);
    }

    function appointToGrantAccess(
        address contractAddress_,
        bytes4 functionSig_,
        address actor_
    ) external override onlyAtomist {
        appointedToGrantAccess[keccak256(abi.encodePacked(contractAddress_, functionSig_, actor_))] = uint32(
            block.timestamp
        );
        emit AppointedToAccess(contractAddress_, functionSig_, actor_);
    }

    function grantAccess(address contractAddress_, bytes4 functionSig_, address actor_) external override onlyAtomist {
        bytes32 key = keccak256(abi.encodePacked(contractAddress_, functionSig_, actor_));
        uint256 appointedTimeLock = appointedToGrantAccess[key];
        uint256 acceptTime = appointedTimeLock + timelocks[TimeLockType.AccessControl];
        if (appointedTimeLock > 0 && acceptTime > block.timestamp) {
            revert TimelockError(block.timestamp, acceptTime);
        }
        accesses[key] = 1;
        appointedToGrantAccess[key] = 0;
        emit AccessGranted(contractAddress_, functionSig_, actor_);
    }

    function pendingAccess(
        address contractAddress_,
        bytes4 functionSig_,
        address actor_
    ) external view override returns (bool) {
        return appointedToGrantAccess[keccak256(abi.encodePacked(contractAddress_, functionSig_, actor_))] > 0;
    }

    function revokeAccess(address contractAddress_, bytes4 functionSig_, address actor_) external override onlyAtomist {
        accesses[keccak256(abi.encodePacked(contractAddress_, functionSig_, actor_))] = 0;
        emit AccessRevoked(contractAddress_, functionSig_, actor_);
    }

    function transferOwnership(address newOwner_) public override onlyAtomist {
        appointedTimeLocks[TimeLockType.AtomistTransferOwnership] = uint32(block.timestamp);
        super.transferOwnership(newOwner_);
    }

    function acceptOwnership() public override {
        uint256 appointedTimeLock = appointedTimeLocks[TimeLockType.AtomistTransferOwnership];
        uint256 acceptTime = appointedTimeLock + timelocks[TimeLockType.AtomistTransferOwnership];
        if (appointedTimeLock > 0 && acceptTime > block.timestamp) {
            revert TimelockError(block.timestamp, acceptTime);
        }
        appointedTimeLocks[TimeLockType.AtomistTransferOwnership] = 0;
        super.acceptOwnership();
    }

    function addPauseGuardians(address[] calldata guardians_) external override onlyAtomist {
        uint256 len = guardians_.length;
        for (uint256 i; i < len; ++i) {
            pauseGuardians[guardians_[i]] = 1;
        }
    }

    function removePauseGuardians(address[] calldata guardians_) external override onlyAtomist {
        uint256 len = guardians_.length;
        for (uint256 i; i < len; ++i) {
            pauseGuardians[guardians_[i]] = 0;
        }
    }

    function pause(
        address[] calldata contractAddresses_,
        bytes4[] memory functionSig_
    ) external override onlyPauseGuardian {
        uint256 len = contractAddresses_.length;
        if (len != functionSig_.length) {
            revert ArrayLengthMismatch(len, functionSig_.length);
        }
        for (uint256 i; i < len; ++i) {
            bytes32 key = keccak256(abi.encodePacked(contractAddresses_[i], functionSig_[i]));
            pausedMethods[key] = 1;
            emit ContractPaused(contractAddresses_[i], functionSig_[i]);
        }
    }

    function unpause(
        address[] calldata contractAddresses_,
        bytes4[] memory functionSignatures_
    ) external override onlyAtomist {
        uint256 len = contractAddresses_.length;
        if (len != functionSignatures_.length) {
            revert ArrayLengthMismatch(len, functionSignatures_.length);
        }
        for (uint256 i; i < len; ++i) {
            bytes32 key = keccak256(abi.encodePacked(contractAddresses_[i], functionSignatures_[i]));
            pausedMethods[key] = 0;
        }
    }

    function disableWhiteList(address contractAddress_, bytes4 functionSignature_) external override onlyAtomist {
        bytes32 key = keccak256(abi.encodePacked(contractAddress_, functionSignature_));
        disabledWhitelist[key] = 1;
    }

    function enableWhiteList(address contractAddress_, bytes4 functionSignature_) external override onlyAtomist {
        bytes32 key = keccak256(abi.encodePacked(contractAddress_, functionSignature_));
        disabledWhitelist[key] = 0;
    }
}
