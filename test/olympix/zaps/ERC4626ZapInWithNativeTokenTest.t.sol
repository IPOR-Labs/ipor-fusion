// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {ERC4626ZapInWithNativeToken} from "../../../contracts/zaps/ERC4626ZapInWithNativeToken.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
contract ERC4626ZapInWithNativeTokenTest is OlympixUnitTest("ERC4626ZapInWithNativeToken") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_setReferralContractAddress_RevertWhenZeroAddress() public {
            ERC4626ZapInWithNativeToken zap = new ERC4626ZapInWithNativeToken();
    
            vm.expectRevert(ERC4626ZapInWithNativeToken.ReferralContractAddressIsZero.selector);
            zap.setReferralContractAddress(address(0));
        }

    function test_setReferralContractAddress_SetsAndRenouncesOwnership() public {
            ERC4626ZapInWithNativeToken zap = new ERC4626ZapInWithNativeToken();
    
            address referral = address(0x1234);
            zap.setReferralContractAddress(referral);
    
            // ownership should be renounced
            assertEq(zap.owner(), address(0));
            // referralContractAddress should be set
            assertEq(zap.referralContractAddress(), referral);
        }
}