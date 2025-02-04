// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC4626ZapiIn, ZapInData, Call} from "../../contracts/zaps/ERC4626ZapiIn.sol";
import {ZapInAllowance} from "../../contracts/zaps/ZapInAllowance.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

interface CreditEnforcer {
    function mintStablecoin(uint256 amount) external returns (uint256);
}

contract UsdcToRUsdcZapTest is Test {
    uint256 internal constant FORK_BLOCK_NUMBER = 21729380;
    PlasmaVault internal plasmaVaultRUsdc = PlasmaVault(0x2D71CC054AA096a1b3739D67303f88C75b1D59dC);
    address internal usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal rUsd = 0x09D4214C03D01F49544C0448DBE3A27f768F2b34;
    address internal dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address internal creditEnforcer = 0x04716DB62C085D9e08050fcF6F7D775A03d07720;
    address internal pegStabilityModule = 0x4809010926aec940b550D34a46A52739f996D75D;

    ERC4626ZapiIn internal zapIn;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK_NUMBER);

        zapIn = new ERC4626ZapiIn();
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
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0)
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount)
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount)
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount)
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit)
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);

        // when
        vm.startPrank(user);
        zapIn.zapIn(zapInData);
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
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0)
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount)
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount)
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount)
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit)
        });

        zapInData.calls = calls;

        bytes memory error = abi.encodeWithSignature("MinAmountToDepositIsZero()");

        // when / then
        vm.expectRevert(error);
        zapIn.zapIn(zapInData);
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
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0)
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount)
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount)
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount)
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(0), minAmountToDeposit)
        });

        zapInData.calls = calls;

        bytes memory error = abi.encodeWithSignature("ERC4626VaultIsZero()");

        // when / then
        vm.expectRevert(error);
        zapIn.zapIn(zapInData);
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
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0)
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount)
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount)
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount)
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit)
        });

        zapInData.calls = calls;

        bytes memory error = abi.encodeWithSignature("ReceiverIsZero()");

        // when / then
        vm.expectRevert(error);
        zapIn.zapIn(zapInData);
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
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0)
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        bytes memory error = abi.encodeWithSignature("NoCalls()");

        // when / then
        vm.expectRevert(error);
        zapIn.zapIn(zapInData);
        vm.stopPrank();
    }

    function testShouldRefundDaiAfterZap() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 daiAmount = 1e18;

        deal(usdc, user, usdcAmount);
        deal(dai, address(zapIn), daiAmount);

        address[] memory assetsToRefund = new address[](1);
        assetsToRefund[0] = dai;

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            assetsToRefundToSender: assetsToRefund,
            calls: new Call[](0)
        });

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);
        vm.stopPrank();

        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount)
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount)
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount)
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit)
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);
        uint256 userDaiBalanceBefore = IERC20(dai).balanceOf(user);
        uint256 zapInDaiBalanceBefore = IERC20(dai).balanceOf(address(zapIn));

        // when
        vm.startPrank(user);
        zapIn.zapIn(zapInData);
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

        assertEq(userDaiBalanceBefore, 0, "User should not have any DAI before the zap");
        assertEq(userDaiBalanceAfter, daiAmount, "User should receive 1e18 DAI after the zap");
        assertEq(zapInDaiBalanceAfter, 0, "ZapIn contract should have no DAI after the refund");
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
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0)
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
            )
        });
        calls[1] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount)
        });
        calls[2] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.transferFrom.selector, user, address(zapIn), usdcAmount)
        });
        calls[3] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount)
        });
        calls[4] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit)
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultRUsdc.balanceOf(user);

        // when
        vm.startPrank(user);
        zapIn.zapIn(zapInData);
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
