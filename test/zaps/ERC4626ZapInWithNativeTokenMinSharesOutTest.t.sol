// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626ZapInWithNativeToken, ZapInData, Call} from "../../contracts/zaps/ERC4626ZapInWithNativeToken.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../fuses/erc4626/IWETH9.sol";

/// @title ERC4626ZapInWithNativeTokenMinSharesOutTest
/// @notice Tests for minSharesOut slippage protection in ERC4626ZapInWithNativeToken
contract ERC4626ZapInWithNativeTokenMinSharesOutTest is Test {
    uint256 internal constant FORK_BLOCK_NUMBER = 32275361;
    PlasmaVault internal plasmaVaultWeth = PlasmaVault(0x7872893e528Fe2c0829e405960db5B742112aa97);
    address internal weth = 0x4200000000000000000000000000000000000006;

    // Expected shares for 10_000 ETH deposit at this block
    uint256 internal constant EXPECTED_SHARES = 984679_501885980912334434;

    ERC4626ZapInWithNativeToken internal zapIn;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK_NUMBER);
        zapIn = new ERC4626ZapInWithNativeToken();
    }

    /// @notice Test successful zap when shares meet minimum (without referral)
    function testShouldZapInSuccessfullyWhenSharesMeetMinimum() public {
        // given
        address user = makeAddr("User");
        uint256 ethAmount = 10_000e18;
        uint256 minSharesOut = EXPECTED_SHARES - 1e18; // Slightly less than expected
        deal(user, ethAmount);

        ZapInData memory zapInData = _createZapInData(user, ethAmount, minSharesOut);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: ethAmount}(zapInData);
        vm.stopPrank();

        // then
        uint256 userShares = plasmaVaultWeth.balanceOf(user);
        assertGe(userShares, minSharesOut, "User should have at least minSharesOut shares");
        assertEq(userShares, EXPECTED_SHARES, "User should have expected shares");
    }

    /// @notice Test successful zap with referral when shares meet minimum
    function testShouldZapInWithReferralWhenSharesMeetMinimum() public {
        // given
        address user = makeAddr("User");
        uint256 ethAmount = 10_000e18;
        uint256 minSharesOut = EXPECTED_SHARES - 1e18;
        bytes32 referralCode = keccak256("TEST_REFERRAL");
        deal(user, ethAmount);

        ZapInData memory zapInData = _createZapInData(user, ethAmount, minSharesOut);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: ethAmount}(zapInData, referralCode);
        vm.stopPrank();

        // then
        uint256 userShares = plasmaVaultWeth.balanceOf(user);
        assertGe(userShares, minSharesOut, "User should have at least minSharesOut shares");
    }

    /// @notice Test revert when shares below minimum
    function testShouldRevertWhenSharesBelowMinimum() public {
        // given
        address user = makeAddr("User");
        uint256 ethAmount = 10_000e18;
        uint256 impossibleMinShares = EXPECTED_SHARES + 1e18; // More than what will be minted
        deal(user, ethAmount);

        ZapInData memory zapInData = _createZapInData(user, ethAmount, impossibleMinShares);

        // when/then
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSignature(
                "InsufficientSharesOut(uint256,uint256)",
                EXPECTED_SHARES,
                impossibleMinShares
            )
        );
        zapIn.zapIn{value: ethAmount}(zapInData);
        vm.stopPrank();
    }

    /// @notice Test zero minSharesOut (backward compatibility)
    function testShouldAcceptZeroMinSharesOut() public {
        // given
        address user = makeAddr("User");
        uint256 ethAmount = 10_000e18;
        uint256 minSharesOut = 0; // No slippage protection
        deal(user, ethAmount);

        ZapInData memory zapInData = _createZapInData(user, ethAmount, minSharesOut);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: ethAmount}(zapInData);
        vm.stopPrank();

        // then
        uint256 userShares = plasmaVaultWeth.balanceOf(user);
        assertGt(userShares, 0, "User should have shares");
        assertEq(userShares, EXPECTED_SHARES, "User should have expected shares");
    }

    /// @notice Test with native token refund
    function testShouldHandleNativeTokenRefundWithMinSharesOut() public {
        // given
        address user = makeAddr("User");
        uint256 ethAmount = 10_000e18;
        uint256 extraEth = 1e18; // Extra ETH to be refunded
        uint256 minSharesOut = EXPECTED_SHARES - 1e18;
        deal(user, ethAmount + extraEth);

        ZapInData memory zapInData = _createZapInData(user, ethAmount, minSharesOut);

        uint256 userBalanceBefore = user.balance;

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: ethAmount + extraEth}(zapInData);
        vm.stopPrank();

        // then
        uint256 userShares = plasmaVaultWeth.balanceOf(user);
        assertGe(userShares, minSharesOut, "User should have at least minSharesOut shares");
        assertEq(user.balance, extraEth, "Extra ETH should be refunded");
    }

    /// @notice Test revert does not transfer assets
    function testShouldNotTransferAssetsWhenSharesBelowMinimum() public {
        // given
        address user = makeAddr("User");
        uint256 ethAmount = 10_000e18;
        uint256 impossibleMinShares = EXPECTED_SHARES + 1e18;
        deal(user, ethAmount);

        ZapInData memory zapInData = _createZapInData(user, ethAmount, impossibleMinShares);

        uint256 userBalanceBefore = user.balance;
        uint256 userSharesBefore = plasmaVaultWeth.balanceOf(user);

        // when/then - transaction reverts
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSignature(
                "InsufficientSharesOut(uint256,uint256)",
                EXPECTED_SHARES,
                impossibleMinShares
            )
        );
        zapIn.zapIn{value: ethAmount}(zapInData);
        vm.stopPrank();

        // State should remain unchanged due to revert
        assertEq(plasmaVaultWeth.balanceOf(user), userSharesBefore, "User shares should remain unchanged");
    }

    /// @notice Helper function to create ZapInData with proper calls
    function _createZapInData(
        address user,
        uint256 ethAmount,
        uint256 minSharesOut
    ) internal view returns (ZapInData memory) {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: weth,
            data: abi.encodeWithSelector(IWETH9.deposit.selector),
            nativeTokenAmount: ethAmount
        });
        calls[1] = Call({
            target: weth,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultWeth), ethAmount),
            nativeTokenAmount: 0
        });

        return ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: user,
            minAmountToDeposit: ethAmount,
            minSharesOut: minSharesOut,
            assetsToRefundToSender: new address[](0),
            calls: calls
        });
    }
}
