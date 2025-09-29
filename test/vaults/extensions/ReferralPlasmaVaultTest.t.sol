// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReferralPlasmaVault} from "../../../contracts/vaults/extensions/ReferralPlasmaVault.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract ReferralPlasmaVaultTest is Test {
    // Define the event to match the one in ReferralPlasmaVault
    event ReferralEvent(address indexed referrer, bytes32 referralCode);

    ReferralPlasmaVault public referralPlasmaVault;
    address public usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    PlasmaVault public plasmaVault = PlasmaVault(0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2);

    address public user;
    address public otherUser;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22630515);

        user = makeAddr("user");
        otherUser = makeAddr("otherUser");
        deal(usdc, user, 100_000_000e6);

        referralPlasmaVault = new ReferralPlasmaVault();
    }

    function testShouldDepositWithReferralUser() public {
        // given
        uint256 depositAmount = 1000e6; // 1000 USDC
        bytes32 referralCode = keccak256(abi.encodePacked("TEST_REFERRAL"));

        vm.startPrank(user);

        IERC20(usdc).approve(address(referralPlasmaVault), depositAmount);

        uint256 initialShares = IERC4626(address(plasmaVault)).balanceOf(user);

        // Expect referral event
        vm.expectEmit(true, true, true, true);
        emit ReferralEvent(user, referralCode);

        // when
        uint256 sharesReceived = referralPlasmaVault.deposit(address(plasmaVault), depositAmount, user, referralCode);

        // then
        uint256 finalShares = IERC4626(address(plasmaVault)).balanceOf(user);

        assertEq(finalShares - initialShares, sharesReceived, "Incorrect shares received by user");
        assertGt(sharesReceived, 0, "No shares received by user");

        vm.stopPrank();
    }

    function testShouldMintSharesToOtherUser() public {
        // given
        uint256 depositAmount = 2000e6;
        bytes32 referralCode = keccak256(abi.encodePacked("OTHER_USER_REFERRAL"));

        uint256 initialOtherUserShares = IERC4626(address(plasmaVault)).balanceOf(otherUser);
        uint256 initialUserShares = IERC4626(address(plasmaVault)).balanceOf(user);

        vm.startPrank(user);

        IERC20(usdc).approve(address(referralPlasmaVault), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit ReferralEvent(user, referralCode);

        // when
        uint256 sharesReceived = referralPlasmaVault.deposit(
            address(plasmaVault),
            depositAmount,
            otherUser,
            referralCode
        );

        // then
        uint256 finalOtherUserShares = IERC4626(address(plasmaVault)).balanceOf(otherUser);
        uint256 finalUserShares = IERC4626(address(plasmaVault)).balanceOf(user);

        assertEq(
            finalOtherUserShares - initialOtherUserShares,
            sharesReceived,
            "Incorrect shares received by otherUser"
        );
        assertGt(sharesReceived, 0, "No shares received by otherUser");
        assertEq(finalUserShares, initialUserShares, "User should not have received any additional shares");
        assertEq(
            finalOtherUserShares,
            initialOtherUserShares + sharesReceived,
            "OtherUser should have received all shares"
        );

        vm.stopPrank();
    }

    // Tests for setZapInAddress function

    function testShouldSetZapInAddressSuccessfully() public {
        // given
        address owner = referralPlasmaVault.owner();
        address zapInContract = makeAddr("ZapInContract");

        // when
        vm.startPrank(owner);
        referralPlasmaVault.setZapInAddress(zapInContract);
        vm.stopPrank();

        // then
        assertEq(referralPlasmaVault.zapInAddress(), zapInContract, "ZapIn address should be set");
        assertEq(referralPlasmaVault.owner(), address(0), "Ownership should be renounced");
    }

    function testShouldRevertWhenSettingZapInAddressAsZero() public {
        // given
        address owner = referralPlasmaVault.owner();
        address zeroAddress = address(0);

        bytes memory error = abi.encodeWithSignature("ZapInAddressIsZero()");

        // when / then
        vm.startPrank(owner);
        vm.expectRevert(error);
        referralPlasmaVault.setZapInAddress(zeroAddress);
        vm.stopPrank();
    }

    function testShouldRevertWhenNonOwnerTriesToSetZapInAddress() public {
        // given
        address nonOwner = makeAddr("NonOwner");
        address zapInContract = makeAddr("ZapInContract");

        // when / then
        vm.startPrank(nonOwner);
        vm.expectRevert();
        referralPlasmaVault.setZapInAddress(zapInContract);
        vm.stopPrank();
    }

    function testShouldRevertWhenTryingToSetZapInAddressAfterOwnershipRenounced() public {
        // given
        address owner = referralPlasmaVault.owner();
        address zapInContract1 = makeAddr("ZapInContract1");
        address zapInContract2 = makeAddr("ZapInContract2");

        // First set zapIn address (this renounces ownership)
        vm.startPrank(owner);
        referralPlasmaVault.setZapInAddress(zapInContract1);
        vm.stopPrank();

        // when / then - try to set again (should fail as ownership is renounced)
        vm.startPrank(owner);
        vm.expectRevert();
        referralPlasmaVault.setZapInAddress(zapInContract2);
        vm.stopPrank();
    }

    function testShouldAllowZapInToCallEmitReferalForZapInAfterSetting() public {
        // given
        address owner = referralPlasmaVault.owner();
        address zapInContract = makeAddr("ZapInContract");
        address referrer = makeAddr("Referrer");
        bytes32 referralCode = keccak256("TEST_REFERRAL");

        // Set zapIn address first
        vm.startPrank(owner);
        referralPlasmaVault.setZapInAddress(zapInContract);
        vm.stopPrank();

        // when
        vm.startPrank(zapInContract);
        vm.expectEmit(true, true, true, true);
        emit ReferralEvent(referrer, referralCode);
        referralPlasmaVault.emitReferralForZapIn(referrer, referralCode);
        vm.stopPrank();

        // then - test passes if no revert occurs and event is emitted
    }

    function testShouldRevertWhenNonZapInTriesToCallEmitReferalForZapIn() public {
        // given
        address owner = referralPlasmaVault.owner();
        address zapInContract = makeAddr("ZapInContract");
        address nonZapIn = makeAddr("NonZapIn");
        address referrer = makeAddr("Referrer");
        bytes32 referralCode = keccak256("TEST_REFERRAL");

        // Set zapIn address first
        vm.startPrank(owner);
        referralPlasmaVault.setZapInAddress(zapInContract);
        vm.stopPrank();

        bytes memory error = abi.encodeWithSignature("NotZapIn()");

        // when / then
        vm.startPrank(nonZapIn);
        vm.expectRevert(error);
        referralPlasmaVault.emitReferralForZapIn(referrer, referralCode);
        vm.stopPrank();
    }

    function testShouldRevertWhenCallingEmitReferalForZapInBeforeZapInAddressIsSet() public {
        // given
        address nonZapIn = makeAddr("NonZapIn");
        address referrer = makeAddr("Referrer");
        bytes32 referralCode = keccak256("TEST_REFERRAL");

        bytes memory error = abi.encodeWithSignature("NotZapIn()");

        // when / then - zapInAddress is still address(0)
        vm.startPrank(nonZapIn);
        vm.expectRevert(error);
        referralPlasmaVault.emitReferralForZapIn(referrer, referralCode);
        vm.stopPrank();
    }

    function testShouldMaintainZapInAddressAfterOwnershipRenounced() public {
        // given
        address owner = referralPlasmaVault.owner();
        address zapInContract = makeAddr("ZapInContract");

        // when
        vm.startPrank(owner);
        referralPlasmaVault.setZapInAddress(zapInContract);
        vm.stopPrank();

        // then
        assertEq(referralPlasmaVault.zapInAddress(), zapInContract, "ZapIn address should remain set");
        assertEq(referralPlasmaVault.owner(), address(0), "Ownership should be renounced");

        // Verify that the zapIn can still call functions
        address referrer = makeAddr("Referrer");
        bytes32 referralCode = keccak256("TEST_REFERRAL");

        vm.startPrank(zapInContract);
        vm.expectEmit(true, true, true, true);
        emit ReferralEvent(referrer, referralCode);
        referralPlasmaVault.emitReferralForZapIn(referrer, referralCode);
        vm.stopPrank();
    }
}
