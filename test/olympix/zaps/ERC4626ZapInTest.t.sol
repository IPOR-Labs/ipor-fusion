// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {ERC4626ZapIn} from "../../../contracts/zaps/ERC4626ZapIn.sol";

import {ZapInData, Call} from "contracts/zaps/ERC4626ZapIn.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract ERC4626ZapInTest is OlympixUnitTest("ERC4626ZapIn") {

    receive() external payable {}


    function test_zapIn_revertsWhenMinAmountToDepositIsZero() public {
            // Arrange: deploy mocks and zap contract
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");
    
            // Prepare minimal valid ZapInData except minAmountToDeposit = 0 to hit the branch
            Call[] memory calls = new Call[](1);
            // dummy target & data, won't be executed due to early revert
            calls[0] = Call({target: address(this), data: bytes("")});
    
            address[] memory assetsToRefund = new address[](0);
    
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(this),
                minAmountToDeposit: 0, // <- triggers opix-target-branch-78-True path
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });
    
            // Act & Assert: expect revert with MinAmountToDepositIsZero
            vm.expectRevert(ERC4626ZapIn.MinAmountToDepositIsZero.selector);
            zap.zapIn(data_);
        }

    function test_zapIn_minAmountToDepositNonZero_hitsElseBranchAndSucceeds() public {
            // Arrange: deploy zap, underlying token and ERC4626 vault
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");

            // Mint underlying to test contract so it can be deposited
            underlying.mint(address(this), 1 ether);

            // Need at least one call: approve the vault to spend underlying from the zap
            Call[] memory calls = new Call[](1);
            calls[0] = Call({
                target: address(underlying),
                data: abi.encodeWithSelector(IERC20.approve.selector, address(vault), type(uint256).max)
            });
            address[] memory assetsToRefund = new address[](0);

            // Prepare ZapInData with minAmountToDeposit > 0 to enter the opix-target-branch-80 else-branch
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(this),
                minAmountToDeposit: 1 ether,
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });

            // Pre-transfer underlying directly to zap so deposit check passes
            underlying.transfer(address(zap), 1 ether);

            // Act: call zapIn, which should not revert and should hit the `minAmountToDeposit != 0` else-branch
            zap.zapIn(data_);

            // Assert basic post-conditions: all underlying deposited into vault, test contract received shares
            assertEq(underlying.balanceOf(address(zap)), 0, "Zap contract should have no remaining underlying");
            assertEq(underlying.balanceOf(address(vault)), 1 ether, "Vault should hold all deposited underlying");
            assertGt(vault.balanceOf(address(this)), 0, "Receiver should receive vault shares");
        }

    function test_zapIn_revertsWhenVaultIsZero_hitsOpixTargetBranch84True() public {
            // Arrange
            ERC4626ZapIn zap = new ERC4626ZapIn();
    
            // Prepare minimal valid ZapInData except vault = address(0) to trigger opix-target-branch-84-True
            Call[] memory calls = new Call[](1);
            calls[0] = Call({target: address(this), data: bytes("")});
    
            address[] memory assetsToRefund = new address[](0);
    
            ZapInData memory data_ = ZapInData({
                vault: address(0), // <- triggers opix-target-branch-84-True (vault == address(0))
                receiver: address(this),
                minAmountToDeposit: 1,
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });
    
            // Act & Assert
            vm.expectRevert(ERC4626ZapIn.ERC4626VaultIsZero.selector);
            zap.zapIn(data_);
        }

    function test_zapIn_callsNonEmpty_hitsOpixBranch94Else() public {
            // Arrange: deploy zap, underlying token and ERC4626 vault
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");

            // Mint underlying to zap so it can be deposited after calls
            underlying.mint(address(this), 1 ether);
            underlying.transfer(address(zap), 1 ether);

            // Prepare a non-empty calls array: approve the vault to spend underlying
            Call[] memory calls = new Call[](1);
            calls[0] = Call({
                target: address(underlying),
                data: abi.encodeWithSelector(IERC20.approve.selector, address(vault), type(uint256).max)
            });

            address[] memory assetsToRefund = new address[](0);

            // Set minAmountToDeposit <= balance on zap so deposit check passes
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(this),
                minAmountToDeposit: 1 ether,
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });

            // Act: this should execute with `callsLength != 0`, entering the opix-target-branch-94 ELSE path
            zap.zapIn(data_);

            // Assert: basic sanity checks that the flow completed
            assertEq(underlying.balanceOf(address(zap)), 0, "Zap should have no remaining underlying after deposit");
            assertEq(underlying.balanceOf(address(vault)), 1 ether, "Vault should hold deposited underlying");
            assertGt(vault.balanceOf(address(this)), 0, "Receiver should have received vault shares");
        }

    function test_zapIn_revertsWhenReceiverIsZero_hitsOpixTargetBranch98True() public {
            // Arrange: deploy zap, underlying token and ERC4626 vault
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");
    
            // Prepare minimal valid ZapInData except receiver = address(0) to trigger opix-target-branch-98-True
            Call[] memory calls = new Call[](1);
            calls[0] = Call({target: address(this), data: bytes("")});
    
            address[] memory assetsToRefund = new address[](0);
    
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(0), // <- triggers opix-target-branch-98-True (receiver == address(0))
                minAmountToDeposit: 1,
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });
    
            // Act & Assert: expect revert with ReceiverIsZero
            vm.expectRevert(ERC4626ZapIn.ReceiverIsZero.selector);
            zap.zapIn(data_);
        }

    function test_zapIn_revertsWhenNoCallsProvided_hitsOpixTargetBranch92True() public {
            // Arrange: deploy zap, underlying token and ERC4626 vault
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");
    
            // Non-zero minAmountToDeposit and valid vault/receiver so we reach the calls-length check
            Call[] memory calls = new Call[](0); // <- triggers opix-target-branch-92-True (length == 0)
            address[] memory assetsToRefund = new address[](0);
    
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(this),
                minAmountToDeposit: 1,
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });
    
            // Act & Assert: expect revert with NoCalls
            vm.expectRevert(ERC4626ZapIn.NoCalls.selector);
            zap.zapIn(data_);
        }

    function test_zapIn_revertsWhenDepositAssetBalanceBelowMin_hitsOpixTargetBranch112True() public {
            // Arrange: deploy zap, underlying token and ERC4626 vault
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");
    
            // Mint some underlying, but leave less than minAmountToDeposit on the zap contract
            underlying.mint(address(this), 1 ether);
            // Transfer 0.5 ether to zap; set minAmountToDeposit to 1 ether so balance < minAmountToDeposit
            underlying.transfer(address(zap), 0.5 ether);
    
            // Need at least one call so we pass the `NoCalls` check; simple approve is fine
            Call[] memory calls = new Call[](1);
            calls[0] = Call({
                target: address(underlying),
                data: abi.encodeWithSelector(IERC20.approve.selector, address(vault), type(uint256).max)
            });
    
            address[] memory assetsToRefund = new address[](0);
    
            // Prepare ZapInData such that all earlier checks pass and we hit the
            // `depositAssetBalance < zapInData_.minAmountToDeposit` branch
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(this),
                minAmountToDeposit: 1 ether, // greater than zap's 0.5 ether balance
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });
    
            // Act & Assert: expect revert with InsufficientDepositAssetBalance, hitting opix-target-branch-112-True
            vm.expectRevert(ERC4626ZapIn.InsufficientDepositAssetBalance.selector);
            zap.zapIn(data_);
        }

    function test_zapIn_revertsWhenSharesReceivedBelowMin_hitsOpixTargetBranch120True() public {
            // Arrange: deploy zap, underlying token and ERC4626 vault
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");
    
            // Mint underlying to this test contract and move it to the zap contract
            underlying.mint(address(this), 1 ether);
            underlying.transfer(address(zap), 1 ether);
    
            // Need at least one call so we pass the NoCalls check; simple approve is fine
            Call[] memory calls = new Call[](1);
            calls[0] = Call({
                target: address(underlying),
                data: abi.encodeWithSelector(IERC20.approve.selector, address(vault), type(uint256).max)
            });
    
            address[] memory assetsToRefund = new address[](0);
    
            // sharesReceived will equal depositAssetBalance (1 ether) for MockERC4626,
            // so set minSharesOut higher than that to trigger the True branch at line 120
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(this),
                minAmountToDeposit: 1 ether,
                minSharesOut: 2 ether, // > sharesReceived, forces InsufficientSharesOut revert
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });
    
            // Act & Assert: expect revert with InsufficientSharesOut, hitting opix-target-branch-120-True
            vm.expectRevert(abi.encodeWithSelector(ERC4626ZapIn.InsufficientSharesOut.selector, 1 ether, 2 ether));
            zap.zapIn(data_);
        }

    function test_zapIn_refundsAssetsToSender_hitsOpixTargetBranch133True() public {
            // Arrange: deploy zap, underlying token, refund token and ERC4626 vault
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC20 refundToken = new MockERC20("RefundToken", "RFT", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");
    
            // Mint underlying to this test contract and move it to the zap contract
            underlying.mint(address(this), 1 ether);
            underlying.transfer(address(zap), 1 ether);
    
            // Mint some refundToken directly to zap so balance > 0 and the if(branch) executes
            refundToken.mint(address(zap), 5 ether);
    
            // Need at least one call so we pass the NoCalls check; simple approve is fine
            Call[] memory calls = new Call[](1);
            calls[0] = Call({
                target: address(underlying),
                data: abi.encodeWithSelector(IERC20.approve.selector, address(vault), type(uint256).max)
            });
    
            // Configure assetsToRefundToSender to include refundToken, so its balance is checked and refunded
            address[] memory assetsToRefund = new address[](1);
            assetsToRefund[0] = address(refundToken);
    
            // Prepare ZapInData so all earlier checks pass and we reach the refund loop
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(this),
                minAmountToDeposit: 1 ether,
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });
    
            // Record starting balances
            uint256 senderRefundBalanceBefore = refundToken.balanceOf(address(this));
            uint256 zapRefundBalanceBefore = refundToken.balanceOf(address(zap));
            assertEq(zapRefundBalanceBefore, 5 ether, "Zap should initially hold refundToken");
    
            // Act: call zapIn, which should execute the `if (balance > 0)` branch and transfer tokens to sender
            zap.zapIn(data_);
    
            // Assert: refundToken moved from zap to msg.sender (this test contract)
            uint256 senderRefundBalanceAfter = refundToken.balanceOf(address(this));
            uint256 zapRefundBalanceAfter = refundToken.balanceOf(address(zap));
    
            assertEq(zapRefundBalanceAfter, 0, "Zap should have refunded all refundToken to sender");
            assertEq(
                senderRefundBalanceAfter,
                senderRefundBalanceBefore + 5 ether,
                "Sender should receive refunded refundToken"
            );
        }

    function test_zapIn_assetsToRefundElseBranch_balanceZero() public {
            ERC4626ZapIn zap = new ERC4626ZapIn();
            MockERC20 underlying = new MockERC20("MockToken", "MTK", 18);
            MockERC20 refundToken = new MockERC20("RefundToken", "RFT", 18);
            MockERC4626 vault = new MockERC4626(underlying, "MockVault", "MVLT");
    
            // Provide underlying to zap so deposit works
            underlying.mint(address(this), 1 ether);
            underlying.transfer(address(zap), 1 ether);
    
            // Ensure refundToken balance on zap is ZERO so the `if (balance > 0)` is false
            assertEq(refundToken.balanceOf(address(zap)), 0, "Initial refund token balance on zap must be zero");
    
            // At least one call so we pass NoCalls check
            Call[] memory calls = new Call[](1);
            calls[0] = Call({
                target: address(underlying),
                data: abi.encodeWithSelector(IERC20.approve.selector, address(vault), type(uint256).max)
            });
    
            // Configure assetsToRefundToSender to include refundToken, which has zero balance on zap
            address[] memory assetsToRefund = new address[](1);
            assetsToRefund[0] = address(refundToken);
    
            ZapInData memory data_ = ZapInData({
                vault: address(vault),
                receiver: address(this),
                minAmountToDeposit: 1 ether,
                minSharesOut: 0,
                assetsToRefundToSender: assetsToRefund,
                calls: calls
            });
    
            uint256 senderRefundBalanceBefore = refundToken.balanceOf(address(this));
    
            // Act: should execute refund loop, but `if (balance > 0)` is false, entering the ELSE branch
            zap.zapIn(data_);
    
            // Assert: no refundToken moved, else-branch was effectively taken
            uint256 senderRefundBalanceAfter = refundToken.balanceOf(address(this));
            assertEq(senderRefundBalanceAfter, senderRefundBalanceBefore, "Sender should not receive any refund token");
            assertEq(refundToken.balanceOf(address(zap)), 0, "Zap should still have zero refund token balance");
        }
}