// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGuardElectron, TimeLockType} from "./IGuardElectron.sol";

contract GuardElectron is Ownable2Step, IGuardElectron {
    event TimeLockChanged(TimeLockType timeLockType, uint256 newTimelock);
    event AppointedToAccess(address contractAddress, bytes4 functionName, address actor);
    event AccessGrated(address contractAddress, bytes4 functionName, address actor);
    event AccessRevoked(address contractAddress, bytes4 functionName, address actor);
    event ContractPaused(address contractAddress, bytes4 functionName);

    error TimeLockError(uint256 time, uint256 minimalTimeLock);
    error SenderNotGuardian(address sender);
    error SenderNotAtomist(address sender);
    error ArrayLengthMismatch(uint256 len1, uint256 len2);

    //    TimeLocks config
    // TODO confirm minimalTimeLock
    uint32 public minimalTimeLock = 1 hours;
    mapping(TimeLockType timeLockType => uint32 timeLock) public timeLocks;
    mapping(TimeLockType timeLockType => uint32 timestamp) public appointedTimeLocks;

    // pausing configuration
    // @dev isGuardian = 1 means guardian is active
    mapping(address pauseGuardianAddress => uint256 isGuardian) public pauseGuards;
    // @dev isPaused = 1 means contract is paused
    // @dev key = keccak256(abi.encodePacked(address contractAddress, byte4 functionSignature))
    mapping(bytes32 key => uint256 isPaused) public pausedMethods;

    // Access control
    // @dev key = keccak256(abi.encodePacked(address contractAddress, byte4 functionSignature, address actor))
    mapping(bytes32 key => uint32 timestamp) public appointedToGrantAccess;
    // @dev key = keccak256(abi.encodePacked(address contractAddress, byte4 functionSignature, address actor))
    mapping(bytes32 key => uint256 isGranted) public accesses;
    // @dev key = keccak256(abi.encodePacked(address contractAddress, byte4 functionSignature))
    mapping(bytes32 key => uint256 isRevoked) public disabledWhiteList;

    constructor(address atomist_, uint32 minimalTimeLock_) Ownable(atomist_) {
        if (minimalTimeLock_ < minimalTimeLock) {
            revert TimeLockError(minimalTimeLock_, minimalTimeLock);
        }
        minimalTimeLock = minimalTimeLock_;
        timeLocks[TimeLockType.AtomistTransfer] = minimalTimeLock_;
        timeLocks[TimeLockType.AccessControl] = minimalTimeLock_;
    }

    function getAtomist() public view returns (address) {
        return owner();
    }

    function hasAccess(
        address contractAddress_,
        bytes4 functionSignature_,
        address actor_
    ) external view returns (bool) {
        if (disabledWhiteList[keccak256(abi.encodePacked(contractAddress_, functionSignature_))] == 1) {
            return true;
        }
        return accesses[keccak256(abi.encodePacked(contractAddress_, functionSignature_, actor_))] == 1;
    }

    function setTimeLock(TimeLockType timeLockType_, uint32 newTimeLock_) external onlyAtomist {
        if (newTimeLock_ < minimalTimeLock) {
            revert TimeLockError(newTimeLock_, minimalTimeLock);
        }
        timeLocks[timeLockType_] = newTimeLock_;
        emit TimeLockChanged(timeLockType_, newTimeLock_);
    }

    function appointedToAccess(address contractAddress, bytes4 functionName, address actor) external onlyAtomist {
        bytes32 key = keccak256(abi.encodePacked(contractAddress, functionName, actor));
        appointedToGrantAccess[key] = uint32(block.timestamp);
        emit AppointedToAccess(contractAddress, functionName, actor);
    }

    function grantAccess(address contractAddress, bytes4 functionName, address actor) external onlyAtomist {
        bytes32 key = keccak256(abi.encodePacked(contractAddress, functionName, actor));
        uint256 appointedTimeLock = appointedToGrantAccess[key];
        uint256 acceptTime = appointedTimeLock + timeLocks[TimeLockType.AccessControl];
        if (appointedTimeLock > 0 && acceptTime > block.timestamp) {
            revert TimeLockError(block.timestamp, acceptTime);
        }
        accesses[key] = 1;
        appointedToGrantAccess[key] = 0;
        emit AccessGrated(contractAddress, functionName, actor);
    }

    function revokeAccess(address contractAddress, bytes4 functionName, address actor) external onlyAtomist {
        bytes32 key = keccak256(abi.encodePacked(contractAddress, functionName, actor));
        accesses[key] = 0;
        emit AccessRevoked(contractAddress, functionName, actor);
    }

    function transferOwnership(address newOwner_) public override onlyAtomist {
        appointedTimeLocks[TimeLockType.AtomistTransfer] = uint32(block.timestamp);
        super.transferOwnership(newOwner_);
    }

    function acceptOwnership() public override {
        uint256 appointedTimeLock = appointedTimeLocks[TimeLockType.AtomistTransfer];
        uint256 acceptTime = appointedTimeLock + timeLocks[TimeLockType.AtomistTransfer];
        if (appointedTimeLock > 0 && acceptTime > block.timestamp) {
            revert TimeLockError(block.timestamp, acceptTime);
        }
        appointedTimeLocks[TimeLockType.AtomistTransfer] = 0;
        super.acceptOwnership();
    }

    function addPauseGuardians(address[] calldata guardians_) external onlyAtomist {
        uint256 len = guardians_.length;
        for (uint256 i; i < len; ++i) {
            pauseGuards[guardians_[i]] = 1;
        }
    }

    function removePauseGuardians(address[] calldata guardians_) external onlyAtomist {
        uint256 len = guardians_.length;
        for (uint256 i; i < len; ++i) {
            pauseGuards[guardians_[i]] = 0;
        }
    }

    function pause(
        address[] calldata contractAddresses_,
        bytes4[] memory functionSignatures_
    ) external onlyPauseGuardian {
        uint256 len = contractAddresses_.length;
        if (len != functionSignatures_.length) {
            revert ArrayLengthMismatch(len, functionSignatures_.length);
        }
        for (uint256 i; i < len; ++i) {
            bytes32 key = keccak256(abi.encodePacked(contractAddresses_[i], functionSignatures_[i]));
            pausedMethods[key] = 1;
            emit ContractPaused(contractAddresses_[i], functionSignatures_[i]);
        }
    }

    function unpause(address[] calldata contractAddresses_, bytes4[] memory functionSignatures_) external onlyAtomist {
        uint256 len = contractAddresses_.length;
        if (len != functionSignatures_.length) {
            revert ArrayLengthMismatch(len, functionSignatures_.length);
        }
        for (uint256 i; i < len; ++i) {
            bytes32 key = keccak256(abi.encodePacked(contractAddresses_[i], functionSignatures_[i]));
            pausedMethods[key] = 0;
        }
    }

    function disableWhiteList(address contractAddress_, bytes4 functionSignature_) external onlyAtomist {
        bytes32 key = keccak256(abi.encodePacked(contractAddress_, functionSignature_));
        disabledWhiteList[key] = 1;
    }

    function enableWhiteList(address contractAddress_, bytes4 functionSignature_) external onlyAtomist {
        bytes32 key = keccak256(abi.encodePacked(contractAddress_, functionSignature_));
        disabledWhiteList[key] = 0;
    }

    modifier onlyPauseGuardian() {
        if (pauseGuards[msg.sender] != 1) {
            revert SenderNotGuardian(msg.sender);
        }
        _;
    }

    modifier onlyAtomist() {
        if (msg.sender != getAtomist()) {
            revert SenderNotAtomist(msg.sender);
        }
        _;
    }
}
