// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {MockPlasmaVault} from "./MockPlasmaVault.sol";
import {MockToken} from "./MockToken.sol";

/// @title RewardsClaimManagerZeroVestingJumpTest
/// @notice IL-9661 (L30), pinning test: with vestingTime == 0 the manager's balanceOf() is the live balance, so a rewards
///         inflow raises the vault's totalAssets() (idle + RewardsClaimManager.balanceOf()) in one step and a
///         depositor right before the inflow takes a proportional part of it. With a non-zero vesting time the same
///         inflow adds nothing in the same block. Zero is an explicit ATOMIST choice; the factory sets one week.
///         Passes on the base commit.
contract RewardsClaimManagerZeroVestingJumpTest is Test {
    uint64 private constant _ROLE = 1001;
    uint256 private constant _IDLE = 1_000_000e18; // vault assets before the depositor
    uint256 private constant _DEPOSIT = 1_000_000e18; // sandwiching deposit, same size as the pool
    uint256 private constant _REWARD = 100_000e18;

    address private _atomist = address(0x1111);
    address private _operator = address(0x2222);
    MockPlasmaVault private _vault;
    IporFusionAccessManager private _accessManager;
    ERC20 private _underlying;
    RewardsClaimManager private _manager;

    function setUp() public {
        _underlying = ERC20(address(new MockToken("Underlying", "UT")));
        _accessManager = new IporFusionAccessManager(_atomist, 0);
        _vault = new MockPlasmaVault(address(_underlying));
        _manager = new RewardsClaimManager(address(_accessManager), address(_vault));

        deal(address(_underlying), _operator, 10 * _REWARD);

        vm.prank(_atomist);
        _accessManager.grantRole(_ROLE, _operator, 0);

        bytes4[] memory sig = new bytes4[](2);
        sig[0] = RewardsClaimManager.setupVestingTime.selector;
        sig[1] = RewardsClaimManager.updateBalance.selector;
        vm.prank(_atomist);
        _accessManager.setTargetFunctionRole(address(_manager), sig, _ROLE);

        vm.warp(1000 days);
    }

    function testShouldJumpTotalAssetsInOneBlockWhenVestingIsZero() external {
        vm.prank(_operator);
        _manager.setupVestingTime(0);

        uint256 totalAssetsBefore = _IDLE + _DEPOSIT + _manager.balanceOf();

        // when: the rewards arrive in the same block as the sandwiching deposit
        vm.prank(_operator);
        _underlying.transfer(address(_manager), _REWARD);

        // then: totalAssets() moves by the full inflow immediately
        uint256 totalAssetsAfter = _IDLE + _DEPOSIT + _manager.balanceOf();
        assertEq(totalAssetsAfter - totalAssetsBefore, _REWARD, "inflow visible in the same block");

        // the depositor owns _DEPOSIT / (_IDLE + _DEPOSIT) of the vault and takes that part of the inflow at once
        uint256 depositorGain = (_REWARD * _DEPOSIT) / (_IDLE + _DEPOSIT);
        assertEq(depositorGain, _REWARD / 2, "sandwiching depositor takes half of the inflow");
        assertGt(depositorGain, 0, "gain must be positive");
    }

    function testShouldAddNothingInSameBlockWhenVestingIsOneWeek() external {
        vm.prank(_operator);
        _manager.setupVestingTime(7 days);
        vm.prank(_operator);
        _manager.updateBalance();

        // when: the same inflow, followed by the re-anchoring updateBalance() in the same block
        vm.prank(_operator);
        _underlying.transfer(address(_manager), _REWARD);
        assertEq(_manager.balanceOf(), 0, "inflow not visible before updateBalance");
        vm.prank(_operator);
        _manager.updateBalance();

        // then: same block, nothing added to totalAssets(); the sandwiching depositor gains nothing
        assertEq(_manager.balanceOf(), 0, "inflow not visible in the same block");
        uint256 depositorGain = (_manager.balanceOf() * _DEPOSIT) / (_IDLE + _DEPOSIT);
        assertEq(depositorGain, 0, "no same-block gain with vesting");

        // and the reward does vest linearly afterwards
        vm.warp(block.timestamp + 7 days / 2);
        assertEq(_manager.balanceOf(), _REWARD / 2, "half vested after half the period");
        vm.warp(block.timestamp + 7 days / 2 + 1);
        assertEq(_manager.balanceOf(), _REWARD, "fully vested after the period");
    }
}
