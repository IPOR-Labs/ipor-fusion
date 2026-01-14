// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626ZapInWithNativeToken, ZapInData, Call} from "../../contracts/zaps/ERC4626ZapInWithNativeToken.sol";
import {ERC4626ZapInAllowance} from "../../contracts/zaps/ERC4626ZapInAllowance.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {ReferralPlasmaVault} from "../../contracts/vaults/extensions/ReferralPlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

interface CreditEnforcer {
    function mintStablecoin(uint256 amount) external returns (uint256);
}

contract UsdcToRUsdcZapWithNativeTokenTest is Test {
    uint256 internal constant FORK_BLOCK_NUMBER = 21729380;
    PlasmaVault internal plasmaVaultRUsdc = PlasmaVault(0x2D71CC054AA096a1b3739D67303f88C75b1D59dC);
    address internal usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal rUsd = 0x09D4214C03D01F49544C0448DBE3A27f768F2b34;
    address internal dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address internal creditEnforcer = 0x04716DB62C085D9e08050fcF6F7D775A03d07720;
    address internal pegStabilityModule = 0x4809010926aec940b550D34a46A52739f996D75D;

    ERC4626ZapInWithNativeToken internal zapIn;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK_NUMBER);

        zapIn = new ERC4626ZapInWithNativeToken();
    }

    function testShouldDepositRusdWithZapFromUsdc() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: 0}(zapInData);
        vm.stopPrank();

        // then

        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultRUsdc.balanceOf(user);

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            minAmountToDeposit * 100,
            "User should have 10_000e18 rUsd in the plasma vault"
        );
    }

    function testShouldRevertWhenMinAmountToDepositIsZero() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 0; // Setting to 0 to trigger the revert
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: minAmountToDeposit,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        bytes memory error = abi.encodeWithSignature("MinAmountToDepositIsZero()");

        // when / then
        vm.expectRevert(error);
        zapIn.zapIn{value: 0}(zapInData);
        vm.stopPrank();
    }

    function testShouldRevertWhenPlasmaVaultIsZero() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(0),
            receiver: user,
            minAmountToDeposit: minAmountToDeposit,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(0), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        bytes memory error = abi.encodeWithSignature("ERC4626VaultIsZero()");

        // when / then
        vm.expectRevert(error);
        zapIn.zapIn{value: 0}(zapInData);
        vm.stopPrank();
    }

    function testShouldRevertWhenReceiverIsZero() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: address(0),
            minAmountToDeposit: minAmountToDeposit,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        bytes memory error = abi.encodeWithSignature("ReceiverIsZero()");

        // when / then
        vm.expectRevert(error);
        zapIn.zapIn{value: 0}(zapInData);
        vm.stopPrank();
    }

    function testShouldRevertWhenCallsIsEmpty() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: minAmountToDeposit,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        bytes memory error = abi.encodeWithSignature("NoCalls()");

        // when / then
        vm.expectRevert(error);
        zapIn.zapIn{value: 0}(zapInData);
        vm.stopPrank();
    }

    /// @notice L13 fix: Pre-existing tokens are NOT refunded to prevent exfiltration attacks
    /// @dev This test verifies that pre-existing DAI in the zap contract is protected from exfiltration
    function testShouldRefundDaiAfterZap() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 daiAmount = 1e18;

        deal(usdc, user, usdcAmount);
        // Pre-existing DAI in zap (e.g., from accidental transfer or previous operation)
        deal(dai, address(zapIn), daiAmount);

        address[] memory assetsToRefund = new address[](1);
        assetsToRefund[0] = dai;

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: 0,
            assetsToRefundToSender: assetsToRefund,
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);
        uint256 userDaiBalanceBefore = IERC20(dai).balanceOf(user);
        uint256 zapInDaiBalanceBefore = IERC20(dai).balanceOf(address(zapIn));

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: 0}(zapInData);
        vm.stopPrank();

        // then
        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultRUsdc.balanceOf(user);
        uint256 userDaiBalanceAfter = IERC20(dai).balanceOf(user);
        uint256 zapInDaiBalanceAfter = IERC20(dai).balanceOf(address(zapIn));

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            minAmountToDeposit * 100,
            "User should have 10_000e18 rUsd in the plasma vault"
        );

        // L13: Pre-existing DAI is NOT refunded (protected from exfiltration)
        assertEq(userDaiBalanceBefore, 0, "User should not have any DAI before the zap");
        assertEq(userDaiBalanceAfter, 0, "User should NOT receive pre-existing DAI (L13 protection)");
        assertEq(zapInDaiBalanceAfter, daiAmount, "Pre-existing DAI should remain in ZapIn contract");
        assertEq(zapInDaiBalanceBefore, daiAmount, "ZapIn contract should have 1e18 DAI before the zap");
    }

    function testShouldDepositRusdWithZapFromUsdcWithPermit() public {
        // given
        uint256 privateKey = 1542361753286182361812;
        address user = vm.addr(privateKey);
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        bytes32 domainSeparator = 0x06c37168a7db5138defc7866392bb87a741f9b3d104deb5094588ce041cae335;
        uint256 nonce = Nonces(usdc).nonces(user);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(zapIn),
                usdcAmount,
                nonce,
                block.timestamp + 10
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        Call[] memory calls = new Call[](5);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(
                IERC20Permit.permit.selector,
                user,
                address(zapIn),
                usdcAmount,
                block.timestamp + 10,
                v,
                r,
                s
            ),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.transferFrom.selector, user, address(zapIn), usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[4] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: 0}(zapInData);
        vm.stopPrank();

        // then

        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultRUsdc.balanceOf(user);

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            minAmountToDeposit * 100,
            "User should have 10_000e18 rUsd in the plasma vault"
        );
    }

    /// @notice L13 fix: Pre-existing native ETH is NOT refunded to prevent exfiltration attacks
    /// @dev This test verifies that pre-existing ETH in the zap contract is protected from exfiltration
    function testShouldRefundNativeTokenAfterZap() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 nativeTokenAmount = 1 ether;

        deal(usdc, user, usdcAmount);
        // Pre-existing ETH in zap (e.g., from accidental transfer or previous operation)
        deal(address(zapIn), nativeTokenAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);
        uint256 userNativeTokenBalanceBefore = user.balance;
        uint256 zapInNativeTokenBalanceBefore = address(zapIn).balance;

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: 0}(zapInData);
        vm.stopPrank();

        // then
        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultRUsdc.balanceOf(user);
        uint256 userNativeTokenBalanceAfter = user.balance;
        uint256 zapInNativeTokenBalanceAfter = address(zapIn).balance;

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            minAmountToDeposit * 100,
            "User should have 10_000e18 rUsd in the plasma vault"
        );

        // L13: Pre-existing ETH is NOT refunded (protected from exfiltration)
        assertEq(userNativeTokenBalanceBefore, 0, "User should not have any native tokens before the zap");
        assertEq(userNativeTokenBalanceAfter, 0, "User should NOT receive pre-existing ETH (L13 protection)");
        assertEq(zapInNativeTokenBalanceAfter, nativeTokenAmount, "Pre-existing ETH should remain in ZapIn contract");
        assertEq(zapInNativeTokenBalanceBefore, nativeTokenAmount, "ZapIn contract should have 1 ether before the zap");
    }

    function testShouldHandleCallsWithNativeTokenAmount() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 nativeTokenAmount = 0.1 ether;

        deal(usdc, user, usdcAmount);
        deal(user, nativeTokenAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: nativeTokenAmount}(zapInData);
        vm.stopPrank();

        // then
        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultRUsdc.balanceOf(user);

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            minAmountToDeposit * 100,
            "User should have 10_000e18 rUsd in the plasma vault"
        );
    }

    // Tests for setReferralContractAddress function

    function testShouldSetReferralContractAddressSuccessfully() public {
        // given
        address owner = zapIn.owner();
        address referralContract = makeAddr("ReferralContract");

        // when
        vm.startPrank(owner);
        zapIn.setReferralContractAddress(referralContract);
        vm.stopPrank();

        // then
        assertEq(zapIn.referralContractAddress(), referralContract, "Referral contract address should be set");
        assertEq(zapIn.owner(), address(0), "Ownership should be renounced");
    }

    function testShouldRevertWhenSettingReferralContractAddressAsZero() public {
        // given
        address owner = zapIn.owner();
        address zeroAddress = address(0);

        bytes memory error = abi.encodeWithSignature("ReferralContractAddressIsZero()");

        // when / then
        vm.startPrank(owner);
        vm.expectRevert(error);
        zapIn.setReferralContractAddress(zeroAddress);
        vm.stopPrank();
    }

    function testShouldRevertWhenNonOwnerTriesToSetReferralContractAddress() public {
        // given
        address nonOwner = makeAddr("NonOwner");
        address referralContract = makeAddr("ReferralContract");

        // when / then
        vm.startPrank(nonOwner);
        vm.expectRevert();
        zapIn.setReferralContractAddress(referralContract);
        vm.stopPrank();
    }

    function testShouldRevertWhenTryingToSetReferralContractAddressAfterOwnershipRenounced() public {
        // given
        address owner = zapIn.owner();
        address referralContract1 = makeAddr("ReferralContract1");
        address referralContract2 = makeAddr("ReferralContract2");

        // First set referral contract (this renounces ownership)
        vm.startPrank(owner);
        zapIn.setReferralContractAddress(referralContract1);
        vm.stopPrank();

        // when / then - try to set again (should fail as ownership is renounced)
        vm.startPrank(owner);
        vm.expectRevert();
        zapIn.setReferralContractAddress(referralContract2);
        vm.stopPrank();
    }

    function testShouldNotCallReferralContractWhenReferralCodeIsZero() public {
        // given
        address owner = zapIn.owner();
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        bytes32 zeroReferralCode = bytes32(0);
        address referralContract = makeAddr("ReferralContract");

        deal(usdc, user, usdcAmount);

        // Set referral contract first
        vm.startPrank(owner);
        zapIn.setReferralContractAddress(referralContract);
        vm.stopPrank();

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        // when
        vm.startPrank(user);
        zapIn.zapIn(zapInData, zeroReferralCode);
        vm.stopPrank();

        // then - verify the zap still works even with zero referral code
        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultRUsdc.balanceOf(user);
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            minAmountToDeposit * 100,
            "User should have 10_000e18 rUsd in the plasma vault"
        );
    }

    function testShouldEmitReferralEventWhenZapInWithReferralCode() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        bytes32 referralCode = keccak256("TEST_REFERRAL_123");

        // Deploy ReferralPlasmaVault
        ReferralPlasmaVault referralPlasmaVault = new ReferralPlasmaVault();

        // Set the zapIn address in ReferralPlasmaVault
        address referralOwner = referralPlasmaVault.owner();
        vm.startPrank(referralOwner);
        referralPlasmaVault.setZapInAddress(address(zapIn));
        vm.stopPrank();

        // Set the referral contract address in zapIn
        address zapInOwner = zapIn.owner();
        vm.startPrank(zapInOwner);
        zapIn.setReferralContractAddress(address(referralPlasmaVault));
        vm.stopPrank();

        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);

        // when - expect referral event to be emitted
        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit ReferralPlasmaVault.ReferralEvent(user, referralCode);
        zapIn.zapIn(zapInData, referralCode);
        vm.stopPrank();

        // then
        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultRUsdc.balanceOf(user);

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            minAmountToDeposit * 100,
            "User should have 10_000e18 rUsd in the plasma vault"
        );

        // Verify that both contracts have been properly configured
        assertEq(
            referralPlasmaVault.zapInAddress(),
            address(zapIn),
            "ReferralPlasmaVault should have zapIn address set"
        );
        assertEq(
            zapIn.referralContractAddress(),
            address(referralPlasmaVault),
            "ZapIn should have referral contract address set"
        );
    }

    function testShouldNotEmitReferralEventWhenReferralCodeIsZero() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        bytes32 zeroReferralCode = bytes32(0);

        // Deploy ReferralPlasmaVault
        ReferralPlasmaVault referralPlasmaVault = new ReferralPlasmaVault();

        // Set the zapIn address in ReferralPlasmaVault
        address referralOwner = referralPlasmaVault.owner();
        vm.startPrank(referralOwner);
        referralPlasmaVault.setZapInAddress(address(zapIn));
        vm.stopPrank();

        // Set the referral contract address in zapIn
        address zapInOwner = zapIn.owner();
        vm.startPrank(zapInOwner);
        zapIn.setReferralContractAddress(address(referralPlasmaVault));
        vm.stopPrank();

        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount),
            nativeTokenAmount: 0
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);

        // when - do NOT expect referral event to be emitted (zero referral code)
        vm.startPrank(user);
        zapIn.zapIn(zapInData, zeroReferralCode);
        vm.stopPrank();

        // then
        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultRUsdc.balanceOf(user);

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            minAmountToDeposit * 100,
            "User should have 10_000e18 rUsd in the plasma vault"
        );
    }
}
