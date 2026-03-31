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

    function setUp() public override {
        // Setup will be filled by Olympix
    }

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
}