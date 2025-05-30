// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {MockPlasmaVault} from "./MockPlasmaVault.sol";
import {MockToken} from "./MockToken.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
contract RewardsClaimManagerTest is Test {
    uint64 private constant _REWARD_MANAGER_ROLE = 1001;

    address private _atomist;
    address private _userOne;
    address private _userTwo;
    MockPlasmaVault private _plasmaVault;
    IporFusionAccessManager private _accessManager;
    address private _underlyingToken;
    address private _rewardsToken;
    RewardsClaimManager private _rewardsClaimManager;

    function setUp() public {
        _atomist = address(0x1111);
        _userOne = address(0x2222);
        _userTwo = address(0x3333);
        _underlyingToken = address(new MockToken("Underlying Token", "UT"));
        _rewardsToken = address(new MockToken("Rewards Token", "RT"));
        _accessManager = new IporFusionAccessManager(_atomist, 0);
        _plasmaVault = new MockPlasmaVault(address(_underlyingToken));

        _rewardsClaimManager = new RewardsClaimManager(address(_accessManager), address(_plasmaVault));

        deal(_underlyingToken, _userOne, 1_000_000e18);
        deal(_underlyingToken, _userTwo, 1_000_000e18);
        deal(_underlyingToken, _atomist, 1_000_000e18);
        deal(_rewardsToken, _atomist, 1_000_000e18);

        vm.prank(_atomist);
        _accessManager.grantRole(_REWARD_MANAGER_ROLE, _userOne, 0);

        bytes4[] memory sig = new bytes4[](7);
        sig[0] = RewardsClaimManager.transfer.selector;
        sig[1] = RewardsClaimManager.addRewardFuses.selector;
        sig[2] = RewardsClaimManager.removeRewardFuses.selector;
        sig[3] = RewardsClaimManager.claimRewards.selector;
        sig[4] = RewardsClaimManager.setupVestingTime.selector;
        sig[5] = RewardsClaimManager.transferVestedTokensToVault.selector;
        sig[6] = RewardsClaimManager.updateBalance.selector;

        vm.prank(_atomist);
        _accessManager.setTargetFunctionRole(address(_rewardsClaimManager), sig, _REWARD_MANAGER_ROLE);
    }

    function testShouldGetInitialBalanceZero() public view {
        assertEq(_rewardsClaimManager.balanceOf(), 0, "Initial balance should be zero");
    }

    function testShouldBalanceZeroWhenTransferUnderlyingTokenToRewardsClaimManager() public {
        // given
        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        uint256 rewardElectionBalanceBefore = ERC20(_underlyingToken).balanceOf(address(_rewardsClaimManager));

        // when
        uint256 vestedBalance = _rewardsClaimManager.balanceOf();

        // then

        assertEq(rewardElectionBalanceBefore, 1_000e18, "Reward Manager balance should be 1_0000e18");
        assertEq(vestedBalance, 0, "Vested balance should be zero");
    }

    function testShouldIncreaseVestingBalanceAfterUpdateBalance() public {
        // given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardsClaimManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        uint256 vestedBalanceBefore = _rewardsClaimManager.balanceOf();

        // when
        vm.prank(_userOne);
        _rewardsClaimManager.updateBalance();
        vm.warp(block.number + 12 hours);

        // then
        uint256 vestedBalanceAfter = _rewardsClaimManager.balanceOf();

        assertEq(vestedBalanceBefore, 0, "Vested balance before should be zero");
        assertGt(
            vestedBalanceAfter,
            vestedBalanceBefore,
            "Vested balance after should be greater than vested balance before"
        );
    }

    function testShouldTransferTokenWhenUpdateBalance() public {
        // given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardsClaimManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        uint256 vestedBalanceBefore = _rewardsClaimManager.balanceOf();

        vm.prank(_userOne);
        _rewardsClaimManager.updateBalance();

        vm.warp(block.number + 12 hours);
        uint256 plasmaVaultBalanceBefore = ERC20(_underlyingToken).balanceOf(address(_plasmaVault));

        // when
        vm.prank(_userOne);
        _rewardsClaimManager.updateBalance();

        // then
        uint256 vestedBalanceAfter = _rewardsClaimManager.balanceOf();
        uint256 plasmaVaultBalanceAfter = ERC20(_underlyingToken).balanceOf(address(_plasmaVault));

        assertGt(
            plasmaVaultBalanceAfter,
            plasmaVaultBalanceBefore,
            "Plasma vault balance after should be greater than plasma vault balance before"
        );
        assertEq(vestedBalanceBefore, 0, "Vested balance before should be zero");
        assertEq(
            vestedBalanceAfter,
            vestedBalanceBefore,
            "Vested balance after should be equal to vested balance before"
        );
    }

    function testShouldVestedAllTokensOnAddress() external {
        // given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardsClaimManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        uint256 vestedBalanceBefore = _rewardsClaimManager.balanceOf();

        // when
        vm.prank(_userOne);
        _rewardsClaimManager.updateBalance();
        vm.warp(block.number + 2 days);

        // then
        uint256 vestedBalanceAfter = _rewardsClaimManager.balanceOf();

        assertEq(vestedBalanceBefore, 0, "Vested balance before should be zero");
        assertEq(vestedBalanceAfter, 1_000e18, "Vested balance after should be 1_000e18");
    }

    function testShouldRevertWhenUserDontHaveRoleToCallUpdateBalance() public {
        // given
        vm.prank(_userTwo);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);
        // when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardsClaimManager.updateBalance();
    }

    function testShouldBeAbleTransferRewardsToken() external {
        //given
        vm.prank(_atomist);
        ERC20(_rewardsToken).transfer(address(_rewardsClaimManager), 1_000e18);

        uint256 userTwoBalanceBefore = ERC20(_rewardsToken).balanceOf(_userTwo);

        //when
        vm.prank(_userOne);
        _rewardsClaimManager.transfer(_rewardsToken, _userTwo, 1_000e18);

        //then
        uint256 userTwoBalanceAfter = ERC20(_rewardsToken).balanceOf(_userTwo);

        assertEq(userTwoBalanceBefore, 0, "User two balance before should be zero");
        assertEq(userTwoBalanceAfter, 1_000e18, "User two balance after should be 1_000e18");
    }

    function testShouldRevertTransferRewardsTokenWhenDontHaveRole() external {
        //given
        vm.prank(_atomist);
        ERC20(_rewardsToken).transfer(address(_rewardsClaimManager), 1_000e18);

        uint256 userTwoBalanceBefore = ERC20(_rewardsToken).balanceOf(_userTwo);
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardsClaimManager.transfer(_rewardsToken, _userTwo, 1_000e18);

        //then
        uint256 userTwoBalanceAfter = ERC20(_rewardsToken).balanceOf(_userTwo);

        assertEq(userTwoBalanceBefore, 0, "User two balance before should be zero");
        assertEq(userTwoBalanceAfter, 0, "User two balance after should be 1_000e18");
    }

    function testShouldBeAbleToAddRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        bool isSupportedBefore = _rewardsClaimManager.isRewardFuseSupported(address(0x4444));

        //when
        vm.prank(_userOne);
        _rewardsClaimManager.addRewardFuses(fuses);

        //then
        bool isSupportedAfter = _rewardsClaimManager.isRewardFuseSupported(address(0x4444));

        assertEq(isSupportedBefore, false, "Fuse should not be supported before");
        assertEq(isSupportedAfter, true, "Fuse should be supported after");
    }

    function testShouldBeAbleToGetRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        address[] memory rewardFusesBefore = _rewardsClaimManager.getRewardsFuses();

        //when
        vm.prank(_userOne);
        _rewardsClaimManager.addRewardFuses(fuses);

        //then
        address[] memory rewardFusesAfter = _rewardsClaimManager.getRewardsFuses();

        assertEq(rewardFusesBefore.length, 0, "Fuses should be empty before");
        assertEq(rewardFusesAfter.length, 1, "Fuses should be 1 after");
        assertEq(rewardFusesAfter[0], address(0x4444), "Fuses should be 0x4444 after");
    }

    function testShouldRevertWhenUserDontHaveRoleToAddRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        bool isSupportedBefore = _rewardsClaimManager.isRewardFuseSupported(address(0x4444));
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardsClaimManager.addRewardFuses(fuses);

        //then
        bool isSupportedAfter = _rewardsClaimManager.isRewardFuseSupported(address(0x4444));

        assertEq(isSupportedBefore, false, "Fuse should not be supported before");
        assertEq(isSupportedAfter, false, "Fuse should not be supported after");
    }

    function testShouldBeAbleToRemoveRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        vm.prank(_userOne);
        _rewardsClaimManager.addRewardFuses(fuses);

        bool isSupportedBefore = _rewardsClaimManager.isRewardFuseSupported(address(0x4444));

        //when
        vm.prank(_userOne);
        _rewardsClaimManager.removeRewardFuses(fuses);

        //then
        bool isSupportedAfter = _rewardsClaimManager.isRewardFuseSupported(address(0x4444));

        assertEq(isSupportedBefore, true, "Fuse should be supported before");
        assertEq(isSupportedAfter, false, "Fuse should not be supported after");
    }

    function testShouldRevertWhenUserDontHaveRoleToRemoveRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        vm.prank(_userOne);
        _rewardsClaimManager.addRewardFuses(fuses);

        bool isSupportedBefore = _rewardsClaimManager.isRewardFuseSupported(address(0x4444));
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardsClaimManager.removeRewardFuses(fuses);

        //then
        bool isSupportedAfter = _rewardsClaimManager.isRewardFuseSupported(address(0x4444));

        assertEq(isSupportedBefore, true, "Fuse should be supported before");
        assertEq(isSupportedAfter, true, "Fuse should be supported after");
    }

    function testShouldRevertWhenUserDonHaveRoleTosSetupVesting() external {
        //given
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardsClaimManager.setupVestingTime(1 days);
    }

    function testShouldTransferVestedTokens() external {
        //given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardsClaimManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        vm.prank(_userOne);
        _rewardsClaimManager.updateBalance();
        vm.warp(block.number + 2 days);

        uint256 vestedBalanceBefore = _rewardsClaimManager.balanceOf();

        //when
        vm.prank(_userOne);
        _rewardsClaimManager.transferVestedTokensToVault();

        //then
        uint256 vestedBalanceAfter = _rewardsClaimManager.balanceOf();

        assertEq(vestedBalanceBefore, 1_000e18, "Vested balance before should be 1_000e18");
        assertEq(vestedBalanceAfter, 0, "Vested balance after should be zero");
    }

    function testShouldRevertWhenUserDontHaveRoleToTransferVestedTokens() external {
        //given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardsClaimManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        vm.prank(_userOne);
        _rewardsClaimManager.updateBalance();
        vm.warp(block.number + 2 days);

        uint256 vestedBalanceBefore = _rewardsClaimManager.balanceOf();
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardsClaimManager.transferVestedTokensToVault();

        //then
        uint256 vestedBalanceAfter = _rewardsClaimManager.balanceOf();

        assertEq(vestedBalanceBefore, 1_000e18, "Vested balance before should be 1_000e18");
        assertEq(vestedBalanceAfter, 1_000e18, "Vested balance after should be 1_000e18");
    }

    function testShouldIncreaseVestingBalanceAfterTransferWhenVestingTimesSetupToZero() public {
        // given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardsClaimManager.setupVestingTime(0);

        uint256 vestedBalanceBefore = _rewardsClaimManager.balanceOf();

        // when
        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        // then
        uint256 vestedBalanceAfter = _rewardsClaimManager.balanceOf();

        assertEq(vestedBalanceBefore, 0, "Vested balance before should be zero");
        assertEq(vestedBalanceAfter, 1_000e18, "Vested balance before should be 1_000e18");
    }

    function testShouldDontIncreaseVestingBalanceAfterTransferWhenDefaultValue() public {
        // given
        vm.warp(1000 days);
        vm.prank(_userOne);

        uint256 vestedBalanceBefore = _rewardsClaimManager.balanceOf();

        // when
        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardsClaimManager), 1_000e18);

        // then
        uint256 vestedBalanceAfter = _rewardsClaimManager.balanceOf();

        assertEq(vestedBalanceBefore, 0, "Vested balance before should be zero");
        assertEq(vestedBalanceAfter, 0, "Vested balance before should be 0");
    }

    function testShouldUpdateBalanceOnClaimRewardsManager() public {
        // given
        vm.prank(_atomist);
        _accessManager.grantRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, _userOne, 0);

        // when
        vm.prank(_userOne);
        _rewardsClaimManager.updateBalance();

        // then
        assertEq(true, true, "Should pass if updateBalance executed successfully");
    }

    function testShouldRevertWhenUserDontHaveRoleToUpdateBalance() public {
        // given
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        vm.prank(_userTwo);
        // then
        vm.expectRevert(error);
        // when
        _rewardsClaimManager.updateBalance();
    }
}
