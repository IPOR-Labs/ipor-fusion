// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCreate3Deployer} from "../../contracts/crosschain/ccip/CcipCreate3Deployer.sol";

/// @dev Minimal payload for the deployment: returns a fixed runtime marker.
contract CcipCreate3DeployerPayload {
    uint256 public constant MARKER = 0xC1C1;
}

/// @title CcipCreate3DeployerTest
/// @notice IL-9150: pins the owner gate and the empty-code guard of the CREATE3 anchor on the deployer itself
///         (existing factory tests assert the factory's own `OnlyOwner`, a different error).
contract CcipCreate3DeployerTest is Test {
    CcipCreate3Deployer internal deployer;
    address internal owner;
    address internal stranger;

    bytes32 internal constant SALT = keccak256("ccip-create3-deployer-test");

    function setUp() public {
        owner = makeAddr("owner");
        stranger = makeAddr("stranger");
        deployer = new CcipCreate3Deployer(owner);
    }

    function testShouldRevertZeroAddressOwner() public {
        vm.expectRevert(CcipCreate3Deployer.ZeroAddress.selector);
        new CcipCreate3Deployer(address(0));
    }

    function testShouldRevertOnlyOwnerWhenStrangerDeploys() public {
        address predicted = deployer.getDeployed(SALT);
        bytes memory code = type(CcipCreate3DeployerPayload).creationCode;

        vm.prank(stranger);
        vm.expectRevert(CcipCreate3Deployer.OnlyOwner.selector);
        deployer.deploy(SALT, code);

        assertEq(predicted.code.length, 0, "nothing deployed at the predicted address");
    }

    function testShouldRevertOnlyOwnerBeforeEmptyCodeCheckForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(CcipCreate3Deployer.OnlyOwner.selector);
        deployer.deploy(SALT, "");
    }

    function testShouldRevertEmptyCreationCodeForOwner() public {
        address predicted = deployer.getDeployed(SALT);

        vm.prank(owner);
        vm.expectRevert(CcipCreate3Deployer.EmptyCreationCode.selector);
        deployer.deploy(SALT, "");

        assertEq(predicted.code.length, 0, "nothing deployed at the predicted address");
    }

    function testShouldDeployAtPredictedAddressWhenOwnerDeploys() public {
        address predicted = deployer.getDeployed(SALT);
        assertEq(predicted.code.length, 0, "address is free before deploy");

        vm.prank(owner);
        address deployed = deployer.deploy(SALT, type(CcipCreate3DeployerPayload).creationCode);

        assertEq(deployed, predicted, "deployed at getDeployed(salt)");
        assertGt(deployed.code.length, 0, "code present");
        assertEq(CcipCreate3DeployerPayload(deployed).MARKER(), 0xC1C1, "payload runtime is live");
    }

    function testShouldKeepOwnerImmutable() public view {
        assertEq(deployer.OWNER(), owner, "owner");
    }
}
