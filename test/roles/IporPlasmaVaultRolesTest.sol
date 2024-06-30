// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

contract IporPlasmaVaultRolesTest is Test {
    address private _deployer = vm.rememberKey(1);
    DataForInitialization private _data;

    function _generateDataForInitialization() private {
        _data.admins = new address[](0);
        _data.owners = new address[](1);
        _data.owners[0] = vm.rememberKey(2);
        _data.atomists = new address[](1);
        _data.atomists[0] = vm.rememberKey(3);
        _data.alphas = new address[](1);
        _data.alphas[0] = vm.rememberKey(4);
        _data.whitelist = new address[](1);
        _data.whitelist[0] = vm.rememberKey(5);
        _data.guardians = new address[](1);
        _data.guardians[0] = vm.rememberKey(6);
        _data.fuseManagers = _generateAddresses(10_000_000, 10);
        _data.performanceFeeManagers = _generateAddresses(100_000_000, 10);
        _data.managementFeeManagers = _generateAddresses(1_000_000_000, 10);
        _data.claimRewardsManagers = _generateAddresses(10_000_000_000, 10);
        _data.transferRewardsManagers = _generateAddresses(100_000_000_000, 10);
        _data.configInstantWithdrawalFusesManagers = _generateAddresses(1_000_000_000_000, 10);

        return data;
    }
}
