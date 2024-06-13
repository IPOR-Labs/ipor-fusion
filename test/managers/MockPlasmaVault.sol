// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

contract MockPlasmaVault {
    //solhint-disable-next-line immutable-vars-naming
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}
