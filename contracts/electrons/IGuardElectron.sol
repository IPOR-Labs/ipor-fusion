// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

enum TimeLockType {
    AtomistTransfer,
    AccessControl
}

interface IGuardElectron {
    function getAtomist() external view returns (address);

    function hasAccess(
        address contractAddress_,
        bytes4 functionSignature_,
        address actor_
    ) external view returns (bool);
}
