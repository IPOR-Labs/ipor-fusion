// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CompoundV3ClaimFuse} from "../../../contracts/rewards_fuses/compound/CompoundV3ClaimFuse.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";

contract CompoundV3ClaimFuseTest is Test {
    address private constant _PLASMA_VAULT_USDC = 0xa91267A25939b2B0f046013fbF9597008F7F014b;
    address private constant _COMET_REWARDS = 0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae;
    address private constant _COMET = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
    address private constant _REWARDS_CLAIM_MANAGER = 0x4bdFeaF09f01AB32E98E144Cd3D7e7831C7225F5;

    address private constant _COMP = 0x354A6dA3fcde098F8389cad84b0182725c6C91dE;

    address private constant _ATOMIST = 0xff560c41eacd072AD025F43DF3516cB6580C96bF;
    address private constant _ALPHA = 0xd8a1087d6bbCd5533F819A4496a06AF452609b99;

    CompoundV3ClaimFuse private _claimFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 259906285);

        _claimFuse = new CompoundV3ClaimFuse(_COMET_REWARDS);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_claimFuse);

        vm.startPrank(_ATOMIST);
        RewardsClaimManager(_REWARDS_CLAIM_MANAGER).addRewardFuses(fuses);
        vm.stopPrank();
    }

    function testShouldClaimRewards() public {
        //given
        FuseAction[] memory claims = new FuseAction[](1);
        claims[0] = FuseAction(address(_claimFuse), abi.encodeWithSignature("claim(address)", _COMET));

        uint256 compBalanceBefore = ERC20(_COMP).balanceOf(_REWARDS_CLAIM_MANAGER);

        //when
        vm.startPrank(_ALPHA);
        RewardsClaimManager(_REWARDS_CLAIM_MANAGER).claimRewards(claims);
        vm.stopPrank();

        //then
        uint256 compBalanceAfter = ERC20(_COMP).balanceOf(_REWARDS_CLAIM_MANAGER);

        assertEq(compBalanceBefore, 0, "compBalanceBefore should be 0");
        assertEq(compBalanceAfter, 21659e12, "compBalanceAfter should be 21659e12");
    }

    function testShouldNotCreateCompoundV3ClaimFuseWhenPassZeroAddress() external {
        bytes memory error = abi.encodeWithSignature("CometRewardsZeroAddress()");

        //when
        vm.expectRevert(error);
        new CompoundV3ClaimFuse(address(0));
    }
}
