// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626ZapInWithNativeToken, ZapInData, Call} from "../../contracts/zaps/ERC4626ZapInWithNativeToken.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../fuses/erc4626/IWETH9.sol";

/// @title Contract that cannot receive ETH (no payable receive/fallback)
/// @notice Simulates a non-payable contract integration that would fail with unconditional ETH refunds
contract NonPayableIntegration {
    ERC4626ZapInWithNativeToken public zapIn;

    constructor(address zapIn_) {
        zapIn = ERC4626ZapInWithNativeToken(payable(zapIn_));
    }

    /// @notice Calls zapIn and expects to work even though this contract cannot receive ETH
    function performZap(ZapInData calldata zapInData_) external payable {
        zapIn.zapIn{value: msg.value}(zapInData_);
    }
}

/// @title Contract that can receive ETH (has payable receive)
contract PayableIntegration {
    ERC4626ZapInWithNativeToken public zapIn;

    constructor(address zapIn_) {
        zapIn = ERC4626ZapInWithNativeToken(payable(zapIn_));
    }

    receive() external payable {}

    /// @notice Calls zapIn and can receive ETH refunds
    function performZap(ZapInData calldata zapInData_) external payable {
        zapIn.zapIn{value: msg.value}(zapInData_);
    }
}

/// @title Contract that forces ETH to the zap contract (griefing attack simulation)
contract EthGriefer {
    constructor(address target_) payable {
        selfdestruct(payable(target_));
    }
}

/// @title Comprehensive tests for native ETH refund security fix (L7)
/// @notice Tests the fix for unconditional ETH refunds that could cause DoS for non-payable contracts
contract ERC4626ZapInNativeRefundTest is Test {
    uint256 internal constant FORK_BLOCK_NUMBER = 32275361;
    PlasmaVault internal plasmaVaultWeth = PlasmaVault(0x7872893e528Fe2c0829e405960db5B742112aa97);
    address internal weth = 0x4200000000000000000000000000000000000006;

    ERC4626ZapInWithNativeToken internal zapIn;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK_NUMBER);
        zapIn = new ERC4626ZapInWithNativeToken();
    }

    // ============================================
    // L7 Security Fix Tests - Non-Payable Contract Compatibility
    // ============================================

    /// @notice TEST-L7-001: Non-payable contract can successfully zap by setting refundNativeTo to address(0)
    /// @dev This test verifies the fix for the L7 vulnerability where non-payable contracts would revert
    function testNonPayableContractCanZapWithRefundNativeToZero() public {
        // given
        NonPayableIntegration integration = new NonPayableIntegration(address(zapIn));
        uint256 ethAmount = 10_000e18;
        deal(address(integration), ethAmount);

        // Simulate leftover ETH in the zap contract (e.g., from a previous operation)
        deal(address(zapIn), 0.5 ether);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: address(integration),
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: address(0) // Skip ETH refund - critical for non-payable contracts
        });

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
        zapInData.calls = calls;

        uint256 zapBalanceBefore = address(zapIn).balance;

        // when
        vm.prank(address(integration));
        integration.performZap{value: ethAmount}(zapInData);

        // then
        uint256 vaultShares = plasmaVaultWeth.balanceOf(address(integration));
        assertGt(vaultShares, 0, "Integration should receive vault shares");

        // Leftover ETH should remain in zap contract (not refunded)
        assertEq(address(zapIn).balance, zapBalanceBefore, "Leftover ETH should remain in zap contract");
    }

    /// @notice TEST-L7-002: Payable contract can receive ETH refund by setting refundNativeTo to itself
    /// @dev L13 fix: Only ETH acquired during current operation is refunded, not pre-existing ETH
    function testPayableContractCanReceiveEthRefund() public {
        // given
        PayableIntegration integration = new PayableIntegration(address(zapIn));
        uint256 ethAmount = 10_000e18;
        uint256 leftoverEth = 0.5 ether;

        // Total ETH sent: ethAmount + leftoverEth (leftover comes from msg.value, not pre-existing)
        deal(address(integration), ethAmount + leftoverEth);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: address(integration),
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: address(integration) // Refund to self (payable contract)
        });

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
        zapInData.calls = calls;

        // when - send extra ETH that will be leftover (not used in calls)
        vm.prank(address(integration));
        integration.performZap{value: ethAmount + leftoverEth}(zapInData);

        // then
        uint256 vaultShares = plasmaVaultWeth.balanceOf(address(integration));
        assertGt(vaultShares, 0, "Integration should receive vault shares");

        // Leftover ETH from current operation should be refunded to integration contract
        assertEq(address(integration).balance, leftoverEth, "Integration should receive leftover ETH");
        assertEq(address(zapIn).balance, 0, "Zap contract should have no ETH left");
    }

    /// @notice TEST-L7-003: EOA user can specify different address for ETH refund
    /// @dev L13 fix: Only ETH acquired during current operation is refunded, not pre-existing ETH
    function testUserCanSpecifyDifferentRefundAddress() public {
        // given
        address user = makeAddr("User");
        address refundRecipient = makeAddr("RefundRecipient");
        uint256 ethAmount = 10_000e18;
        uint256 leftoverEth = 0.3 ether;

        // Total ETH sent: ethAmount + leftoverEth (leftover comes from msg.value, not pre-existing)
        deal(user, ethAmount + leftoverEth);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: user,
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: refundRecipient // Refund to different address
        });

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
        zapInData.calls = calls;

        // when - send extra ETH that will be leftover (not used in calls)
        vm.prank(user);
        zapIn.zapIn{value: ethAmount + leftoverEth}(zapInData);

        // then
        uint256 vaultShares = plasmaVaultWeth.balanceOf(user);
        assertGt(vaultShares, 0, "User should receive vault shares");

        // Leftover ETH from current operation should be refunded to specified recipient
        assertEq(refundRecipient.balance, leftoverEth, "Refund recipient should receive leftover ETH");
        assertEq(user.balance, 0, "User should not receive ETH refund");
        assertEq(address(zapIn).balance, 0, "Zap contract should have no ETH left");
    }

    /// @notice TEST-L7-004: Griefing attack via forced ETH does not cause DoS when refundNativeTo is address(0)
    function testGriefingAttackDoesNotCauseDoSWithRefundNativeToZero() public {
        // given
        NonPayableIntegration integration = new NonPayableIntegration(address(zapIn));
        uint256 ethAmount = 10_000e18;
        uint256 griefAmount = 1 ether;

        deal(address(integration), ethAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: address(integration),
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: address(0) // Skip refund - prevents griefing DoS
        });

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
        zapInData.calls = calls;

        // Simulate griefing: force-send ETH to zap contract during execution
        // In practice, this would happen via selfdestruct from another contract
        deal(address(zapIn), griefAmount);

        // when - should NOT revert despite forced ETH
        vm.prank(address(integration));
        integration.performZap{value: ethAmount}(zapInData);

        // then
        uint256 vaultShares = plasmaVaultWeth.balanceOf(address(integration));
        assertGt(vaultShares, 0, "Integration should receive vault shares despite griefing attempt");

        // Forced ETH remains in zap contract (not refunded)
        assertEq(address(zapIn).balance, griefAmount, "Forced ETH should remain in zap contract");
    }

    /// @notice TEST-L7-005: Zero leftover ETH with refundNativeTo set should not revert
    function testZeroLeftoverEthWithRefundNativeToSet() public {
        // given
        address user = makeAddr("User");
        address refundRecipient = makeAddr("RefundRecipient");
        uint256 ethAmount = 10_000e18;

        deal(user, ethAmount);
        // No leftover ETH in zap contract

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: user,
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: refundRecipient
        });

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
        zapInData.calls = calls;

        // when
        vm.prank(user);
        zapIn.zapIn{value: ethAmount}(zapInData);

        // then
        uint256 vaultShares = plasmaVaultWeth.balanceOf(user);
        assertGt(vaultShares, 0, "User should receive vault shares");

        // No refund should occur (zero balance)
        assertEq(refundRecipient.balance, 0, "No refund should occur with zero leftover ETH");
        assertEq(address(zapIn).balance, 0, "Zap contract should have no ETH");
    }

    /// @notice TEST-L7-006: Backward compatibility - EOA can still receive refunds by setting refundNativeTo to msg.sender
    /// @dev L13 fix: Only ETH acquired during current operation is refunded, not pre-existing ETH
    function testBackwardCompatibilityEOAReceivesRefund() public {
        // given
        address user = makeAddr("User");
        uint256 ethAmount = 10_000e18;
        uint256 leftoverEth = 0.2 ether;

        // Total ETH sent: ethAmount + leftoverEth (leftover comes from msg.value, not pre-existing)
        deal(user, ethAmount + leftoverEth);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: user,
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user // Explicitly set to user for backward compatibility
        });

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
        zapInData.calls = calls;

        // when - send extra ETH that will be leftover (not used in calls)
        vm.prank(user);
        zapIn.zapIn{value: ethAmount + leftoverEth}(zapInData);

        // then
        uint256 vaultShares = plasmaVaultWeth.balanceOf(user);
        assertGt(vaultShares, 0, "User should receive vault shares");

        // User should receive leftover ETH from current operation
        assertEq(user.balance, leftoverEth, "User should receive leftover ETH");
        assertEq(address(zapIn).balance, 0, "Zap contract should have no ETH left");
    }

    /// @notice TEST-L7-007: Multiple operations with different refund strategies
    /// @dev L13 fix: Pre-existing ETH is NOT refunded to prevent exfiltration attacks
    function testMultipleOperationsWithDifferentRefundStrategies() public {
        // given
        address user1 = makeAddr("User1");
        address user2 = makeAddr("User2");
        address refundRecipient = makeAddr("RefundRecipient");
        uint256 ethAmount = 5_000e18;
        uint256 leftoverEth = 0.1 ether;

        deal(user1, ethAmount);
        // User2 sends extra ETH that will be leftover
        deal(user2, ethAmount + leftoverEth);

        // Pre-existing ETH in zap (e.g., from griefing or accidental transfer)
        deal(address(zapIn), 0.1 ether);

        ZapInData memory zapInData1 = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: user1,
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: address(0) // Skip refund
        });

        Call[] memory calls1 = new Call[](2);
        calls1[0] = Call({
            target: weth,
            data: abi.encodeWithSelector(IWETH9.deposit.selector),
            nativeTokenAmount: ethAmount
        });
        calls1[1] = Call({
            target: weth,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultWeth), ethAmount),
            nativeTokenAmount: 0
        });
        zapInData1.calls = calls1;

        // when - first operation
        vm.prank(user1);
        zapIn.zapIn{value: ethAmount}(zapInData1);

        // then - first operation
        assertGt(plasmaVaultWeth.balanceOf(user1), 0, "User1 should receive vault shares");
        // L13: Pre-existing ETH remains in zap (not refunded, protected from exfiltration)
        assertEq(address(zapIn).balance, 0.1 ether, "Pre-existing ETH should remain in zap");

        // Second operation: user2 sends extra ETH and receives only their leftover back
        ZapInData memory zapInData2 = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: user2,
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: refundRecipient // Refund to different address
        });

        Call[] memory calls2 = new Call[](2);
        calls2[0] = Call({
            target: weth,
            data: abi.encodeWithSelector(IWETH9.deposit.selector),
            nativeTokenAmount: ethAmount
        });
        calls2[1] = Call({
            target: weth,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultWeth), ethAmount),
            nativeTokenAmount: 0
        });
        zapInData2.calls = calls2;

        // when - second operation with extra ETH that will be leftover
        vm.prank(user2);
        zapIn.zapIn{value: ethAmount + leftoverEth}(zapInData2);

        // then - second operation
        assertGt(plasmaVaultWeth.balanceOf(user2), 0, "User2 should receive vault shares");
        // L13: Only user2's leftover is refunded, not pre-existing ETH
        assertEq(
            refundRecipient.balance,
            leftoverEth,
            "Refund recipient should receive leftover ETH from second operation only"
        );
        // Pre-existing ETH stays in zap contract (protected from exfiltration)
        assertEq(address(zapIn).balance, 0.1 ether, "Pre-existing ETH should still remain in zap");
    }

    /// @notice TEST-L7-008: Large leftover ETH amount can be refunded successfully
    /// @dev L13 fix: Only ETH acquired during current operation is refunded, not pre-existing ETH
    function testLargeLeftoverEthRefund() public {
        // given
        address user = makeAddr("User");
        address refundRecipient = makeAddr("RefundRecipient");
        uint256 ethAmount = 10_000e18;
        uint256 largeLeftoverEth = 100 ether; // Large leftover amount

        // Total ETH sent: ethAmount + largeLeftoverEth (leftover comes from msg.value, not pre-existing)
        deal(user, ethAmount + largeLeftoverEth);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: user,
            minAmountToDeposit: ethAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: refundRecipient
        });

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
        zapInData.calls = calls;

        // when - send extra ETH that will be leftover (not used in calls)
        vm.prank(user);
        zapIn.zapIn{value: ethAmount + largeLeftoverEth}(zapInData);

        // then - large leftover from current operation should be refunded
        assertEq(refundRecipient.balance, largeLeftoverEth, "Refund recipient should receive large leftover ETH");
        assertEq(address(zapIn).balance, 0, "Zap contract should have no ETH left");
    }
}
