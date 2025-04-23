// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {LiquityBalanceFuse} from "../../../contracts/fuses/liquity/LiquityBalanceFuse.sol";

contract LiquityBalanceFuseTest is Test {
    LiquityBalanceFuse public liquityBalanceFuse;

    function setUp() external {
        liquityBalanceFuse = new LiquityBalanceFuse(1);
    }

    function testLiquityBalanceShouldReturnZero() external view {
        uint256 balance = liquityBalanceFuse.balanceOf();

        bytes32 res = keccak256(abi.encode(uint256(keccak256("io.ipor.LiquityV2TroveIds")) - 1)) &
            ~bytes32(uint256(0xff));

        console.logBytes32(res);

        assertEq(balance, 0, "Expected balance to be zero");
    }
}
