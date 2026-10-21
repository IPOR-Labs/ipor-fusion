// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCreate3Deployer} from "../../contracts/crosschain/ccip/CcipCreate3Deployer.sol";

contract CcipCreate3DeployerTest is Test {
    function testShouldRevertZeroAddressOwner() public {
        vm.expectRevert(CcipCreate3Deployer.ZeroAddress.selector);
        new CcipCreate3Deployer(address(0));
    }
}
