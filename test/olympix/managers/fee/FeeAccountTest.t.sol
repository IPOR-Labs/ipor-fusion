// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {FeeAccount} from "../../../../contracts/managers/fee/FeeAccount.sol";

import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract FeeAccountTest is OlympixUnitTest("FeeAccount") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_approveMaxForFeeManager_RevertsWhenCallerNotFeeManager() public {
            address feeManager = address(0xFEE1);
            FeeAccount feeAccount = new FeeAccount(feeManager);
            MockERC20 token = new MockERC20("Mock", "MCK", 18);
    
            // deal some tokens to FeeAccount so approve makes sense
            token.mint(address(feeAccount), 100 ether);
    
            // expect revert when non-fee-manager calls
            vm.expectRevert(FeeAccount.OnlyFeeManagerCanApprove.selector);
            feeAccount.approveMaxForFeeManager(address(token));
        }
}