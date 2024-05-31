// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

contract MockPlasmaVault {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}
