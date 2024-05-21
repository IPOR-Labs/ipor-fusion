// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

enum TimeLockType {
    AtomistTransfer, //todo fix atomist
    AccessControl
}

interface IGuardElectron {
    function getAtomist() external view returns (address);
}
