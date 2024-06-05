// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultAccessManager} from "../../contracts/managers/PlasmaVaultAccessManager.sol";
import {RewardsManager} from "../../contracts/managers/RewardsManager.sol";
import {MockPlasmaVault} from "./MockPlasmaVault.sol";
import {MockToken} from "./MockToken.sol";

contract RewardManagerTest is Test {
    uint64 private constant _REWARD_MANAGER_ROLE = 1001;

    address private _atomist;
    address private _userOne;
    address private _userTwo;
    MockPlasmaVault private _plasmaVault;
    PlasmaVaultAccessManager private _accessManager;
    address private _underlyingToken;
    address private _rewardsToken;
    RewardsManager private _rewardManager;

    function setUp() public {
        _atomist = address(0x1111);
        _userOne = address(0x2222);
        _userTwo = address(0x3333);
        _underlyingToken = address(new MockToken("Underlying Token", "UT"));
        _rewardsToken = address(new MockToken("Rewards Token", "RT"));
        _accessManager = new PlasmaVaultAccessManager(_atomist);
        _plasmaVault = new MockPlasmaVault(address(_underlyingToken));

        _rewardManager = new RewardsManager(address(_accessManager), address(_plasmaVault));

        deal(_underlyingToken, _userOne, 1_000_000e18);
        deal(_underlyingToken, _userTwo, 1_000_000e18);
        deal(_underlyingToken, _atomist, 1_000_000e18);
        deal(_rewardsToken, _atomist, 1_000_000e18);

        vm.prank(_atomist);
        _accessManager.grantRole(_REWARD_MANAGER_ROLE, _userOne, 0);

        bytes4[] memory sig = new bytes4[](7);
        sig[0] = RewardsManager.transfer.selector;
        sig[1] = RewardsManager.addRewardFuses.selector;
        sig[2] = RewardsManager.removeRewardFuses.selector;
        sig[3] = RewardsManager.claimRewards.selector;
        sig[4] = RewardsManager.setupVestingTime.selector;
        sig[5] = RewardsManager.transferVestedTokensToVault.selector;
        sig[6] = RewardsManager.updateBalance.selector;

        vm.prank(_atomist);
        _accessManager.setTargetFunctionRole(address(_rewardManager), sig, _REWARD_MANAGER_ROLE);
    }

    function testShouldGetInitialBalanceZero() public {
        assertEq(_rewardManager.balanceOf(), 0, "Initial balance should be zero");
    }

    function testShouldBalanceZeroWhenTransferUnderlineTokenToRewardManager() public {
        // given
        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardManager), 1_000e18);

        uint256 rewardElectionBalanceBefore = ERC20(_underlyingToken).balanceOf(address(_rewardManager));

        // when
        uint256 vestedBalance = _rewardManager.balanceOf();

        // then

        assertEq(rewardElectionBalanceBefore, 1_000e18, "Reward Manager balance should be 1_0000e18");
        assertEq(vestedBalance, 0, "Vested balance should be zero");
    }

    function testShouldIncreaseVestingBalanceAfterUpdateBalance() public {
        // given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardManager), 1_000e18);

        uint256 vestedBalanceBefore = _rewardManager.balanceOf();

        // when
        vm.prank(_userOne);
        _rewardManager.updateBalance();
        vm.warp(block.number + 12 hours);

        // then
        uint256 vestedBalanceAfter = _rewardManager.balanceOf();

        assertEq(vestedBalanceBefore, 0, "Vested balance before should be zero");
        assertGt(
            vestedBalanceAfter,
            vestedBalanceBefore,
            "Vested balance after should be greater than vested balance before"
        );
    }

    function testShouldVestedAllTokensOnAddress() external {
        // given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardManager), 1_000e18);

        uint256 vestedBalanceBefore = _rewardManager.balanceOf();

        // when
        vm.prank(_userOne);
        _rewardManager.updateBalance();
        vm.warp(block.number + 2 days);

        // then
        uint256 vestedBalanceAfter = _rewardManager.balanceOf();

        assertEq(vestedBalanceBefore, 0, "Vested balance before should be zero");
        assertEq(vestedBalanceAfter, 1_000e18, "Vested balance after should be 1_000e18");
    }

    function testShouldRevertWhenUserDontHaveRoleToCallUpdateBalance() public {
        // given
        vm.prank(_userTwo);
        ERC20(_underlyingToken).transfer(address(_rewardManager), 1_000e18);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);
        // when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardManager.updateBalance();
    }

    function testShouldBeAbleTransferRewardsToken() external {
        //given
        vm.prank(_atomist);
        ERC20(_rewardsToken).transfer(address(_rewardManager), 1_000e18);

        uint256 userTwoBalanceBefore = ERC20(_rewardsToken).balanceOf(_userTwo);

        //when
        vm.prank(_userOne);
        _rewardManager.transfer(_rewardsToken, _userTwo, 1_000e18);

        //then
        uint256 userTwoBalanceAfter = ERC20(_rewardsToken).balanceOf(_userTwo);

        assertEq(userTwoBalanceBefore, 0, "User two balance before should be zero");
        assertEq(userTwoBalanceAfter, 1_000e18, "User two balance after should be 1_000e18");
    }

    function testShouldRevertTransferRewardsTokenWhenDontHaveRole() external {
        //given
        vm.prank(_atomist);
        ERC20(_rewardsToken).transfer(address(_rewardManager), 1_000e18);

        uint256 userTwoBalanceBefore = ERC20(_rewardsToken).balanceOf(_userTwo);
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardManager.transfer(_rewardsToken, _userTwo, 1_000e18);

        //then
        uint256 userTwoBalanceAfter = ERC20(_rewardsToken).balanceOf(_userTwo);

        assertEq(userTwoBalanceBefore, 0, "User two balance before should be zero");
        assertEq(userTwoBalanceAfter, 0, "User two balance after should be 1_000e18");
    }

    function testShouldBeAbleToaddRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        bool isSupportedBefore = _rewardManager.isRewardFuseSupported(address(0x4444));

        //when
        vm.prank(_userOne);
        _rewardManager.addRewardFuses(fuses);

        //then
        bool isSupportedAfter = _rewardManager.isRewardFuseSupported(address(0x4444));

        assertEq(isSupportedBefore, false, "Fuse should not be supported before");
        assertEq(isSupportedAfter, true, "Fuse should be supported after");
    }

    function testShouldRevertWhenUserDontHaveRoleToaddRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        bool isSupportedBefore = _rewardManager.isRewardFuseSupported(address(0x4444));
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardManager.addRewardFuses(fuses);

        //then
        bool isSupportedAfter = _rewardManager.isRewardFuseSupported(address(0x4444));

        assertEq(isSupportedBefore, false, "Fuse should not be supported before");
        assertEq(isSupportedAfter, false, "Fuse should not be supported after");
    }

    function testShouldBeAbleToremoveRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        vm.prank(_userOne);
        _rewardManager.addRewardFuses(fuses);

        bool isSupportedBefore = _rewardManager.isRewardFuseSupported(address(0x4444));

        //when
        vm.prank(_userOne);
        _rewardManager.removeRewardFuses(fuses);

        //then
        bool isSupportedAfter = _rewardManager.isRewardFuseSupported(address(0x4444));

        assertEq(isSupportedBefore, true, "Fuse should be supported before");
        assertEq(isSupportedAfter, false, "Fuse should not be supported after");
    }

    function testShouldRevertWhenUserDontHaveRoleToremoveRewardFuses() external {
        //given
        address[] memory fuses = new address[](1);
        fuses[0] = address(0x4444);

        vm.prank(_userOne);
        _rewardManager.addRewardFuses(fuses);

        bool isSupportedBefore = _rewardManager.isRewardFuseSupported(address(0x4444));
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardManager.removeRewardFuses(fuses);

        //then
        bool isSupportedAfter = _rewardManager.isRewardFuseSupported(address(0x4444));

        assertEq(isSupportedBefore, true, "Fuse should be supported before");
        assertEq(isSupportedAfter, true, "Fuse should be supported after");
    }

    function testShouldRevertWhenUserDonHaveRoleTosSetupVesting() external {
        //given
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardManager.setupVestingTime(1 days);
    }

    function testShouldTransferVestedTokens() external {
        //given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardManager), 1_000e18);

        vm.prank(_userOne);
        _rewardManager.updateBalance();
        vm.warp(block.number + 2 days);

        uint256 vestedBalanceBefore = _rewardManager.balanceOf();

        //when
        vm.prank(_userOne);
        _rewardManager.transferVestedTokensToVault();

        //then
        uint256 vestedBalanceAfter = _rewardManager.balanceOf();

        assertEq(vestedBalanceBefore, 1_000e18, "Vested balance before should be 1_000e18");
        assertEq(vestedBalanceAfter, 0, "Vested balance after should be zero");
    }

    function testShouldRevertWhenUserDontHaveRoleToTransferVestedTokens() external {
        //given
        vm.warp(1000 days);
        vm.prank(_userOne);
        _rewardManager.setupVestingTime(1 days);

        vm.prank(_userOne);
        ERC20(_underlyingToken).transfer(address(_rewardManager), 1_000e18);

        vm.prank(_userOne);
        _rewardManager.updateBalance();
        vm.warp(block.number + 2 days);

        uint256 vestedBalanceBefore = _rewardManager.balanceOf();
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _userTwo);

        //when
        vm.prank(_userTwo);
        vm.expectRevert(error);
        _rewardManager.transferVestedTokensToVault();

        //then
        uint256 vestedBalanceAfter = _rewardManager.balanceOf();

        assertEq(vestedBalanceBefore, 1_000e18, "Vested balance before should be 1_000e18");
        assertEq(vestedBalanceAfter, 1_000e18, "Vested balance after should be 1_000e18");
    }
}
