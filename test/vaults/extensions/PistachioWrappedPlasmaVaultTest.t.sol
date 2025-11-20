// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WrappedPlasmaVault} from "../../../contracts/vaults/extensions/WrappedPlasmaVault.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PistachioWrappedPlasmaVaultTest is Test {
    address public user;
    address public owner;

    PlasmaVault public plasmaVault = PlasmaVault(0x7872893e528Fe2c0829e405960db5B742112aa97);
    WrappedPlasmaVault public wPlasmaVault = WrappedPlasmaVault(0x2219F21327474d49D4C9D5BcD8071e720B93df4b);

    address public wETH = 0x4200000000000000000000000000000000000006;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 35004033);
        owner = 0x6209517A9496987C2AaDd03157D1858927e303Ed;
        user = 0xfc221a00CfE2A8EA403e279071ae807C14eb96E3;
    }

    function testShouldWithdrawMaxWithdraw() public {
        // given
        uint256 maxWithdrawBefore = wPlasmaVault.maxWithdraw(user);

        // when
        vm.startPrank(user);
        wPlasmaVault.withdraw(maxWithdrawBefore, user, user);
        vm.stopPrank();

        // then
        uint256 maxWithdrawAfter = wPlasmaVault.maxWithdraw(user);

        assertEq(maxWithdrawAfter, 0, "maxWithdrawAfter should be 0");
    }

    function testShouldChangeMaxWithdrawAfterOneBlock() public {
        // given
        uint256 maxWithdrawBefore = wPlasmaVault.maxWithdraw(user);

        // when
        vm.warp(block.timestamp + 1);

        //then
        uint256 maxWithdrawAfter = wPlasmaVault.maxWithdraw(user);

        assertGt(
            maxWithdrawBefore,
            maxWithdrawAfter,
            "maxWithdrawBefore should be greater than maxWithdrawAfter, because of the fee"
        );
    }
}
